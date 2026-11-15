import 'dart:async';
import 'dart:convert';

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

/// 按名称读回失败类型；认不出的返回空，界面不显示未知失败。
LlmFailure? llmFailureFromName(String? name) {
  for (final failure in LlmFailure.values) {
    if (failure.name == name) return failure;
  }
  return null;
}

/// 一种失败类型给人看的说法；界面按类型写下一步，不解析异常原文。
String shortTextOf(LlmFailure failure) => switch (failure) {
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

class LlmException implements Exception {
  const LlmException(this.failure, this.detail);

  final LlmFailure failure;
  final String detail;

  String get shortText => shortTextOf(failure);

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
