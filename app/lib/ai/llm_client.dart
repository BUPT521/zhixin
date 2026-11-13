import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/rules/content_identity.dart';
import 'llm_config.dart';

/// 一次模型调用的失败类型；界面只显示一句人话，不把 key 或响应体带出去。
enum LlmFailure {
  notConfigured,
  offline,
  timeout,
  auth,
  rateLimited,
  badResponse,
  truncated,
  toolStalled,
  contextLimit,
  cancelled,
  server,
  toolUnsupported,
  unknown,
}

class LlmException implements Exception {
  const LlmException(this.failure, this.detail);

  final LlmFailure failure;
  final String detail;

  String get shortText => switch (failure) {
    LlmFailure.notConfigured => '模型尚未配置',
    LlmFailure.offline => '网络不可用',
    LlmFailure.timeout => '请求超时',
    LlmFailure.auth => 'API Key 无效或没有权限',
    LlmFailure.rateLimited => '调用额度或频率受限',
    LlmFailure.badResponse => '模型回复格式无法识别',
    LlmFailure.truncated => '回答被截断，请再试一次',
    LlmFailure.toolStalled => '工具调用未能推进回答',
    LlmFailure.contextLimit => '本轮内容超过模型上下文预算',
    LlmFailure.cancelled => '已停止生成',
    LlmFailure.server => '模型服务出错',
    LlmFailure.toolUnsupported => '这个模型或地址不支持工具调用',
    LlmFailure.unknown => '调用失败',
  };

  @override
  String toString() => 'LlmException($failure): $detail';
}

/// 一次流式请求的取消信号；完成时底层连接中止，已经收到的正文由调用方保留。
class LlmCancelToken {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get whenCancelled => _cancelled.future;

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// 同一轮回答共用的截止时间与取消信号，覆盖工具后的请求、流式回退与重试等待。
class LlmRequestBudget {
  LlmRequestBudget({required this.timeout, this.cancelToken})
    : _clock = Stopwatch()..start();

  final Duration timeout;
  final LlmCancelToken? cancelToken;
  final Stopwatch _clock;
  final _expired = Completer<void>();
  late final Future<void> abortTrigger = Future.any<void>([
    _expired.future,
    if (cancelToken case final token?) token.whenCancelled,
  ]);

  Duration get _remaining {
    if (cancelToken?.isCancelled ?? false) {
      throw const LlmException(LlmFailure.cancelled, '用户停止');
    }
    final value = timeout - _clock.elapsed;
    if (value <= Duration.zero) {
      throw _expire();
    }
    return value;
  }

  void check() {
    _remaining;
  }

  LlmException _expire() {
    if (!_expired.isCompleted) _expired.complete();
    return LlmException(LlmFailure.timeout, '超过 ${timeout.inSeconds} 秒');
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    try {
      final remaining = _remaining;
      final timed = operation().timeout(remaining);
      final token = cancelToken;
      final result = token == null
          ? await timed
          : await Future.any<T>([
              timed,
              token.whenCancelled.then<T>(
                (_) => throw const LlmException(LlmFailure.cancelled, '用户停止'),
              ),
            ]);
      check();
      return result;
    } on TimeoutException {
      throw _expire();
    }
  }

  Future<void> wait(Duration duration) =>
      run(() => Future<void>.delayed(duration));
}

/// 一张随消息上传的图片；默认按 JPEG 处理，原图已经压缩到长边 1600。
class LlmImage {
  LlmImage({required Uint8List bytes, this.mimeType = 'image/jpeg'})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  final String mimeType;

  /// 与本机附件对象共用按原始字节计算的标识。
  late final String id = contentHash(bytes);
  late final String _base64 = base64Encode(bytes);
}

class LlmMessage {
  const LlmMessage({
    this.id,
    required this.role,
    required this.content,
    this.images = const [],
    this.toolCalls = const [],
    this.reasoningItems = const [],
  }) : toolCallId = null,
       toolIsError = false;

  const LlmMessage.toolResult({
    required String callId,
    required this.content,
    this.toolIsError = false,
  }) : role = 'tool',
       id = 'tool-result:$callId',
       toolCallId = callId,
       images = const [],
       toolCalls = const [],
       reasoningItems = const [];

  /// 本轮内的消息标识，用于合并历史。线协议按各接口的格式组装。
  final String? id;

  /// `user`、`assistant` 或 `tool`；system 单独传。
  final String role;
  final String content;

  /// 非空时 content 按数组发送，文字在前、图片在后。
  final List<LlmImage> images;
  final List<LlmToolCall> toolCalls;
  final List<Map<String, Object?>> reasoningItems;
  final String? toolCallId;
  final bool toolIsError;
}

/// 一个可调用的工具；参数是一个 JSON Schema 对象。
class LlmTool {
  const LlmTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 模型已经完成的一次工具调用；参数是 JSON 字符串。
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  Map<String, Object?>? get argumentsObject {
    try {
      final value = jsonDecode(arguments);
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }
}

/// 流式响应里的一段工具参数；同一次调用按 [index] 累积。
class LlmToolCallDelta {
  const LlmToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.arguments = '',
    this.replaceArguments = false,
  });

