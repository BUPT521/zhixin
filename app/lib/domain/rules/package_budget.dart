/// 一个数据包本机接受的大小上限，与服务端的 `ZHIXIN_MAX_BACKUP_BYTES` 一致。
///
/// 上传、下载与导入都在把包读进内存之前先看这个上限：超过的文件直接拒绝，
/// 不读进内存再失败。包内的条目数、单条目大小与压缩比另由解压预算约束。
const int dataPackageMaxBytes = 256 * 1024 * 1024;

/// 超过上限时给用户看的一句话，[bytes] 是实际大小。
String dataPackageTooLargeMessage(int bytes) =>
    '这个数据包约 ${formatPackageSize(bytes)}，超过本机接收的上限 256 MiB，没有读取。';

/// 文件大小的简短写法，用于提示与确认框。
String formatPackageSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}
