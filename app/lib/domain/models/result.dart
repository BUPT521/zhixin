import '../rules/notices.dart';
import 'backup_error.dart';

/// 一次可能失败的操作的结果：成功带值，失败带原因。
///
/// 读路径原先用 null、bool、自建结果类与异常混着表达失败，调用方分不清“没有
/// 数据”“可预期的失败”与“程序错误”。这里先给数据包与恢复的预检、恢复结果
/// 使用，后续按服务逐步替换；程序错误仍然抛异常，只有本来就要给用户一句说明
/// 的失败才进入 [Failure]。
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;

  /// 成功时的值；失败时为空。
  T? get valueOrNull => switch (this) {
    Success<T>(:final value) => value,
    Failure<T>() => null,
  };

  /// 失败原因；成功时为空。
  FailureReason? get failureOrNull => switch (this) {
    Success<T>() => null,
    Failure<T>(:final reason) => reason,
  };

  /// 读取结果中的值：失败时返回调用方给的兜底值。
  ///
  /// 读取失败本身仍要由调用方按 [failureOrNull] 判断；只有“失败时沿用上一份
  /// 内容”这类场景才用它。
  T fallback(T value) => switch (this) {
    Success<T>(:final value) => value,
    Failure<T>() => value,
  };
}

final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;
}

final class Failure<T> extends Result<T> {
  const Failure(this.reason);

  final FailureReason reason;
}

/// 一次失败的原因：一句能直接显示的说明，以及可选的分类。
///
/// [notice] 放回答流程的 [Notice]；[failureName] 放模型失败类型名
/// （`LlmFailure.name`），域层不依赖 ai/，由应用层填入；数据包与恢复的可预期
/// 失败只有一句说明，放在 [message]，[detail] 留给本机诊断，界面不显示。
class FailureReason {
  const FailureReason(
    this.message, {
    this.notice,
    this.failureName,
    this.detail,
  });

  /// 把可预期的备份失败换成失败原因；说明与诊断细节原样保留。
  factory FailureReason.backup(BackupException error) =>
      FailureReason(error.message, detail: error.detail);

  /// 能直接显示给用户的一句说明。
  final String message;
  final Notice? notice;
  final String? failureName;
  final String? detail;

  bool get isEmpty => message.trim().isEmpty;
}
