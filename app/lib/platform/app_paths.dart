import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/app_database.dart';
import '../domain/rules/attachments.dart';

/// 应用私有目录下的路径。图片与库分开存，导出时一起打包。
class AppPaths {
  const AppPaths(this.filesDir);

  final String filesDir;

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    return AppPaths(dir.path);
  }

  String get dbPath => p.join(filesDir, zhixinDbFileName);

  /// 语义索引库与业务库分开保存；丢失后可以从业务库重建。
  String get vectorIndexPath => p.join(filesDir, 'vector_index.db');

  String get imagesDir => p.join(filesDir, questionImagesDirName);

  String imagePath(String name) => p.join(imagesDir, name);

  /// 数据库里的图片名换成可读文件路径。
  String resolveImage(String stored) => resolveAttachment(filesDir, stored);

  Future<void> ensureDirectories() async {
    await Directory(imagesDir).create(recursive: true);
  }
}
