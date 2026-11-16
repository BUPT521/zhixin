import 'dart:io';

import 'package:path/path.dart' as p;

import '../backup/restore_journal.dart';
import 'app_database.dart';
import '../../domain/rules/attachments.dart';

/// 删除本机全部学习数据（06 第 7 章“删除全部记录”）。
///
/// 调用前先关闭数据库与向量库句柄：`vectorIndexPath` 下的 collection 带着打开
/// 的句柄时删不掉，所以清空的调用方要先释放语义索引的句柄。模型配置存在
/// Keystore 里，会保留，库内的截止小时与自动保存设置随库删除后恢复默认。
/// 删除范围是库文件及其 WAL/SHM、题目图片、语义索引目录、旧的数据版本目录、
/// 恢复点、未完成的恢复记录与回滚目录。
Future<void> deleteLocalStudyData({
  required String filesDir,
  required String dbPath,
  required String vectorIndexPath,
}) async {
  final root = p.normalize(p.absolute(filesDir));
  final vectorIndex = Directory(p.normalize(p.absolute(vectorIndexPath)));
  if (!p.isWithin(root, vectorIndex.path)) {
    throw ArgumentError.value(
      vectorIndexPath,
      'vectorIndexPath',
      '语义索引目录必须位于本机数据目录下',
    );
  }

  for (final suffix in const ['', ...zhixinDbSideFiles]) {
    final file = File('$dbPath$suffix');
    if (await file.exists()) {
      await file.delete();
    }
  }

  final images = Directory(p.join(filesDir, questionImagesDirName));
  if (await images.exists()) {
    await images.delete(recursive: true);
  }

  // 语义索引里存着片段正文，是学习数据的派生物，与业务库一起删除。调用方
  // 已经释放句柄；仍然删不掉时留给下一次刷新清理，索引可以从业务库重建。
  if (await vectorIndex.exists()) {
    try {
      await vectorIndex.delete(recursive: true);
    } on FileSystemException {
      // 文件被系统占用时下次打开会重建或由刷新清空。
    }
  }

  // 旧格式的数据版本目录与当前的恢复点保存的都是整库副本，一并删除。
  for (final name in const ['data_versions', 'restore_points']) {
    final directory = Directory(p.join(filesDir, name));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  await RestoreJournal(filesDir).clear();

  final dir = Directory(filesDir);
  if (!await dir.exists()) return;
  await for (final entity in dir.list()) {
    if (entity is Directory &&
        p.basename(entity.path).startsWith('.restore-')) {
      await entity.delete(recursive: true);
    }
  }
}
