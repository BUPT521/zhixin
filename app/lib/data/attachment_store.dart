import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/rules/attachments.dart';

/// 按数据库中的图片引用读取或回收附件文件。
class AttachmentStore {
  AttachmentStore({required this.filesDir});

  final String filesDir;

  Future<Set<String>> referencedPaths(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'message',
      columns: ['image_paths_json'],
      where: 'image_paths_json IS NOT NULL',
    );
    final root = p.normalize(
      p.absolute(p.join(filesDir, questionImagesDirName)),
    );
    final paths = <String>{};
    for (final row in rows) {
      final encoded = row['image_paths_json'] as String?;
      if (encoded == null || encoded.isEmpty) continue;
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! List) continue;
        for (final value in decoded.whereType<String>()) {
          final path = p.normalize(
            p.absolute(resolveAttachment(filesDir, value)),
          );
          if (p.isWithin(root, path)) paths.add(path);
        }
      } catch (_) {
        // 无法解析的路径记录不影响恢复或应用启动，也不会被当作有效引用。
      }
    }
    return paths;
  }

  Future<void> cleanupUnreferenced(DatabaseExecutor executor) async {
    final root = Directory(p.join(filesDir, questionImagesDirName));
    if (!await root.exists()) return;
    final rootPath = p.normalize(p.absolute(root.path));
    final referenced = await referencedPaths(executor);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = p.normalize(p.absolute(entity.path));
      if (!p.isWithin(rootPath, path) || referenced.contains(path)) continue;
      await entity.delete();
    }
  }

  /// 仅检查本次操作涉及的文件，避免清理其他页面尚未写入记录的图片。
  Future<void> cleanupCandidates(
    DatabaseExecutor executor,
    Iterable<String> candidates,
  ) async {
    final candidatePaths = candidates.toSet();
    if (candidatePaths.isEmpty) return;

    final rootPath = p.normalize(
      p.absolute(p.join(filesDir, questionImagesDirName)),
    );
    final referenced = await referencedPaths(executor);
    for (final candidate in candidatePaths) {
      final path = p.normalize(
        p.absolute(resolveAttachment(filesDir, candidate)),
      );
      if (!p.isWithin(rootPath, path) || referenced.contains(path)) continue;
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
