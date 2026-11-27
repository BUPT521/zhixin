/// 可预期的失败：用户能理解、界面要原样显示原因的失败。
///
/// 讨论、作答与系统学习原先用 `StateError`、`ArgumentError` 承载“未找到这条
/// 讨论”“请输入问题或添加图片”这类可预期的失败；`failure_notice` 的已知类型
/// 表只收自定义异常与 `ServerProblem`，其余一律显示成“某个动作没有完成”，
/// 用户看不到原因。ADR-0021 要求异常只表示程序错误，可预期失败因此改抛这一种
/// 类型，由 `failure_notice` 原样取出说明。
///
/// 真正的内容格式错误仍用 `FormatException`（解析 JSON、协议字段、模型响应
/// 结构），程序自身的装配与不变量错误仍用 `StateError`。
final class UserFailure implements Exception {
  const UserFailure(this.message);

  /// 一句能直接显示给用户的说明。
  final String message;

  @override
  String toString() => message;
}
