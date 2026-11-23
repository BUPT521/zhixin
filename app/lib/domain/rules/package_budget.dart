/// 一个数据包本机接受的大小上限，与服务端的 `ZHIXIN_MAX_BACKUP_BYTES` 一致。
///
/// 上传、下载与导入都在把包读进内存之前先看这个上限：超过的文件直接拒绝，
/// 不读进内存再失败。包内的条目数、单条目大小与压缩比另由解压预算约束。
const int dataPackageMaxBytes = 256 * 1024 * 1024;

/// 数据包内的条目数上限；目录条目也计入。
const int dataPackageMaxEntries = 20000;

/// 包内数据库解压后的上限。
const int dataPackageMaxDatabaseBytes = 256 * 1024 * 1024;

/// 单个附件解压后的上限，与服务端的 `ZHIXIN_MAX_ATTACHMENT_BYTES` 一致。
const int dataPackageMaxAttachmentBytes = 32 * 1024 * 1024;

/// 所有条目解压后的累计大小上限。
const int dataPackageMaxUncompressedBytes = 512 * 1024 * 1024;

/// 累计解压大小与压缩包字节数的比值上限，压缩包字节数为 0 时不判断。
const int dataPackageMaxCompressionRatio = 100;

/// 数据包里的数据库条目名。
const String dataPackageDatabaseEntry = 'zhixin.db';

/// 当前数据包的附件前缀。
const String dataPackageAssetPrefix = 'assets/';

/// 旧格式备份里题目图片的前缀。
const String dataPackageImagePrefix = 'question_images/';

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

/// 上限值的写法：正好是整 MiB 时写成 MiB，其余沿用 [formatPackageSize]。
String _formatPackageLimit(int bytes) => bytes % (1024 * 1024) == 0
    ? '${bytes ~/ (1024 * 1024)} MiB'
    : formatPackageSize(bytes);

/// zip 头里的一项元数据，只描述条目而不包含内容。
class PackageBudgetEntry {
  const PackageBudgetEntry({
    required this.name,
    required this.uncompressedBytes,
    required this.isDirectory,
  });

  final String name;
  final int uncompressedBytes;
  final bool isDirectory;
}

/// 解压预算：在读取条目内容之前，按压缩包大小与 zip 头里的元数据判断是否超限。
///
/// 上限做成可覆盖的构造参数，测试用小上限构造超限包；默认值取本文件顶部的常量。
class PackageBudget {
  const PackageBudget({
    this.maxPackageBytes = dataPackageMaxBytes,
    this.maxEntries = dataPackageMaxEntries,
    this.maxDatabaseBytes = dataPackageMaxDatabaseBytes,
    this.maxAttachmentBytes = dataPackageMaxAttachmentBytes,
    this.maxUncompressedBytes = dataPackageMaxUncompressedBytes,
    this.maxCompressionRatio = dataPackageMaxCompressionRatio,
  });

  final int maxPackageBytes;
  final int maxEntries;
  final int maxDatabaseBytes;
  final int maxAttachmentBytes;
  final int maxUncompressedBytes;
  final int maxCompressionRatio;

  /// 超限时返回一句中文说明，未超限返回 null。
  ///
  /// 只读取 [entries] 里的名字与大小，不读取条目内容；调用方在解出目录之后、
  /// 读取 manifest、数据库或附件之前调用。
  String? problem({
    required int packageBytes,
    required Iterable<PackageBudgetEntry> entries,
  }) {
    if (packageBytes > maxPackageBytes) {
      return '这个数据包约 ${formatPackageSize(packageBytes)}，'
          '超过本机接收的上限 ${_formatPackageLimit(maxPackageBytes)}，没有读取。';
    }
    final items = entries.toList(growable: false);
    if (items.length > maxEntries) {
      return '数据包有 ${items.length} 个条目，'
          '超过条目数上限 $maxEntries，没有读取。';
    }
    var total = 0;
    for (final item in items) {
      if (item.isDirectory) continue;
      total += item.uncompressedBytes;
      if (item.name == dataPackageDatabaseEntry &&
          item.uncompressedBytes > maxDatabaseBytes) {
        return '数据包里的 $dataPackageDatabaseEntry 有 '
            '${formatPackageSize(item.uncompressedBytes)}，'
            '超过数据库上限 ${_formatPackageLimit(maxDatabaseBytes)}，没有读取。';
      }
      if (_isAttachment(item.name) &&
          item.uncompressedBytes > maxAttachmentBytes) {
        return '数据包里的附件 ${item.name} 有 '
            '${formatPackageSize(item.uncompressedBytes)}，'
            '超过单附件上限 ${_formatPackageLimit(maxAttachmentBytes)}，没有读取。';
      }
    }
    if (total > maxUncompressedBytes) {
      return '数据包解开后共 ${formatPackageSize(total)}，'
          '超过累计解压上限 ${_formatPackageLimit(maxUncompressedBytes)}，没有读取。';
    }
    if (packageBytes > 0 && total > packageBytes * maxCompressionRatio) {
      final ratio = (total / packageBytes).toStringAsFixed(0);
      return '数据包解开后共 ${formatPackageSize(total)}，是压缩包大小的 $ratio 倍，'
          '超过压缩比上限 $maxCompressionRatio，没有读取。';
    }
    return null;
  }

  bool _isAttachment(String name) =>
      name.startsWith(dataPackageAssetPrefix) ||
      name.startsWith(dataPackageImagePrefix);
}
