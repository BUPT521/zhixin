import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../atomic_file.dart';
import '../db/drift/tables.dart'
    show AttachmentReferenceKind, attachmentReferenceColumns;
import '../db/raw_executor.dart';
import '../db/sql.dart';

import '../../domain/rules/attachments.dart';
import '../../domain/rules/content_identity.dart';
import '../../domain/rules/time_format.dart';
import 'revision_models.dart';

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
    RawExecutor executor,
    String hash,
    Uint8List bytes,
  ) async {
    final existing = await executor.rawQuery(
      'SELECT hash FROM asset_object WHERE hash = ? LIMIT 1',
      [hash],
    );
    if (existing.isNotEmpty) return false;
    await executor.execute(
      'INSERT INTO asset_object (hash, byte_length, created_at) '
      'VALUES (?, ?, ?)',
      [hash, bytes.length, formatDateTime(DateTime.now())],
    );
    for (var offset = 0, seq = 0; offset < bytes.length; seq++) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      await executor.execute(
        'INSERT INTO asset_chunk (hash, seq, data) VALUES (?, ?, ?)',
        [hash, seq, bytes.sublist(offset, end)],
      );
      offset = end;
    }
    return true;
  }

  Future<Uint8List?> readBytes(RawExecutor executor, String hash) async {
    final object = await executor.rawQuery(
      'SELECT byte_length FROM asset_object WHERE hash = ? LIMIT 1',
      [hash],
    );
    if (object.isEmpty) return null;
    final length = object.first['byte_length']! as int;
    final chunks = await executor.rawQuery(
      'SELECT data FROM asset_chunk WHERE hash = ? ORDER BY seq',
      [hash],
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

  Future<bool> verify(RawExecutor executor, String hash) async {
    try {
      final bytes = await readBytes(executor, hash);
      if (bytes == null) return false;
      return hashBytes(bytes) == hash;
    } catch (_) {
      return false;
    }
  }

  Future<Set<String>> objectHashes(RawExecutor executor) async {
    final rows = await executor.rawQuery('SELECT hash FROM asset_object');
    return {for (final row in rows) row['hash']! as String};
  }

  /// 只保留 [keep] 里的附件对象，其余删除并返回删掉的个数。
  ///
  /// 调用方给出的 [keep] 是当前投影的附件哈希加上 `revision_asset_ref` 里仍
  /// 有主人的哈希，不再解码全部变更明细与检查点清单（ADR-0039 第 4 节泳道 B）。
  ///
  /// 删除用一条 `DELETE ... WHERE hash NOT IN (...)` 完成，附件多时不必逐条
  /// 执行语句；[keep] 超过 [_keepParameterLimit] 时退回逐条删除，不同平台的
  /// SQLite 变量上限不一样，结果相同，只是慢一些。
  Future<int> collectGarbage(
    RawExecutor executor, {
    required Set<String> keep,
  }) async {
    final hashes = await objectHashes(executor);
    final removed = hashes.difference(keep).length;
    if (removed == 0) return 0;
    if (keep.isEmpty) {
      await executor.execute('DELETE FROM asset_object');
      return removed;
    }
    if (keep.length > _keepParameterLimit) {
      for (final hash in hashes) {
        if (keep.contains(hash)) continue;
        await executor.execute('DELETE FROM asset_object WHERE hash = ?', [
          hash,
        ]);
      }
      return removed;
    }
    final placeholders = List.filled(keep.length, '?').join(', ');
    await executor.execute(
      'DELETE FROM asset_object WHERE hash NOT IN ($placeholders)',
      keep.toList(growable: false),
    );
    return removed;
  }

  /// 一条 DELETE 最多带多少个哈希；留出余量，不同平台的 SQLite 变量上限不同。
  static const int _keepParameterLimit = 20000;

  /// 投影里被业务行引用的附件哈希。
  ///
  /// 只读 [attachmentReferenceColumns] 声明过的列（审查 S17）：声明之外的文本
  /// 即使正好是 64 位十六进制，也当作用户内容，不算附件引用。`hash` 列只在整
  /// 个值是哈希时收；`hashArray` 列解码 JSON 数组后收其中形如哈希的字符串。
  static Set<String> hashesInProjection(Projection projection) {
    final result = <String>{};
    for (final declared in attachmentReferenceColumns.entries) {
      final (table, column) = _splitColumn(declared.key);
      final rows = projection[table];
      if (rows == null) continue;
      for (final row in rows.values) {
        _collectHash(result, row[column], declared.value);
      }
    }
    return result;
  }

  /// 版本明细里引用到的附件哈希。
  ///
  /// 与 [hashesInProjection] 同一口径：只读声明过的列。
  static Set<String> hashesInChanges(Iterable<RevisionChange> changes) {
    final result = <String>{};
    for (final change in changes) {
      for (final declared in attachmentReferenceColumns.entries) {
        final (table, column) = _splitColumn(declared.key);
        if (change.table != table) continue;
        for (final row in [change.before, change.after]) {
          if (row == null) continue;
          _collectHash(result, row[column], declared.value);
        }
      }
    }
    return result;
  }

  /// 把“表名.列名”拆成两段；声明格式不对时按不含点的列名处理。
  static (String, String) _splitColumn(String declared) {
    final separator = declared.lastIndexOf('.');
    if (separator <= 0) return (declared, '');
    return (
      declared.substring(0, separator),
      declared.substring(separator + 1),
    );
  }

  /// 按列的种类收一个值里的附件哈希；不是文本或形状不对时跳过。
  static void _collectHash(
    Set<String> result,
    RevisionValue? value,
    AttachmentReferenceKind kind,
  ) {
    if (value == null || value.type != RevisionValueType.text) return;
    final text = value.value as String;
    switch (kind) {
      case AttachmentReferenceKind.hash:
        final trimmed = text.trim();
        if (isHash(trimmed)) result.add(trimmed);
      case AttachmentReferenceKind.hashArray:
        if (!text.startsWith('[')) return;
        try {
          final decoded = jsonDecode(text);
          if (decoded is! List) return;
          for (final item in decoded.whereType<String>()) {
            final trimmed = item.trim();
            if (isHash(trimmed)) result.add(trimmed);
          }
        } catch (_) {
          // 损坏的 JSON 数组不提供引用，导入校验会按缺项处理。
        }
    }
  }
}

/// 界面读取图片用的临时文件缓存；内容始终可以从数据库重建。
class AttachmentCache {
  AttachmentCache({required this.filesDir});

  final String Function() filesDir;

  /// 全量补建的标记文件：还原、导入之前写入，补建成功后删除。
  ///
  /// 应用在补建之前退出时标记还在，下次启动在首帧之后补一次；平时启动只看
  /// 这个标记，不再全表扫描消息。
  static const String pendingFileName = 'attachment_cache.pending';

  String directory() => p.join(filesDir(), questionImagesDirName);

  String pathFor(String hash) => p.join(directory(), hash);

  File get _pendingFile => File(p.join(filesDir(), pendingFileName));

  bool get pendingRebuild => _pendingFile.existsSync();

  /// 没有缓存目录、目录为空也当作需要补建：系统清理过临时文件时不至于一直缺图。
  Future<bool> get needsRebuild async {
    if (pendingRebuild) return true;
    final directory = Directory(this.directory());
    if (!await directory.exists()) return true;
    return (await directory.list(followLinks: false).isEmpty);
  }

  Future<void> markPendingRebuild() async {
    await Directory(filesDir()).create(recursive: true);
    await _pendingFile.writeAsString('1', flush: true);
  }

  Future<void> clearPendingRebuild() async {
    try {
      if (await _pendingFile.exists()) await _pendingFile.delete();
    } catch (_) {
      // 删不掉时下次启动会再补建一次，不影响使用。
    }
  }

  /// 写入附件缓存：先写完整临时文件再改名，读到的要么是旧文件，要么是新文件。
  ///
  /// 临时后缀取 `AtomicFile.temporarySuffix`，与外观偏好、诊断开关这些本机小文件
  /// 同一种，不再按微秒另造一种；写入失败时删掉半份文件，下一次补建重新生成。
  Future<File> write(String hash, Uint8List bytes) async {
    final file = File(pathFor(hash));
    if (await file.exists() && await file.length() == bytes.length) {
      return file;
    }
    await Directory(directory()).create(recursive: true);
    final temporary = File('${file.path}${AtomicFile.temporarySuffix}');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    return file;
  }

  /// 把当前数据引用到的图片补回临时目录；缺失的对象会抛错。
  Future<void> rebuild(RawExecutor executor, AssetStore assets) async {
    final rows = await selectRows(
      executor,
      'message',
      columns: ['image_hashes_json'],
      where: "image_hashes_json IS NOT NULL AND image_hashes_json != ''",
    );
    final hashes = <String>{};
    for (final row in rows) {
      final raw = row['image_hashes_json'] as String?;
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
}
