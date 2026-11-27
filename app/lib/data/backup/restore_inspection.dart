import 'dart:typed_data';

/// 数据包的两种来源：版本库备份带提交历史与命名版本，旧格式的当前数据包没有。
enum RestorePackageKind { repository, currentData }

/// 整库恢复的预检产物：包内规模、已经解出并校验过的库与附件，以及替换之后
/// 用来核对的行数。
///
/// 版本库备份与当前数据包都经这一个模型报告，不再各自声明一份形状相同的结果：
/// 两种包的 `schemaVersion` 都取包内已经校验过的值。恢复入口只接受它，不再接收
/// 原始字节，因此同一次恢复只解包一次、只做一次完整性校验；界面在确认框之前
/// 拿到的就是这份产物。
class RestoreInspection {
  const RestoreInspection({
    required this.kind,
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.databaseBytes,
    required this.expectedRows,
    this.images = const {},
    this.head,
    this.commitCount = 0,
    this.namedCount = 0,
  });

  final RestorePackageKind kind;
  final int schemaVersion;
  final String appVersion;
  final String exportedAt;

  /// 包内 `zhixin.db` 的字节；恢复时直接写入，不再回读数据包。
  final Uint8List databaseBytes;

  /// 包内的附件文件；版本库备份把附件存在库里，这里是空表，恢复时清掉旧的
  /// 图片目录之后由图片缓存从库里重建。
  final Map<String, Uint8List> images;

  /// 包内各业务表的行数；替换之后核对新库没有少记录。
  final Map<String, int> expectedRows;

  /// 包内业务表的行数合计，用于恢复前的影响说明。
  int get rowCount => expectedRows.values.fold(0, (sum, value) => sum + value);

  /// 版本库备份声明的 `HEAD`；旧格式的当前数据包没有提交历史，因此为空。
  final int? head;
  final int commitCount;
  final int namedCount;
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
