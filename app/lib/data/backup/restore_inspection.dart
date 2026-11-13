/// 数据包的两种来源：版本库备份带提交历史与命名版本，旧格式的当前数据包没有。
enum RestorePackageKind { repository, currentData }

/// 整库恢复之前的预检结果：包内规模，用于恢复前的影响说明。
class RestoreInspection {
  const RestoreInspection({
    required this.kind,
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    this.head,
    this.commitCount = 0,
    this.namedCount = 0,
    this.rowCount = 0,
  });

  final RestorePackageKind kind;
  final int schemaVersion;
  final String appVersion;
  final String exportedAt;

  /// 版本库备份声明的 `HEAD`；旧格式的当前数据包没有提交历史，因此为空。
  final int? head;
  final int commitCount;
  final int namedCount;

  /// 旧格式数据包里业务表的行数合计；版本库备份不统计，保持为 0。
  final int rowCount;
}

/// 当前库的规模；恢复前的说明与恢复点里的记录共用这一份。
class RestoreSummary {
  const RestoreSummary({
    required this.head,
    required this.commitCount,
    required this.namedCount,
  });

  final int head;
  final int commitCount;
  final int namedCount;
}
