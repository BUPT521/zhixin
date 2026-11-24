import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_config.dart';
import 'llm_failure.dart';
import 'llm_protocol.dart';

/// 业务代码只认这个接口，不直接拼 HTTP。
abstract class LlmClient {
  Future<LlmReply> complete({
    required String system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    String? forceTool,
    bool allowToolCalls = true,
    LlmRequestBudget? budget,
  });

  /// 边生成边返回正文与工具调用增量；服务端不支持流式时仍可用 [complete]。
  ///
  /// 流已经给出内容之后再失败时不能重来，错误直接抛给调用方；调用方已经
  /// 显示的半截回答由它自己决定是否换成兜底内容。
  Stream<LlmDelta> stream({
    required String system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    String? forceTool,
    bool allowToolCalls = true,
    LlmCancelToken? cancelToken,
    LlmRequestBudget? budget,
  });

  /// 只有 HTTP 实现需要关连接；测试替身可以不管。
  void dispose() {}
}

/// 知新服务的 HTTP 客户端：接口固定为 Responses。
///
/// 共用的部分：请求预算给出的整段、首字与空闲期限，网络错误与服务端 5xx
/// 重试一次，SSE 按规范读事件（多行 `data:`、空行分发、注释与 `event:` 字段、
/// 首行 BOM），非 2xx 时读出服务端自己的错误说明；超时不在这一层另设。
///
/// 结束由 `response.completed` 一类的结束事件确认；没有时按截断保留已经生成
/// 的正文，半截回答不会被当成完整回答。地址与令牌只由账号服务在发请求前补进
/// [config]。
class HttpLlmClient implements LlmClient {
  HttpLlmClient({
    required this.config,
    http.Client? httpClient,
    this.budget,
    this.retryDelay = const Duration(milliseconds: 600),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final LlmConfig config;

  /// 构造时给的期限模板；每次请求按它新建预算、从零计时。
  final LlmRequestBudget? budget;
  final Duration retryDelay;
  final http.Client _http;
  final bool _ownsClient;

  /// 普通请求与流式请求各用一份判据：流式请求把首字与空闲超时算作可重试。
  static const _plainRetry = RetryPolicy();
  static const _streamRetry = RetryPolicy(retryTimeout: true);

  /// 上游给出的等待不超过这个时长时自动重试一次；更长的等待交给用户点重试。
  static const Duration _busyRetryLimit = Duration(seconds: 2);

  /// 服务端把上游限流与自己的额度用完分成两个错误码，这里按短时繁忙处理：
  /// 没有给出内容、且等待时间很短时才自动再发一次，避免在限流期间反复请求。
  bool _shortBusyRetry(
    LlmException failure, {
    required bool hasOutput,
    required int attempt,
  }) =>
      failure.failure == LlmFailure.busy &&
      attempt == 0 &&
      !hasOutput &&
      failure.retryAfter != null &&
      failure.retryAfter! <= _busyRetryLimit;

  /// 本次请求的预算：调用方给了就共用它，否则按构造时的模板新建一份。
  LlmRequestBudget _budgetFor({LlmCancelToken? cancelToken}) {
    final template = budget;
    if (template == null) {
      return LlmRequestBudget.request(cancelToken: cancelToken);
    }
    return template.restart(cancelToken: cancelToken ?? template.cancelToken);
  }

  @override
  Future<LlmReply> complete({
    required String system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    String? forceTool,
    bool allowToolCalls = true,
    LlmRequestBudget? budget,
  }) async {
    if (!config.isConfigured) {
      throw const LlmException(LlmFailure.notConfigured, '配置为空');
    }
    final lifecycle = budget ?? _budgetFor();
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await lifecycle.run(
          () => _http.send(
            _request(
              system: system,
              messages: messages,
              stream: false,
              tools: tools,
              forceTool: forceTool,
              allowToolCalls: allowToolCalls,
              abortTrigger: lifecycle.abortTrigger,
              roundBudget: lifecycle.remaining,
              roundSession: lifecycle.sessionId,
            ),
          ),
        );
        if (_ok(response.statusCode)) {
          // 服务端多半只回 `application/json`、不带 charset，按 UTF-8 自己解，
          // 免得中文被 latin1 解成乱码。
          final bytes = await lifecycle.run(response.stream.toBytes);
          return decodeResponse(utf8.decode(bytes, allowMalformed: true));
        }
        final failure = await _readFailure(response, lifecycle);
        if (_plainRetry.shouldRetry(
              failure.failure,
              attempt: attempt,
              serverUnavailable: failure.failure == LlmFailure.server,
            ) ||
            _shortBusyRetry(failure, hasOutput: false, attempt: attempt)) {
          await lifecycle.wait(failure.retryAfter ?? retryDelay);
          continue;
        }
        throw failure;
      } on http.RequestAbortedException {
        throw _aborted(lifecycle);
      } catch (error) {
        final failure = _failureOf(error);
        if (failure == null) rethrow;
        if (_plainRetry.shouldRetry(failure.failure, attempt: attempt)) {
          await lifecycle.wait(retryDelay);
          continue;
        }
        throw failure;
      }
    }
  }

