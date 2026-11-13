import 'dart:io';

import 'package:path/path.dart' as p;

import '../backup/restore_journal.dart';
import 'app_database.dart';
import '../../domain/rules/attachments.dart';

/// 删除本机全部学习数据（06 第 7 章“删除全部记录”）。
///
/// 调用前先关闭数据库；模型配置存在 Keystore 里，会保留，库内的截止小时与
/// 自动保存设置随库删除后恢复默认。
/// 删除范围是库文件及其 WAL/SHM、题目图片、旧的数据版本目录、恢复点、
/// 未完成的恢复记录与回滚目录。
Future<void> deleteLocalStudyData({
  required String filesDir,
  required String dbPath,
}) async {
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