  final int index;
  final String? id;
  final String? name;
  final String arguments;

  /// 协议在收尾时给出的完整参数覆盖先前的分片。
  final bool replaceArguments;
}

/// 流式响应的一段：正文增量与工具调用增量分开到达，互不影响。
class LlmDelta {
  const LlmDelta({
    this.text = '',
    this.toolCalls = const [],
    this.truncated = false,
    this.reasoningItems = const [],
    this.reasoningProgress = false,
  });

  final String text;
  final List<LlmToolCallDelta> toolCalls;
  final List<Map<String, Object?>> reasoningItems;
  final bool reasoningProgress;

  bool get hasOutput =>
      text.isNotEmpty ||
      toolCalls.isNotEmpty ||
      reasoningItems.isNotEmpty ||
      reasoningProgress;

  /// 模型因输出上限结束，正文已经给完，工具参数不完整；调用方应丢弃工具调用。
  final bool truncated;
}

class LlmReply {
  const LlmReply({
    required this.text,
    this.toolCalls = const [],
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.truncated = false,
    this.reasoningItems = const [],
  });

  final String text;
  final List<LlmToolCall> toolCalls;
  final int tokensIn;
  final int tokensOut;

  /// Responses 用于续接工具调用的协议数据，只在当前回答内传回模型。
  final List<Map<String, Object?>> reasoningItems;

  /// 模型因输出上限结束；[text] 是已经生成的部分，[toolCalls] 为空。
  final bool truncated;
}

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