  @override
  Stream<LlmDelta> stream({
    required String system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    String? forceTool,
    bool allowToolCalls = true,
    LlmCancelToken? cancelToken,
    LlmRequestBudget? budget,
  }) async* {
    if (!config.isConfigured) {
      throw const LlmException(LlmFailure.notConfigured, '配置为空');
    }
    final lifecycle = budget ?? _budgetFor(cancelToken: cancelToken);
    for (var index = 0; ; index++) {
      lifecycle.check();
      final attempt = _StreamAttempt(lifecycle: lifecycle);
      var serverUnavailable = false;
      var waitFor = retryDelay;
      try {
        final response = await attempt.run(
          () => _http.send(
            _request(
              system: system,
              messages: messages,
              stream: true,
              tools: tools,
              forceTool: forceTool,
              allowToolCalls: allowToolCalls,
              abortTrigger: attempt.abortTrigger,
              roundBudget: lifecycle.remaining,
              roundSession: lifecycle.sessionId,
            ),
          ),
        );
        if (!_ok(response.statusCode)) {
          serverUnavailable = response.statusCode >= 500;
          throw await _readFailure(response, lifecycle, attempt: attempt);
        }
        final deltas = _isEventStream(response)
            ? _events(response.stream, attempt)
            : _readJsonAsStream(response, attempt);
        await for (final delta in deltas) {
          yield delta;
          // 界面接收增量的时间不占用下一段响应的空闲期限。
          attempt.checkLifecycle();
          if (delta.hasOutput) attempt.noteOutput();
        }
        return;
      } catch (error) {
        final failure = switch (error) {
          http.RequestAbortedException() => _aborted(lifecycle),
          _ => _failureOf(error),
        };
        if (failure == null) rethrow;
        lifecycle.check();
        if (!_streamRetry.shouldRetry(
              failure.failure,
              attempt: index,
              hasOutput: attempt.hasOutput,
              serverUnavailable: serverUnavailable,
            ) &&
            !_shortBusyRetry(
              failure,
              hasOutput: attempt.hasOutput,
              attempt: index,
            )) {
          throw failure;
        }
        waitFor = failure.retryAfter ?? retryDelay;
      } finally {
        attempt.abort();
      }
      await lifecycle.wait(waitFor);
    }
  }

