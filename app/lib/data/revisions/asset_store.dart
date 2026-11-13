import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../domain/rules/attachments.dart';
import '../../domain/rules/content_identity.dart';
import 'revision_models.dart';
import 'revision_value.dart';

/// 附件对象：字节按内容哈希去重，分块保存在同一个 SQLite 文件里。
///
/// 业务表与版本明细只保存 64 位十六进制哈希；图片在事务外读入内存、计算哈希，
/// 提交时与业务行、版本明细一起写入。进程中断时由 SQLite 事务整体回滚，不需要
/// 判断数据库提交前后哪些图片文件应当保留。
class AssetStore {
  AssetStore({this.chunkSize = 64 * 1024});

  final int chunkSize;

  static bool isHash(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value.trim());

  static String hashBytes(List<int> bytes) => contentHash(bytes);

  /// 写入一份附件；已经存在时直接复用，不重复写块。
  Future<bool> putBytes(
    DatabaseExecutor executor,
    String hash,
    Uint8List bytes,
  ) async {
    final existing = await executor.query(
      'asset_object',
      columns: ['hash'],
      where: 'hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;
    await executor.insert('asset_object', {
      'hash': hash,
      'byte_length': bytes.length,
      'created_at': DateTime.now().toIso8601String(),
    });
    for (var offset = 0, seq = 0; offset < bytes.length; seq++) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      await executor.insert('asset_chunk', {
        'hash': hash,
        'seq': seq,
        'data': bytes.sublist(offset, end),
      });
      offset = end;
    }
    return true;
  }

  Future<Uint8List?> readBytes(DatabaseExecutor executor, String hash) async {
    final object = await executor.query(
      'asset_object',
      columns: ['byte_length'],
      where: 'hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    if (object.isEmpty) return null;
    final length = object.first['byte_length']! as int;
    final chunks = await executor.query(
      'asset_chunk',
      columns: ['data'],
      where: 'hash = ?',
      whereArgs: [hash],
      orderBy: 'seq',
    );
    final builder = BytesBuilder(copy: false);
    for (final row in chunks) {
      final data = row['data'];
      if (data is Uint8List) {
        builder.add(data);
      } else if (data is List<int>) {
        builder.add(data);
      }
    }
    final bytes = builder.takeBytes();
    if (bytes.length != length) {
      throw StateError('附件 $hash 的块长度与记录不一致');
    }
    return bytes;
  }

  Future<bool> verify(DatabaseExecutor executor, String hash) async {
    try {
      final bytes = await readBytes(executor, hash);
      if (bytes == null) return false;
      return hashBytes(bytes) == hash;
    } catch (_) {
      return false;
    }
  }

  Future<Set<String>> objectHashes(DatabaseExecutor executor) async {
    final rows = await executor.query('asset_object', columns: ['hash']);
    return {for (final row in rows) row['hash']! as String};
  }

  /// 只保留仍被当前数据、保留提交、检查点或进行中任务引用的附件。
  Future<int> collectGarbage(
    DatabaseExecutor executor, {
    required Set<String> keep,
  }) async {
    final hashes = await objectHashes(executor);
    var removed = 0;
    for (final hash in hashes) {
      if (keep.contains(hash)) continue;
      await executor.delete(
        'asset_object',
        where: 'hash = ?',
        whereArgs: [hash],
      );
      removed++;
    }
    return removed;
  }

  /// 投影里被业务行引用的附件哈希。
  static Set<String> hashesInProjection(Projection projection) {
    final result = <String>{};
    for (final table in projection.values) {
      for (final row in table.values) {
        for (final value in row.values) {
          if (value.type != 'text') continue;
          final text = value.value as String;
          if (isHash(text)) {
            result.add(text);
            continue;
          }
          if (!text.startsWith('[')) continue;
          try {
            final decoded = jsonDecode(text);
            if (decoded is! List) continue;
            for (final item in decoded.whereType<String>()) {
              if (isHash(item)) result.add(item);
            }
          } catch (_) {
            // 非 JSON 的文本列与附件无关。
          }
        }
      }
    }
    return result;
  }

  /// 版本明细里引用到的附件哈希。
  static Set<String> hashesInChanges(Iterable<RevisionChange> changes) {
    final result = <String>{};
    for (final change in changes) {
      for (final row in [change.before, change.after]) {
        if (row == null) continue;
        for (final value in row.values) {
          if (value.type != 'text') continue;
          final text = value.value as String;
          if (isHash(text)) {
            result.add(text);
          } else if (text.startsWith('[')) {
            try {
              final decoded = jsonDecode(text);
              if (decoded is List) {
                for (final item in decoded.whereType<String>()) {
                  if (isHash(item)) result.add(item);
                }
              }
            } catch (_) {
              // 与业务无关的文本。
            }
          }
        }
      }
    }
    return result;
  }

  /// 检查点里的业务投影引用的附件哈希。
  static Set<String> hashesInProjectionJson(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return const {};
    final projection = <String, Map<String, TypedRow>>{};
    for (final table in decoded.entries) {
      final rows = table.value;
      if (rows is! Map) continue;
      final tableRows = <String, TypedRow>{};
      for (final row in rows.entries) {
        tableRows[row.key as String] = decodeTypedRow(jsonEncode(row.value));
      }
      projection[table.key as String] = tableRows;
    }
    return hashesInProjection(projection);
  }
}

/// 界面读取图片用的临时文件缓存；内容始终可以从数据库重建。
class AttachmentCache {
  AttachmentCache({required this.filesDir});

  final String Function() filesDir;

  String directory() => p.join(filesDir(), questionImagesDirName);

  String pathFor(String hash) => p.join(directory(), hash);

  Future<File> write(String hash, Uint8List bytes) async {
    final file = File(pathFor(hash));
    if (await file.exists() && await file.length() == bytes.length) {
      return file;
    }
    await Directory(directory()).create(recursive: true);
    final temporary = File(
      '${file.path}.partial-${DateTime.now().microsecondsSinceEpoch}',
    );
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    return file;
  }

  /// 把当前数据引用到的图片补回临时目录；缺失的对象会抛错。
  Future<void> rebuild(DatabaseExecutor executor, AssetStore assets) async {
    final rows = await executor.query(
      'message',
      columns: ['image_paths_json'],
      where: "image_paths_json IS NOT NULL AND image_paths_json != ''",
    );
    final hashes = <String>{};
    for (final row in rows) {
      final raw = row['image_paths_json'] as String?;
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) continue;
        for (final item in decoded.whereType<String>()) {
          if (AssetStore.isHash(item)) hashes.add(item);
        }
      } catch (_) {
        // 旧的非哈希引用不在这里处理。
      }
    }
    for (final hash in hashes) {
      final file = File(pathFor(hash));
      if (await file.exists()) continue;
      final bytes = await assets.readBytes(executor, hash);
      if (bytes == null) {
        throw StateError('图片附件缺失：$hash');
      }
      if (AssetStore.hashBytes(bytes) != hash) {
        throw StateError('图片附件校验失败：$hash');
      }
      await write(hash, bytes);
    }
  }

  /// 已缓存且被当前数据引用的图片文件；清理时只删没有引用的缓存。
  Future<Set<String>> cachedHashes() async {
    final directory = Directory(this.directory());
    if (!await directory.exists()) return const {};
    final result = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (AssetStore.isHash(name)) result.add(name);
    }
    return result;
  }
}