/// 三种线格式的 HTTP 客户端：Chat Completions、Responses 与 Anthropic Messages。
///
/// 共用的部分：30 秒超时，网络错误与服务端 5xx 重试一次，SSE 按规范读事件
/// （多行 `data:`、空行分发、注释与 `event:` 字段、首行 BOM），非 2xx 时读出
/// 服务端自己的错误说明。
///
/// 结束的确认方式各家不同：Chat Completions 用 `[DONE]` 或 `finish_reason`，
/// Responses 用 `response.completed` 一类事件，Anthropic 用 `message_stop`；
/// 都没有时按截断保留已经生成的正文，半截回答不会被当成完整回答。
class HttpLlmClient implements LlmClient {
  HttpLlmClient({
    required this.config,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(milliseconds: 600),
    this.firstOutputTimeout = const Duration(seconds: 30),
    this.streamIdleTimeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final LlmConfig config;
  final Duration timeout;
  final Duration retryDelay;
  final Duration firstOutputTimeout;
  final Duration streamIdleTimeout;
  final http.Client _http;
  final bool _ownsClient;

  _Wire get _wire => _wireFor(config.api);

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
    final wire = _wire;
    final lifecycle = budget ?? LlmRequestBudget(timeout: timeout);
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final response = await lifecycle.run(
          () => _http.send(
            _request(
              wire: wire,
              system: system,
              messages: messages,
              stream: false,
              tools: tools,
              forceTool: forceTool,
              allowToolCalls: allowToolCalls,
              abortTrigger: lifecycle.abortTrigger,
            ),
          ),
        );
        if (_ok(response.statusCode)) {
          // 服务端多半只回 `application/json`、不带 charset，按 UTF-8 自己解，
          // 免得中文被 latin1 解成乱码。
          final bytes = await lifecycle.run(response.stream.toBytes);
          return wire.decoder().decodeBody(
            utf8.decode(bytes, allowMalformed: true),
          );
        }
        final failure = await _readFailure(response, lifecycle);
        if (failure.failure == LlmFailure.server && attempt == 1) {
          await lifecycle.wait(retryDelay);
          continue;
        }
        throw failure;
      } on LlmException {
        rethrow;
      } on SocketException catch (error) {
        if (attempt == 1) {
          await lifecycle.wait(retryDelay);
          continue;
        }
        throw LlmException(LlmFailure.offline, error.message);
      } on http.RequestAbortedException {
        throw _aborted(lifecycle);
      } on http.ClientException catch (error) {
        if (attempt == 1) {
          await lifecycle.wait(retryDelay);
          continue;
        }
        throw LlmException(LlmFailure.offline, error.message);
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
    final wire = _wire;
    final lifecycle =
        budget ?? LlmRequestBudget(timeout: timeout, cancelToken: cancelToken);
    for (var index = 0; ; index++) {
      lifecycle.check();
      final attempt = _StreamAttempt(
        lifecycle: lifecycle,
        firstOutputTimeout: firstOutputTimeout,
        idleTimeout: streamIdleTimeout,
      );
      var serverUnavailable = false;
      try {
        final response = await attempt.run(
          () => _http.send(
            _request(
              wire: wire,
              system: system,
              messages: messages,
              stream: true,
              tools: tools,
              forceTool: forceTool,
              allowToolCalls: allowToolCalls,
              abortTrigger: attempt.abortTrigger,
            ),
          ),
        );
        if (!_ok(response.statusCode)) {
          serverUnavailable = response.statusCode >= 500;
          throw await _readFailure(response, lifecycle, attempt: attempt);
        }
        final deltas = _isEventStream(response)
            ? _events(response.stream, attempt, wire.decoder())
            : _readJsonAsStream(response, attempt, wire.decoder());
        await for (final delta in deltas) {
          yield delta;
          // 界面接收增量的时间不占用下一段响应的空闲期限。
          attempt.checkLifecycle();
          if (delta.hasOutput) attempt.noteOutput();
        }
        return;
      } catch (error) {
        final failure = switch (error) {
          final LlmException value => value,
          final SocketException value => LlmException(
            LlmFailure.offline,
            value.message,
          ),
          http.RequestAbortedException() => _aborted(lifecycle),
          final http.ClientException value => LlmException(
            LlmFailure.offline,
            value.message,
          ),
          _ => null,
        };
        if (failure == null) rethrow;
        lifecycle.check();
        final retryable = switch (failure.failure) {
          LlmFailure.offline || LlmFailure.timeout => true,
          LlmFailure.server => serverUnavailable,
          _ => false,
        };
        if (index != 0 || attempt.hasOutput || !retryable) throw failure;
      } finally {
        attempt.abort();
      }
      await lifecycle.wait(retryDelay);
    }
  }

  /// 有的兼容接口忽略 stream，直接返回完整 JSON。
  Stream<LlmDelta> _readJsonAsStream(
    http.StreamedResponse response,
    _StreamAttempt attempt,
    _Decoder decoder,
  ) async* {
    final bytes = await attempt.run(response.stream.toBytes);
    final reply = decoder.decodeBody(utf8.decode(bytes, allowMalformed: true));
    if (reply.text.isNotEmpty) yield LlmDelta(text: reply.text);
    if (reply.truncated) {
      yield const LlmDelta(truncated: true);
      return;
    }
    if (reply.reasoningItems.isNotEmpty) {
      yield LlmDelta(reasoningItems: reply.reasoningItems);
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
    required _Wire wire,
    required String system,
    required List<LlmMessage> messages,
    required bool stream,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required Future<void> abortTrigger,
  }) {
    final request = http.AbortableRequest(
      'POST',
      Uri.parse(config.endpoint),
      abortTrigger: abortTrigger,
    );
    request.headers.addAll(wire.headers(config, stream: stream));
    request.bodyBytes = utf8.encode(
      jsonEncode(
        wire.body(
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

  /// 逐事件读 SSE，交给对应协议的解码器；空行分发，`data:` 可以多行。
  Stream<LlmDelta> _events(
    Stream<List<int>> bytes,
    _StreamAttempt attempt,
    _Decoder decoder,
  ) async* {
    final reader = _SseReader();
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

  /// 非 2xx 时尽量读出服务端自己的说明：key、额度、模型名的问题全靠这一句。
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
      final message = _errorMessage(utf8.decode(bytes, allowMalformed: true));
      if (message != null) detail = message;
    } on LlmException catch (error) {
      if (attempt == null || error.failure != LlmFailure.timeout) rethrow;
      lifecycle.check();
    } catch (_) {
      // 读不出响应体时保留状态码。
    }
    return LlmException(failure, detail);
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
  _StreamAttempt({
    required this.lifecycle,
    required Duration firstOutputTimeout,
    required this.idleTimeout,
  }) : _deadline = firstOutputTimeout;

  final LlmRequestBudget lifecycle;
  final Duration idleTimeout;
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
    _deadline = _clock.elapsed + idleTimeout;
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

// ---------------------------------------------------------------------------
// 公共小工具
// ---------------------------------------------------------------------------

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

/// 服务端在响应体或流式片段里带的错误说明；没有说明时给一句通用的话。
String _errorText(Object? error) {
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.trim().isNotEmpty) {
      return _clip(message.trim());
    }
  }
  if (error is String && error.trim().isNotEmpty) {
    return _clip(error.trim());
  }
  return '模型服务出错';
}

String? _errorMessage(String body) {
  final text = body.trim();
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, Object?>) {
      final error = decoded['error'];
      if (error is Map) return _errorText(error);
      if (error is String) return _errorText(error);
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) {
        return _clip(message.trim());
      }
    }
  } on FormatException {
    // 不是 JSON：当纯文本说明读。
  }
  // HTML 错误页不整页塞进提示。
  if (text.startsWith('<')) return null;
  return _clip(text);
}

String _clip(String text) =>
    text.length <= 200 ? text : '${text.substring(0, 200)}…';

/// 正文可能是字符串，也可能是内容块数组：多模态的兼容实现会按 OpenAI 的
/// 新格式发 `[{"type":"text","text":"…"}]`。
String _textOf(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is Map && part['text'] is String) {
      buffer.write(part['text'] as String);
    }
  }
  return buffer.toString();
}

String _dataUrl(LlmImage image) =>
    'data:${image.mimeType};base64,${image._base64}';

// ---------------------------------------------------------------------------
// 三种线格式
// ---------------------------------------------------------------------------

_Wire _wireFor(LlmApi api) => switch (api) {
  LlmApi.chat => const _ChatWire(),
  LlmApi.responses => const _ResponsesWire(),
  LlmApi.anthropic => const _AnthropicWire(),
};