  /// 有的服务端忽略 stream，直接返回整段 JSON。
  Stream<LlmDelta> _readJsonAsStream(
    http.StreamedResponse response,
    _StreamAttempt attempt,
  ) async* {
    final bytes = await attempt.run(response.stream.toBytes);
    final reply = decodeResponse(utf8.decode(bytes, allowMalformed: true));
    if (reply.text.isNotEmpty) yield LlmDelta(text: reply.text);
    if (reply.truncated) {
      yield const LlmDelta(truncated: true);
      return;
    }
    for (var index = 0; index < reply.toolCalls.length; index++) {
      final call = reply.toolCalls[index];
      yield LlmDelta(
        toolCalls: [
          LlmToolCallDelta(
            index: index,
            id: call.id,
            name: call.name,
            arguments: call.arguments,
          ),
        ],
      );
    }
    if (reply.text.isEmpty && reply.toolCalls.isEmpty) {
      throw const LlmException(LlmFailure.badResponse, '整段回答没有内容');
    }
  }

  http.AbortableRequest _request({
    required String system,
    required List<LlmMessage> messages,
    required bool stream,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required Future<void> abortTrigger,
    required Duration roundBudget,
    String? roundSession,
  }) {
    final request = http.AbortableRequest(
      'POST',
      Uri.parse(config.endpoint),
      abortTrigger: abortTrigger,
    );
    request.headers.addAll({
      'Authorization': 'Bearer ${config.apiKey.trim()}',
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
      // 本轮剩余预算，单位毫秒；服务端按自己的上限截断，并把它用作整段回答与
      // 等待首个有效输出的时限，两端的期限因此落在同一份预算里。
      'X-Zhixin-Round-Budget-Ms': '${roundBudget.inMilliseconds}',
      // 这条讨论的稳定标识：服务端据此把追问与工具步骤分到同一条来源，复用
      // 上游已经处理过的前缀；没有归属的请求不带这个头。
      if (roundSession != null && roundSession.trim().isNotEmpty)
        'X-Zhixin-Session-Id': roundSession.trim(),
    });
    request.bodyBytes = utf8.encode(
      jsonEncode(
        responsesBody(
          config: config,
          system: system,
          messages: messages,
          tools: tools,
          forceTool: forceTool,
          allowToolCalls: allowToolCalls,
          stream: stream,
        ),
      ),
    );
    return request;
  }

  bool _ok(int statusCode) => statusCode >= 200 && statusCode < 300;

