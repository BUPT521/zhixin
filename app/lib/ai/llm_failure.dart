import 'dart:async';
import 'dart:convert';

/// 一次模型调用的失败类型；界面只显示一句人话，不把 key 或响应体带出去。
enum LlmFailure {
  notConfigured,
  offline,
  timeout,
  auth,
  contactUnverified,
  rateLimited,

  /// 上游或实例短时繁忙，等一会儿重试即可，与当天额度用完不同。
  busy,
  badResponse,
  truncated,

  /// 模型按内容政策拒答：没有正文，只有一句拒答说明。
  refused,
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
  LlmFailure.notConfigured => '还没有登录知新服务',
  LlmFailure.offline => '网络不可用',
  LlmFailure.timeout => '请求超时',
  LlmFailure.auth => '登录已失效或没有访问权限',
  LlmFailure.contactUnverified => '还没有确认任何登录方式，托管额度未开放',
  LlmFailure.rateLimited => '调用额度或频率受限',
  LlmFailure.busy => '模型服务暂时繁忙',
  LlmFailure.badResponse => '模型回复格式无法识别',
  LlmFailure.truncated => '回答被截断，请再试一次',
  LlmFailure.refused => '这个问题模型不能回答，请换一种问法',
  LlmFailure.toolStalled => '工具调用未能推进回答',
  LlmFailure.contextLimit => '本轮内容超过模型上下文预算',
  LlmFailure.cancelled => '已停止生成',
  LlmFailure.server => '模型服务出错',
  LlmFailure.toolUnsupported => '服务端没有接受这次工具调用',
  LlmFailure.unknown => '调用失败',
};

class LlmException implements Exception {
  const LlmException(this.failure, this.detail, {this.retryAfter});

  final LlmFailure failure;
  final String detail;

  /// 服务端要求等待的时长；只有短时繁忙时由 `Retry-After` 给出，其余为 null。
  final Duration? retryAfter;

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

/// 同一轮回答共用的截止时间、分阶段期限与取消信号，覆盖工具后的请求、流式
/// 回退与重试等待。
///
/// 超时只在预算里定义一处：整轮回答的 [timeout]、流式响应等待首个有效事件的
/// [firstOutputTimeout]、首个事件之后相邻事件之间的 [idleTimeout]。传输层
/// 不再另设时限，按这一份期限执行。
class LlmRequestBudget {
  LlmRequestBudget({
    this.timeout = defaultTimeout,
    this.firstOutputTimeout = defaultFirstOutputTimeout,
    this.idleTimeout = defaultIdleTimeout,
    this.cancelToken,
  });

  /// 一次讨论回答：整段 90 秒，首字与空闲沿用默认值。
  factory LlmRequestBudget.answer({LlmCancelToken? cancelToken}) =>
      LlmRequestBudget(
        timeout: const Duration(seconds: 90),
        cancelToken: cancelToken,
      );

  /// 设置页连接测试：只发一次最小请求，15 秒内必须返回。
  factory LlmRequestBudget.probe() =>
      LlmRequestBudget(timeout: const Duration(seconds: 15));

  /// 没有另外指定预算的一次普通请求。
  factory LlmRequestBudget.request({LlmCancelToken? cancelToken}) =>
      LlmRequestBudget(cancelToken: cancelToken);

  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration defaultFirstOutputTimeout = Duration(seconds: 30);
  static const Duration defaultIdleTimeout = Duration(seconds: 20);

  final Duration timeout;
  final Duration firstOutputTimeout;
  final Duration idleTimeout;
  final LlmCancelToken? cancelToken;
  final Stopwatch _clock = Stopwatch()..start();
  final _expired = Completer<void>();
  late final Future<void> abortTrigger = Future.any<void>([
    _expired.future,
    if (cancelToken case final token?) token.whenCancelled,
  ]);

  /// 按同一组期限新建一份预算，计时从零开始；构造时给的预算因此可以当作
  /// 一份期限模板，每次请求各自计时。
  LlmRequestBudget restart({LlmCancelToken? cancelToken}) => LlmRequestBudget(
    timeout: timeout,
    firstOutputTimeout: firstOutputTimeout,
    idleTimeout: idleTimeout,
    cancelToken: cancelToken,
  );

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

  /// 这一轮还剩多少时间，已经用完时为 0。传输层把它放进请求头交给服务端，
  /// 服务端据此约束等待首个有效输出与整段回答的时限，两端的期限因此不会互相
  /// 等待到对方先结束。
  Duration get remaining {
    if (cancelToken?.isCancelled ?? false) return Duration.zero;
    final value = timeout - _clock.elapsed;
    return value <= Duration.zero ? Duration.zero : value;
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

/// 流式响应的一段：正文、工具参数与截断标记分开到达，互不影响。
class LlmDelta {
  const LlmDelta({
    this.text = '',
    this.toolCalls = const [],
    this.truncated = false,
  });

  final String text;
  final List<LlmToolCallDelta> toolCalls;

  bool get hasOutput => text.isNotEmpty || toolCalls.isNotEmpty;

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
  });

  final String text;
  final List<LlmToolCall> toolCalls;
  final int tokensIn;
  final int tokensOut;

  /// 模型因输出上限结束；[text] 是已经生成的部分，[toolCalls] 为空。
  final bool truncated;
}