abstract class _Wire {
  const _Wire();

  Map<String, String> headers(LlmConfig config, {required bool stream});

  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  });

  _Decoder decoder();
}

/// OpenAI 兼容的 `/chat/completions`，DeepSeek 与多数中转站都属于这一类。
final class _ChatWire extends _Wire {
  const _ChatWire();

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'Authorization': 'Bearer ${config.apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  /// DeepSeek 的思考模式默认打开，推理内容同样计入输出上限，还会让指定工具的
  /// `tool_choice` 直接返回 400；知新的回答只要三到五句，所以按服务商关掉。
  /// 输出上限在 OpenAI 官方换成了 `max_completion_tokens`，其余兼容实现仍用
  /// `max_tokens`。
  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': system},
        for (final message in messages) _message(message),
      ],
      'temperature': 0.5,
      if (config.isDeepSeek) 'thinking': const {'type': 'disabled'},
      if (stream) 'stream': true,
      if (stream) 'stream_options': const {'include_usage': true},
      if (config.isOpenAi)
        'max_completion_tokens': config.outputTokenLimit
      else
        'max_tokens': config.outputTokenLimit,
      if (tools.isNotEmpty) 'tools': [for (final tool in tools) tool.toJson()],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? 'none'
            : forceTool == null
            ? 'auto'
            : {
                'type': 'function',
                'function': {'name': forceTool},
              },
    };
  }

  Map<String, Object?> _message(LlmMessage message) {
    if (message.toolCallId case final id?) {
      return {'role': 'tool', 'tool_call_id': id, 'content': message.content};
    }
    if (message.toolCalls.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': message.content.isEmpty ? null : message.content,
        'tool_calls': [
          for (final call in message.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {'name': call.name, 'arguments': call.arguments},
            },
        ],
      };
    }
    if (message.images.isEmpty) {
      return {'role': message.role, 'content': message.content};
    }
    return {
      'role': message.role,
      'content': [
        {'type': 'text', 'text': message.content},
        for (final image in message.images)
          {
            'type': 'image_url',
            'image_url': {'url': _dataUrl(image)},
          },
      ],
    };
  }

  @override
  _Decoder decoder() => _ChatDecoder();
}

/// OpenAI 与 DeepSeek 的 `/responses`：system 放 `instructions`，输入是条目数组。
final class _ResponsesWire extends _Wire {
  const _ResponsesWire();

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'Authorization': 'Bearer ${config.apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'instructions': system,
      'input': [for (final message in messages) ..._input(message)],
      if (config.isDeepSeek) 'reasoning': const {'effort': 'none'},
      if (config.isOpenAi) ...{
        'store': false,
        'include': const ['reasoning.encrypted_content'],
      },
      'stream': stream,
      'max_output_tokens': config.outputTokenLimit,
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
              'strict': false,
            },
        ],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? 'none'
            : forceTool == null
            ? 'auto'
            : {'type': 'function', 'name': forceTool},
    };
  }

  /// 用户消息用 `input_text`／`input_image`，助手历史用 `output_text`。
  List<Object?> _input(LlmMessage message) {
    if (message.toolCallId case final id?) {
      return [
        {
          'type': 'function_call_output',
          'call_id': id,
          'output': message.content,
        },
      ];
    }
    final assistant = message.role == 'assistant';
    final parts = <Object?>[
      {
        'type': assistant ? 'output_text' : 'input_text',
        'text': message.content,
      },
      if (!assistant)
        for (final image in message.images)
          {'type': 'input_image', 'image_url': _dataUrl(image)},
    ];
    return [
      ...message.reasoningItems,
      if (message.content.isNotEmpty || message.toolCalls.isEmpty)
        {'role': message.role, 'content': parts},
      for (final call in message.toolCalls)
        {
          'type': 'function_call',
          'call_id': call.id,
          'name': call.name,
          'arguments': call.arguments,
        },
    ];
  }

  @override
  _Decoder decoder() => _ResponsesDecoder();
}

/// Anthropic Messages：system 是顶层字段，鉴权用 `x-api-key`。
final class _AnthropicWire extends _Wire {
  const _AnthropicWire();

  static const String _version = '2023-06-01';

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'x-api-key': config.apiKey.trim(),
    'anthropic-version': _version,
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'max_tokens': config.outputTokenLimit,
      'system': system,
      'messages': _messages(messages),
      'stream': stream,
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
        ],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? const {'type': 'none'}
            : forceTool == null
            ? const {'type': 'auto'}
            : {'type': 'tool', 'name': forceTool},
    };
  }

  List<Object?> _messages(List<LlmMessage> messages) {
    final result = <Object?>[];
    List<Object?>? toolResults;
    for (final message in messages) {
      if (message.toolCallId case final id?) {
        if (toolResults == null) {
          toolResults = [];
          result.add({'role': 'user', 'content': toolResults});
        }
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': id,
          'content': message.content,
          if (message.toolIsError) 'is_error': true,
        });
      } else {
        toolResults = null;
        result.add(_message(message));
      }
    }
    return result;
  }

  Map<String, Object?> _message(LlmMessage message) {
    final parts = <Object?>[
      if (message.content.trim().isNotEmpty)
        {'type': 'text', 'text': message.content},
      if (message.role != 'assistant')
        for (final image in message.images)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': image.mimeType,
              'data': image._base64,
            },
          },
      for (final call in message.toolCalls)
        {
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': call.argumentsObject ?? const <String, Object?>{},
        },
    ];
    // Anthropic 不接受空 content；图片被关掉时仍要保留这一轮的占位文字。
    if (parts.isEmpty) {
      parts.add({'type': 'text', 'text': '[发了一张图片]'});
    }
    return {'role': message.role, 'content': parts};
  }

  @override
  _Decoder decoder() => _AnthropicDecoder();
}