  bool _isEventStream(http.StreamedResponse response) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        return entry.value.toLowerCase().contains('text/event-stream');
      }
    }
    return false;
  }

  /// 逐事件读 SSE，交给 [LlmStream]；空行分发，`data:` 可以多行。
  Stream<LlmDelta> _events(
    Stream<List<int>> bytes,
    _StreamAttempt attempt,
  ) async* {
    final reader = _SseReader();
    final decoder = LlmStream();
    final iterator = StreamIterator(
      bytes.transform(utf8.decoder).transform(const LineSplitter()),
    );
    var finished = false;
    try {
      while (await attempt.run(iterator.moveNext)) {
        final event = reader.add(iterator.current);
        if (event == null) continue;
        for (final delta in decoder.accept(event.name, event.data)) {
          yield delta;
        }
        if (decoder.done) break;
      }
      // 最后一条事件可能没有空行收尾，仍然要处理。
      if (!decoder.done) {
        final event = reader.flush();
        if (event != null) {
          for (final delta in decoder.accept(event.name, event.data)) {
            yield delta;
          }
        }
      }
      finished = true;
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    } finally {
      if (!finished) attempt.abort();
      await iterator.cancel();
    }

    if (decoder.truncated) {
      // 没有正文时截断等于没有结果，仍按失败退回本地兜底；有正文则交给调用方
      // 保留正文、丢掉不完整的工具调用。
      if (!decoder.sawText) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      yield const LlmDelta(truncated: true);
      return;
    }
    if (!decoder.done && !attempt.hasOutput) {
      throw const LlmException(LlmFailure.offline, '连接在首个有效事件前关闭');
    }
    decoder.verify();
    if (!decoder.done) {
      // 服务端没有给结束标记：连接可能提前结束，正文停在半路，按截断交给上层
      // 保留并提示。
      yield const LlmDelta(truncated: true);
    }
  }

  /// 非 2xx 时尽量读出服务端自己的说明：登录、额度、模型名的问题全靠这一句。
  ///
  /// 服务端代理的 `contact_unverified` 单独归类，界面据此提示去账号页验证，
  /// 而不是让人以为登录失效；这类 4xx 不自动重试。服务端把上游限流写成
  /// `rate_limited` 并给出 `Retry-After`，与账号当天额度用完的 `quota_exceeded`
  /// 分开，前者按短时繁忙提示，后者仍按额度用完提示。
  Future<LlmException> _readFailure(
    http.StreamedResponse response,
    LlmRequestBudget lifecycle, {
    _StreamAttempt? attempt,
  }) async {
    final failure = _failureFor(response.statusCode);
    var detail = 'HTTP ${response.statusCode}';
    try {
      final bytes = attempt == null
          ? await lifecycle.run(response.stream.toBytes)
          : await attempt.run(response.stream.toBytes);
      final body = utf8.decode(bytes, allowMalformed: true);
      final code = problemCodeOf(body);
      final message = errorMessageOf(body);
      if (message != null) detail = message;
      if (code == 'contact_unverified') {
        return const LlmException(
          LlmFailure.contactUnverified,
          '账号还没有确认任何登录方式，托管额度未开放',
        );
      }
      if (code == 'rate_limited') {
        return LlmException(
          LlmFailure.busy,
          detail,
          retryAfter: _retryAfterOf(response),
        );
      }
      if (code == 'quota_exceeded') {
        return LlmException(LlmFailure.rateLimited, detail);
      }
    } on LlmException catch (error) {
      if (attempt == null || error.failure != LlmFailure.timeout) rethrow;
      lifecycle.check();
    } catch (_) {
      // 读不出响应体时保留状态码。
    }
    return LlmException(failure, detail);
  }

  /// 读 `Retry-After` 的秒数；HTTP 日期形式与读不出的值返回 null。
  Duration? _retryAfterOf(http.StreamedResponse response) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'retry-after') continue;
      final seconds = int.tryParse(entry.value.trim());
      if (seconds == null || seconds < 1) return null;
      return Duration(seconds: seconds);
    }
    return null;
  }

  @override
  void dispose() {
    if (_ownsClient) _http.close();
  }

  LlmException _aborted(LlmRequestBudget lifecycle) {
    lifecycle.check();
    return const LlmException(LlmFailure.offline, '请求连接已中断');
  }
}

/// 每次流式尝试独立计时和中止，整轮截止时间与用户取消仍由回答共用。
class _StreamAttempt {
  _StreamAttempt({required this.lifecycle})
    : _deadline = lifecycle.firstOutputTimeout;

  final LlmRequestBudget lifecycle;
  final _clock = Stopwatch()..start();
  final _aborted = Completer<void>();
  Duration _deadline;
  bool hasOutput = false;

  late final Future<void> abortTrigger = Future.any([
    lifecycle.abortTrigger,
    _aborted.future,
  ]);

  void checkLifecycle() => lifecycle.check();

  void noteOutput() {
    hasOutput = true;
    _deadline = _clock.elapsed + lifecycle.idleTimeout;
  }

  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
  }

  Future<T> run<T>(Future<T> Function() operation) => lifecycle.run(() {
    final remaining = _deadline - _clock.elapsed;
    if (remaining <= Duration.zero) throw _timeout();
    return operation().timeout(remaining, onTimeout: () => throw _timeout());
  });

  LlmException _timeout() {
    abort();
    return LlmException(
      LlmFailure.timeout,
      hasOutput ? '流式响应在有效事件之间超时' : '流式响应等待首个有效事件超时',
    );
  }
}

