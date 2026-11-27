/// 一份恢复点：整库恢复之前自动保存的当前状态。
///
/// [path] 指向一份版本库备份 zip，与恢复入口使用同一种包；[head]、[commitCount]
/// 与 [namedCount] 是保存时的规模，即使没有说明文件也能从文件名与修改时间认出来。
class RestorePoint {
  const RestorePoint({
    required this.path,
    required this.createdAt,
    required this.head,
    required this.commitCount,
    required this.namedCount,
    required this.reason,
    required this.size,
  });

  final String path;
  final DateTime createdAt;
  final int? head;
  final int commitCount;
  final int namedCount;
  final String reason;
  final int size;
}
