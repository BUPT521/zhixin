/// 一次未捕获的错误，用于本机诊断记录。
///
/// 只保存时间、来源、一条摘要与截断后的调用栈，不保存库里的学习内容。
class CrashEntry {
  const CrashEntry({
    required this.at,
    required this.kind,
    required this.message,
    required this.stack,
  });

  final DateTime at;

  /// 来源：`framework` 是 Flutter 框架错误，`platform` 是异步与引擎错误。
  final String kind;
  final String message;
  final String stack;
}

/// 崩溃记录的汇总：启动次数与最近的错误。
class CrashSummary {
  const CrashSummary({required this.launches, required this.crashes});

  final int launches;

  /// 最近的在前。
  final List<CrashEntry> crashes;

  int get count => crashes.length;

  CrashEntry? get latest => crashes.isEmpty ? null : crashes.first;

  static const CrashSummary empty = CrashSummary(launches: 0, crashes: []);
}