// ---------------------------------------------------------------------------
// 流式解码
// ---------------------------------------------------------------------------

/// 一次流式回答的解码状态；不同协议的结束标记与事件形状在这里各自处理。
abstract class _Decoder {
  bool done = false;
  bool truncated = false;
  bool sawText = false;
  bool sawOutput = false;

  /// 一个 SSE 事件转成增量；服务端报错时抛出 [LlmException]。
  List<LlmDelta> accept(String? event, String data);

  /// 流结束时检查：没有正文按格式错误抛出。
  void verify() {
    if (!sawOutput) {
      throw const LlmException(LlmFailure.badResponse, '流式响应没有内容');
    }
  }

  LlmReply decodeBody(String body);
}

/// Chat Completions：一条 `data:` 放一个 chunk，`[DONE]` 收尾。
final class _ChatDecoder extends _Decoder {
  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty) return const [];
    if (payload == '[DONE]') {
      done = true;
      return const [];
    }
    final chunk = _decodeChunk(payload);
    final deltas = <LlmDelta>[];
    if (chunk.reasoningProgress) {
      deltas.add(const LlmDelta(reasoningProgress: true));
    }
    if (chunk.text.isNotEmpty) {
      sawText = true;
      sawOutput = true;
      deltas.add(LlmDelta(text: chunk.text));
    }
    if (chunk.calls.isNotEmpty) {
      sawOutput = true;
      deltas.add(LlmDelta(toolCalls: chunk.calls));
    }
    final finish = chunk.finish;
    if (finish != null) {
      done = true;
      if (_incomplete(finish)) truncated = true;
      if (finish == 'content_filter') {
        throw const LlmException(LlmFailure.server, '回答被内容过滤');
      }
    }
    return deltas;
  }

  _Chunk _decodeChunk(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error) {
      throw LlmException(
        LlmFailure.badResponse,
        '流式片段不是 JSON：${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const LlmException(LlmFailure.badResponse, '流式片段不是 JSON object');
    }
    final error = decoded['error'];
    if (error != null) {
      throw LlmException(LlmFailure.server, _errorText(error));
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      // 只带用量的片段，没有正文可读。
      return const _Chunk();
    }
    final first = choices.first;
    if (first is! Map<String, Object?>) return const _Chunk();
    final body = first['delta'] is Map<String, Object?>
        ? first['delta'] as Map<String, Object?>
        : first['message'] is Map<String, Object?>
        ? first['message'] as Map<String, Object?>
        : const <String, Object?>{};
    final finish = first['finish_reason'];
    final reasoning = body['reasoning_content'];
    return _Chunk(
      text: _textOf(body['content']),
      calls: _toolCallDeltas(body['tool_calls']),
      finish: finish is String && finish.isNotEmpty ? finish : null,
      reasoningProgress: reasoning is String && reasoning.isNotEmpty,
    );
  }

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw LlmException(LlmFailure.server, _errorText(error));
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('没有 choices');
      }
      final first = choices.first;
      final message = first is Map<String, Object?> ? first['message'] : null;
      final content = message is Map<String, Object?>
          ? message['content']
          : null;
      final finish =
          first is Map<String, Object?> && first['finish_reason'] is String
          ? first['finish_reason'] as String
          : null;
      final text = _textOf(content).trim();
      if (finish == 'content_filter') {
        throw const LlmException(LlmFailure.server, '回答被内容过滤');
      }
      final truncated = finish != null && _incomplete(finish);
      if (truncated && text.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      final calls = message is Map<String, Object?>
          ? _toolCalls(message['tool_calls'])
          : const <LlmToolCall>[];
      if (text.isEmpty && calls.isEmpty) {
        throw const FormatException('message.content 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: text,
        toolCalls: truncated ? const [] : calls,
        tokensIn:
            _intOf(usage, 'prompt_tokens') ??
            _intOf(usage, 'input_tokens') ??
            0,
        tokensOut:
            _intOf(usage, 'completion_tokens') ??
            _intOf(usage, 'output_tokens') ??
            0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}

/// Responses：语义事件，正文在 `response.output_text.delta`，结束时带完整 output。
final class _ResponsesDecoder extends _Decoder {
  /// 某个工具调用是否已经收到过参数增量；没有收到时用收尾事件里的完整参数。
  final Map<int, String> _finalArguments = {};
  final Map<String, int> _indexByItem = {};
  var _nextToolIndex = 0;
  var _lastToolIndex = 0;
  final StringBuffer _textSent = StringBuffer();

  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty || payload == '[DONE]') return const [];
    final decoded = _decodeObject(payload);
    final type = decoded['type'] is String
        ? decoded['type'] as String
        : (event ?? '');
    final deltas = <LlmDelta>[];
    switch (type) {
      case 'response.output_text.delta':
        final text = decoded['delta'];
        if (text is String && text.isNotEmpty) {
          _textSent.write(text);
          sawText = true;
          sawOutput = true;
          deltas.add(LlmDelta(text: text));
        }
      case 'response.reasoning_text.delta' ||
          'response.reasoning_summary_text.delta':
        final fragment = decoded['delta'];
        if (fragment is String && fragment.isNotEmpty) {
          deltas.add(const LlmDelta(reasoningProgress: true));
        }
      case 'response.function_call_arguments.delta':
        final args = decoded['delta'];
        if (args is String && args.isNotEmpty) {
          final index = _indexFor(_itemId(decoded));
          _lastToolIndex = index;
          if (!_finalArguments.containsKey(index)) {
            deltas.add(
              LlmDelta(
                toolCalls: [LlmToolCallDelta(index: index, arguments: args)],
              ),
            );
          }
        }
      case 'response.function_call_arguments.done':
        _finishArguments(
          deltas,
          _indexFor(_itemId(decoded)),
          decoded['arguments'],
        );
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = decoded['item'];
        if (item is Map<String, Object?> && item['type'] == 'reasoning') {
          final encrypted = item['encrypted_content'];
          deltas.add(
            type == 'response.output_item.done' &&
                    encrypted is String &&
                    encrypted.isNotEmpty
                ? LlmDelta(reasoningItems: [item])
                : const LlmDelta(reasoningProgress: true),
          );
        }
        if (item is Map<String, Object?> && item['type'] == 'function_call') {
          final index = _indexFor(_itemId(item));
          _lastToolIndex = index;
          final id = item['call_id'] is String
              ? item['call_id'] as String
              : null;
          final name = item['name'] is String ? item['name'] as String : null;
          if (name != null || id != null) {
            sawOutput = true;
            deltas.add(
              LlmDelta(
                toolCalls: [LlmToolCallDelta(index: index, id: id, name: name)],
              ),
            );
          }
          if (type == 'response.output_item.done') {
            _finishArguments(deltas, index, item['arguments']);
          }
        }
      case 'response.completed' || 'response.incomplete':
        final response = decoded['response'];
        if (response is Map<String, Object?>) {
          final status = response['status'];
          final incomplete =
              type == 'response.incomplete' || status == 'incomplete';
          if (incomplete) truncated = true;
          deltas.addAll(_reconcile(response));
        }
        done = true;
      case 'response.failed':
        final response = decoded['response'];
        final error = response is Map<String, Object?>
            ? response['error']
            : null;
        throw LlmException(LlmFailure.server, _errorText(error ?? '回答生成失败'));
      case 'error':
        throw LlmException(
          LlmFailure.server,
          _errorText(decoded['error'] ?? decoded),
        );
      default:
        // reasoning、web search 等事件不影响正文。
        break;
    }
    return deltas;
  }

  /// 有的网关在工具调用前后不发正文增量，只在收尾事件里给出完整 output：
  /// 正文只补还没发过的后缀，完整工具参数覆盖已有分片。
  List<LlmDelta> _reconcile(Map<String, Object?> response) {
    final output = response['output'];
    if (output is! List) return const [];
    final deltas = <LlmDelta>[];
    final reasoningItems = _reasoningItems(output);
    if (reasoningItems.isNotEmpty) {
      deltas.add(LlmDelta(reasoningItems: reasoningItems));
    }
    final fullText = StringBuffer();
    for (final item in output) {
      if (item is Map<String, Object?> && item['type'] == 'message') {
        fullText.write(_textOf(item['content']));
      }
    }
    final complete = fullText.toString();
    final sent = _textSent.toString();
    if (complete.length > sent.length && complete.startsWith(sent)) {
      final suffix = complete.substring(sent.length);
      _textSent.write(suffix);
      sawText = true;
      sawOutput = true;
      deltas.add(LlmDelta(text: suffix));
    }
    for (final item in output) {
      if (item is! Map<String, Object?>) continue;
      final type = item['type'];
      if (type == 'function_call') {
        final itemId = _itemId(item);
        final index = _indexFor(itemId);
        final id = item['call_id'] is String ? item['call_id'] as String : null;
        final name = item['name'] is String ? item['name'] as String : null;
        if (name != null || id != null) {
          sawOutput = true;
          deltas.add(
            LlmDelta(
              toolCalls: [LlmToolCallDelta(index: index, id: id, name: name)],
            ),
          );
        }
        _finishArguments(deltas, index, item['arguments']);
      }
    }
    return deltas;
  }

  void _finishArguments(List<LlmDelta> deltas, int index, Object? value) {
    if (value is! String || value.isEmpty || _finalArguments[index] == value) {
      return;
    }
    _finalArguments[index] = value;
    sawOutput = true;
    deltas.add(
      LlmDelta(
        toolCalls: [
          LlmToolCallDelta(
            index: index,
            arguments: value,
            replaceArguments: true,
          ),
        ],
      ),
    );
  }

  String? _itemId(Map<String, Object?> value) {
    final itemId = value['item_id'];
    if (itemId is String && itemId.isNotEmpty) return itemId;
    final id = value['id'];
    if (id is String && id.isNotEmpty) return id;
    final outputIndex = value['output_index'];
    if (outputIndex is int) return 'output:$outputIndex';
    return null;
  }

  int _indexFor(String? itemId) {
    if (itemId == null) return _lastToolIndex;
    final existing = _indexByItem[itemId];
    if (existing != null) return existing;
    final index = _nextToolIndex++;
    _indexByItem[itemId] = index;
    return index;
  }

  List<Map<String, Object?>> _reasoningItems(List<Object?> output) => [
    for (final item in output)
      if (item is Map<String, Object?> && item['type'] == 'reasoning') item,
  ];

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw LlmException(LlmFailure.server, _errorText(error));
      }
      final output = decoded['output'];
      if (output is! List) throw const FormatException('没有 output');
      final text = StringBuffer();
      final calls = <LlmToolCall>[];
      for (final item in output) {
        if (item is! Map<String, Object?>) continue;
        if (item['type'] == 'message') {
          text.write(_textOf(item['content']));
        } else if (item['type'] == 'function_call') {
          final name = item['name'];
          final args = item['arguments'];
          if (name is! String || name.trim().isEmpty) continue;
          calls.add(
            LlmToolCall(
              id: item['call_id'] is String ? item['call_id'] as String : '',
              name: name.trim(),
              arguments: args is String
                  ? args
                  : args == null
                  ? ''
                  : jsonEncode(args),
            ),
          );
        }
      }
      final status = decoded['status'];
      final reason = decoded['incomplete_details'] is Map<String, Object?>
          ? (decoded['incomplete_details'] as Map<String, Object?>)['reason']
          : null;
      final truncated = status == 'incomplete' || reason != null;
      final bodyText = text.toString().trim();
      if (truncated && bodyText.isEmpty && calls.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      if (bodyText.isEmpty && calls.isEmpty) {
        throw const FormatException('output 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: bodyText,
        toolCalls: truncated ? const [] : calls,
        reasoningItems: truncated ? const [] : _reasoningItems(output),
        tokensIn: _intOf(usage, 'input_tokens') ?? 0,
        tokensOut: _intOf(usage, 'output_tokens') ?? 0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}

/// Anthropic Messages：`content_block_*` 增量与 `message_delta.stop_reason`。
final class _AnthropicDecoder extends _Decoder {
  final Map<int, int> _toolIndexByBlock = {};
  final Map<int, bool> _argsSeenByBlock = {};
  var _nextToolIndex = 0;
  String? _stopReason;

  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty || payload == '[DONE]') return const [];
    final decoded = _decodeObject(payload);
    final type = decoded['type'] is String
        ? decoded['type'] as String
        : (event ?? '');
    switch (type) {
      case 'content_block_start':
        final block = decoded['content_block'];
        final blockIndex = _intOf(decoded, 'index') ?? 0;
        if (block is! Map<String, Object?>) return const [];
        if (block['type'] == 'text') {
          final text = block['text'];
          if (text is String && text.isNotEmpty) {
            sawText = true;
            sawOutput = true;
            return [LlmDelta(text: text)];
          }
          return const [];
        }
        if (block['type'] == 'tool_use') {
          final index = _nextToolIndex++;
          _toolIndexByBlock[blockIndex] = index;
          final id = block['id'] is String ? block['id'] as String : null;
          final name = block['name'] is String ? block['name'] as String : null;
          final input = block['input'];
          final hasInput = input is Map && input.isNotEmpty;
          if (hasInput) _argsSeenByBlock[blockIndex] = true;
          sawOutput = true;
          return [
            LlmDelta(
              toolCalls: [
                LlmToolCallDelta(
                  index: index,
                  id: id,
                  name: name,
                  arguments: hasInput ? jsonEncode(input) : '',
                ),
              ],
            ),
          ];
        }
        return const [];
      case 'content_block_delta':
        final blockIndex = _intOf(decoded, 'index') ?? 0;
        final delta = decoded['delta'];
        if (delta is! Map<String, Object?>) return const [];
        switch (delta['type']) {
          case 'thinking_delta' || 'signature_delta':
            return const [LlmDelta(reasoningProgress: true)];
          case 'text_delta':
            final text = delta['text'];
            if (text is String && text.isNotEmpty) {
              sawText = true;
              sawOutput = true;
              return [LlmDelta(text: text)];
            }
          case 'input_json_delta':
            final args = delta['partial_json'];
            final index = _toolIndexByBlock[blockIndex];
            if (args is String && args.isNotEmpty && index != null) {
              _argsSeenByBlock[blockIndex] = true;
              sawOutput = true;
              return [
                LlmDelta(
                  toolCalls: [LlmToolCallDelta(index: index, arguments: args)],
                ),
              ];
            }
        }
        return const [];
      case 'message_delta':
        final delta = decoded['delta'];
        if (delta is Map<String, Object?>) {
          final reason = delta['stop_reason'];
          if (reason is String) _stopReason = reason;
        }
        if (_stopReason == 'max_tokens' || _stopReason == 'pause_turn') {
          truncated = true;
        }
        if (_stopReason == 'refusal') {
          throw const LlmException(LlmFailure.server, '模型拒绝回答这个问题');
        }
        return const [];
      case 'message_stop':
        done = true;
        return const [];
      case 'error':
        throw _streamError(decoded['error']);
      default:
        // ping、thinking 与工具调用收尾等事件不影响正文。
        return const [];
    }
  }

  LlmException _streamError(Object? error) {
    if (error is! Map) {
      return LlmException(LlmFailure.server, _errorText(error));
    }
    final type = error['type'];
    final message = error['message'];
    final detail = message is String && message.trim().isNotEmpty
        ? _clip(message.trim())
        : '模型服务出错';
    final failure = switch (type) {
      'authentication_error' || 'permission_error' => LlmFailure.auth,
      'rate_limit_error' => LlmFailure.rateLimited,
      'overloaded_error' || 'api_error' => LlmFailure.server,
      'invalid_request_error' || 'not_found_error' => LlmFailure.badResponse,
      _ => LlmFailure.server,
    };
    return LlmException(failure, detail);
  }

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw _streamError(error);
      }
      final content = decoded['content'];
      if (content is! List) throw const FormatException('没有 content');
      final text = StringBuffer();
      final calls = <LlmToolCall>[];
      for (final block in content) {
        if (block is! Map<String, Object?>) continue;
        switch (block['type']) {
          case 'text':
            final value = block['text'];
            if (value is String) text.write(value);
          case 'tool_use':
            final name = block['name'];
            if (name is! String || name.trim().isEmpty) continue;
            final input = block['input'];
            calls.add(
              LlmToolCall(
                id: block['id'] is String ? block['id'] as String : '',
                name: name.trim(),
                arguments: input == null ? '' : jsonEncode(input),
              ),
            );
        }
      }
      final reason = decoded['stop_reason'];
      final truncated = reason == 'max_tokens' || reason == 'pause_turn';
      final bodyText = text.toString().trim();
      if (truncated && bodyText.isEmpty && calls.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      if (bodyText.isEmpty && calls.isEmpty) {
        throw const FormatException('content 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: bodyText,
        toolCalls: truncated ? const [] : calls,
        tokensIn: _intOf(usage, 'input_tokens') ?? 0,
        tokensOut: _intOf(usage, 'output_tokens') ?? 0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}

// ---------------------------------------------------------------------------
// 片段与工具调用
// ---------------------------------------------------------------------------

/// 一条 Chat Completions 流式片段里的正文、工具调用与结束原因。
class _Chunk {
  const _Chunk({
    this.text = '',
    this.calls = const [],
    this.finish,
    this.reasoningProgress = false,
  });

  final String text;
  final List<LlmToolCallDelta> calls;
  final String? finish;
  final bool reasoningProgress;
}

/// `finish_reason` 里表示“没写完”的取值。
bool _incomplete(String finish) =>
    finish == 'length' ||
    finish == 'aborted' ||
    finish == 'insufficient_system_resource';

Map<String, Object?> _decodeObject(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw LlmException(LlmFailure.badResponse, '响应不是 JSON：${error.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const LlmException(LlmFailure.badResponse, '响应不是 JSON object');
  }
  return decoded;
}

int? _intOf(Object? value, String key) {
  if (value is! Map) return null;
  final found = value[key];
  return found is int ? found : null;
}

List<LlmToolCall> _toolCalls(Object? raw) {
  if (raw is! List) return const [];
  final result = <LlmToolCall>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final function = item['function'];
    if (function is! Map) continue;
    final name = function['name'];
    if (name is! String || name.trim().isEmpty) continue;
    final arguments = function['arguments'];
    result.add(
      LlmToolCall(
        id: item['id'] is String ? item['id'] as String : '',
        name: name.trim(),
        arguments: arguments is String
            ? arguments
            : arguments == null
            ? ''
            : jsonEncode(arguments),
      ),
    );
  }
  return result;
}

List<LlmToolCallDelta> _toolCallDeltas(Object? raw) {
  if (raw is! List) return const [];
  final result = <LlmToolCallDelta>[];
  for (var position = 0; position < raw.length; position++) {
    final item = raw[position];
    if (item is! Map) continue;
    final function = item['function'];
    final name = function is Map ? function['name'] : null;
    final arguments = function is Map ? function['arguments'] : null;
    if (name is! String && arguments is! String) continue;
    result.add(
      LlmToolCallDelta(
        // 有的实现不发 index，按数组位置区分并行调用。
        index: item['index'] is int ? item['index'] as int : position,
        id: item['id'] is String ? item['id'] as String : null,
        name: name is String && name.trim().isNotEmpty ? name.trim() : null,
        arguments: arguments is String
            ? arguments
            : arguments == null
            ? ''
            : jsonEncode(arguments),
      ),
    );
  }
  return result;
}

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
