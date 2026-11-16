import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/app_database.dart';
import '../domain/rules/attachments.dart';

/// 应用私有目录下的路径。图片与库分开存，导出时一起打包。
class AppPaths {
  const AppPaths(this.filesDir, {required this.cacheDir});

  final String filesDir;

  /// 引擎日志等可随时清理的缓存目录。
  final String cacheDir;

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return AppPaths(dir.path, cacheDir: cache.path);
  }

  String get dbPath => p.join(filesDir, zhixinDbFileName);

  /// 语义索引按模型分目录保存；丢失后可以从业务库重建。
  String get vectorIndexPath => p.join(filesDir, 'vector_index');

  /// zvec 引擎的警告日志；不放进数据包，也不随业务数据导出。
  String get vectorLogPath => p.join(cacheDir, 'zvec_logs');

  String get imagesDir => p.join(filesDir, questionImagesDirName);

  String imagePath(String name) => p.join(imagesDir, name);

  /// 数据库里的图片名换成可读文件路径。
  String resolveImage(String stored) => resolveAttachment(filesDir, stored);

  Future<void> ensureDirectories() async {
    await Directory(imagesDir).create(recursive: true);
  }
}
