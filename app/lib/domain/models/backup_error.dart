/// 导出与恢复的可预期失败；界面上把 message 直接给用户看。
///
/// [detail] 只给本机诊断记录与排障用，例如底层异常类型或暂存目录；界面不显示
/// 它，避免把 SQL、文件路径或平台原文当成对用户说的话。
class BackupException implements Exception {
  const BackupException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}