LlmFailure _failureFor(int statusCode) {
  return switch (statusCode) {
    >= 300 && < 400 => LlmFailure.badResponse,
    401 || 403 => LlmFailure.auth,
    404 => LlmFailure.badResponse,
    408 => LlmFailure.timeout,
    429 => LlmFailure.rateLimited,
    >= 500 => LlmFailure.server,
    _ => LlmFailure.badResponse,
  };
}

/// 读服务端 `application/problem+json` 里的 `code`；普通模型响应返回 null。
///
/// 代理自己的拒绝（例如账号还没有确认任何登录方式）用这个字段区分，提供方
/// 原样返回的错误体没有这个字段，仍按状态码归类。
String? problemCodeOf(String body) {
  final text = body.trim();
  if (text.isEmpty || !text.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['code'] is String) {
      final code = (decoded['code']! as String).trim();
      return code.isEmpty ? null : code;
    }
  } on FormatException {
    // 不是 JSON：交给普通错误说明处理。
  }
  return null;
}

/// 普通请求与流式请求共用的重试判据。
///
/// 两边原先各写一段判据：普通请求只看服务端 5xx 与网络异常，并且只在第一次
/// 尝试时重试；流式请求走一份可重试集合，另外要求还没有给出过内容。这里把两个
/// 允许集合原样合并，不因为共用一个策略而放宽或收紧：[offline] 两边都重试，
/// 服务端错误只有这次响应确实是 5xx 时才算可重试，超时只在 [retryTimeout]
/// 为真时重试。
class RetryPolicy {
  const RetryPolicy({this.retryTimeout = false});

  final bool retryTimeout;

  bool shouldRetry(
    LlmFailure failure, {
    required int attempt,
    bool hasOutput = false,
    bool serverUnavailable = false,
  }) {
    if (attempt != 0 || hasOutput) return false;
    return switch (failure) {
      LlmFailure.offline => true,
      LlmFailure.timeout => retryTimeout,
      LlmFailure.server => serverUnavailable,
      _ => false,
    };
  }
}

/// 网络层异常统一成模型调用的失败。
///
/// 连接中断不在这里处理：普通请求不重试中断，流式请求把中断当作可重试的
/// 网络问题，两个循环各自决定，因此保持原来的差异。
LlmException? _failureOf(Object error) => switch (error) {
  final LlmException value => value,
  final SocketException value => LlmException(
    LlmFailure.offline,
    value.message,
  ),
  final http.ClientException value => LlmException(
    LlmFailure.offline,
    value.message,
  ),
  _ => null,
};

// ---------------------------------------------------------------------------
// SSE 读行
// ---------------------------------------------------------------------------

/// 一个 SSE 事件：`event:` 名称可空，负载是拼好的 `data:`。
class _SseEvent {
  const _SseEvent(this.name, this.data);

  final String? name;
  final String data;
}

/// 按 SSE 规范把行拼成事件：`data:` 可以连续多行，空行才是一个事件的结束，
/// 注释行（心跳）与 `id:`／`retry:` 跳过，`event:` 记下事件名。
class _SseReader {
  final StringBuffer _data = StringBuffer();
  var _hasData = false;
  String? _name;

  /// 收下一行；凑满一个事件时返回它，否则返回 null。
  _SseEvent? add(String line) {
    // 有的网关会在流的最前面带 UTF-8 BOM，它不属于字段名。
    if (line.startsWith('\uFEFF')) line = line.substring(1);
    if (line.isEmpty) return _take();
    if (line.startsWith(':')) return null;
    final separator = line.indexOf(':');
    final field = separator < 0 ? line : line.substring(0, separator);
    var value = separator < 0 ? '' : line.substring(separator + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'event':
        _name = value;
      default:
        break;
    }
    return null;
  }

  /// 流在最后一个空行之前结束：最后一条事件照样要处理。
  _SseEvent? flush() => _take();

  _SseEvent? _take() {
    if (!_hasData) {
      _name = null;
      return null;
    }
    final event = _SseEvent(_name, _data.toString());
    _data.clear();
    _hasData = false;
    _name = null;
    return event;
  }
}
