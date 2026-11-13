import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../domain/rules/time_policy.dart';
import '../backup/backup_manifest.dart';
import '../db/schema_objects.dart';
import 'asset_store.dart';
import 'revision_engine.dart';
import 'revision_models.dart';

/// 当前数据包与版本库备份。
///
/// 当前数据包只包含干净的业务投影与仍被引用的附件，导入时通过同一个数据入口
/// 追加一条提交；版本库备份是 `VACUUM INTO` 生成的整库快照，包含 `HEAD`、
/// 保留历史、命名版本与附件，交回现有恢复流程替换连接。两类数据包都不含
/// 诊断记录与密钥。
class RevisionPackageService {
  RevisionPackageService({
    required this.engine,
    required this.assets,
    required this.factory,
    required this.schemaVersion,
    required this.appVersion,
    this.chunkSize = 64 * 1024,
    this.clock = systemClock,
  });

  final RevisionEngine engine;
  final AssetStore assets;
  final DatabaseFactory factory;
  final int schemaVersion;
  final String appVersion;
  final int chunkSize;
  final Clock clock;

  static const String _manifestEntry = 'manifest.json';
  static const String _dataEntry = 'data.json';
  static const String _assetPrefix = 'assets/';
  static const String _databaseEntry = 'zhixin.db';

  /// 导出当前的业务投影与附件。
  ///
  /// 包内清单按数据库引用生成；有附件读不出或哈希不符时中止导出并列出缺项，
  /// 不生成一个看起来完整的包。否则用户要等到换机恢复时才会发现图片缺失。
  Future<void> exportCurrent(Database db, String outputPath) async {
    final projection = await engine.readProjection(db);
    final projectionJson = encodeProjection(projection);
    final hashes = AssetStore.hashesInProjection(projection).toList()..sort();
    final missing = <String>[];
    for (final hash in hashes) {
      if (!await assets.verify(db, hash)) missing.add(hash);
    }
    if (missing.isNotEmpty) {
      throw StateError(
        '导出中止：数据库引用的 ${missing.length} 个附件缺失或校验失败'
        '（${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}）',
      );
    }
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    if (await output.exists()) await output.delete();
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      encoder.create(output.path, level: 6);
      opened = true;
      final manifest = {
        'kind': 'current_data',
        'schema_version': schemaVersion,
        'app_version': appVersion,
        'exported_at': clock().toUtc().toIso8601String(),
        'projection_sha256': sha256
            .convert(utf8.encode(projectionJson))
            .toString(),
        'asset_count': hashes.length,
        'assets': hashes,
      };
      encoder.addArchiveFile(
        ArchiveFile.bytes(
          _manifestEntry,
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
        ),
      );
      encoder.addArchiveFile(
        ArchiveFile.bytes(_dataEntry, utf8.encode(projectionJson)),
      );
      for (final hash in hashes) {
        final bytes = await assets.readBytes(db, hash);
        if (bytes == null) throw StateError('附件 $hash 无法读取');
        encoder.addArchiveFile(ArchiveFile.bytes('$_assetPrefix$hash', bytes));
      }
      await encoder.close();
      opened = false;
    } catch (error) {
      if (opened) {
        try {
          await encoder.close();
        } catch (_) {
          // 保留原始错误。
        }
      }
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  /// 导入当前数据包；目标库必须仍是预览时的 `HEAD`。
  Future<RevisionCommit> importCurrent(
    Database db,
    Uint8List bytes, {
    required int expectedHead,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestFile = archive.findFile(_manifestEntry);
    final dataFile = archive.findFile(_dataEntry);
    if (manifestFile == null || dataFile == null) {
      throw const FormatException('当前数据包缺少 manifest.json 或 data.json');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
    if (manifest is! Map || manifest['kind'] != 'current_data') {
      throw const FormatException('不是当前数据包');
    }
    final version = manifest['schema_version'];
    if (version != schemaVersion) {
      throw FormatException('数据包是 schema v$version，当前只接受 v$schemaVersion');
    }
    final projectionJson = utf8.decode(dataFile.content as List<int>);
    final checksum = manifest['projection_sha256'];
    if (checksum != sha256.convert(utf8.encode(projectionJson)).toString()) {
      throw const FormatException('当前数据包校验值不一致');
    }
    final projection = decodeProjection(projectionJson);
    final required = AssetStore.hashesInProjection(projection).toList()..sort();
    final declared = manifest['assets'];
    final declaredHashes = declared is List
        ? (declared.whereType<String>().toList()..sort())
        : const <String>[];
    if (declaredHashes.join(',') != required.join(',')) {
      throw const FormatException('当前数据包附件清单不一致');
    }
    final attachmentBytes = <String, Uint8List>{};
    for (final hash in required) {
      final file = archive.findFile('$_assetPrefix$hash');
      final content = file?.content;
      if (content == null) throw FormatException('缺少附件 $hash');
      final data = Uint8List.fromList(content as List<int>);
      if (AssetStore.hashBytes(data) != hash) {
        throw FormatException('附件 $hash 校验失败');
      }
      attachmentBytes[hash] = data;
    }
    return engine.importProjection(
      db,
      projection,
      expectedHead: expectedHead,
      attachments: attachmentBytes,
    );
  }

  /// 版本库备份：`VACUUM INTO` 生成一致的暂存库，校验后与 manifest 一起发布。
  Future<void> backupRepository(Database db, String outputPath) async {
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    final temporaryDb = File(
      '${output.path}.partial-${clock().millisecondsSinceEpoch}.db',
    );
    if (await temporaryDb.exists()) await temporaryDb.delete();
    Database? copy;
    try {
      await db.rawQuery('VACUUM INTO ?', [temporaryDb.path]);
      copy = await factory.openDatabase(
        temporaryDb.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final integrity = await copy.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty ||
          integrity.first.values.first?.toString() != 'ok') {
        throw StateError('版本库备份完整性校验失败');
      }
      final version = await copy.rawQuery('PRAGMA user_version');
      if (version.first.values.first != schemaVersion) {
        throw StateError('版本库备份的 schema 与当前不一致');
      }
      final unexpected = await unexpectedDatabaseObjects(copy);
      if (unexpected.isNotEmpty) {
        throw StateError(
          '备份中止：数据库带有当前程序不认识的'
          '${unexpected.take(5).join('、')}${unexpected.length > 5 ? ' 等' : ''}',
        );
      }
      final head = await engine.headId(copy);
      final missing = await engine.verifyAssets(copy);
      if (missing.isNotEmpty) {
        throw StateError(
          '备份中止：数据库引用的 ${missing.length} 个附件缺失或校验失败'
          '（${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}）',
        );
      }
      final digest = sha256.convert(await temporaryDb.readAsBytes()).toString();
      final manifest = BackupManifest(
        schemaVersion: schemaVersion,
        appVersion: appVersion,
        exportedAt: clock().toUtc().toIso8601String(),
        imageCount: 0,
        images: const {},
      );
      final encoder = ZipFileEncoder();
      var opened = false;
      try {
        if (await output.exists()) await output.delete();
        encoder.create(output.path, level: 6);
        opened = true;
        encoder.addArchiveFile(
          ArchiveFile.bytes(
            _manifestEntry,
            utf8.encode(
              const JsonEncoder.withIndent('  ').convert({
                ...manifest.toJson(),
                'kind': 'repository',
                'head': head,
                'database_sha256': digest,
              }),
            ),
          ),
        );
        await encoder.addFile(temporaryDb, _databaseEntry);
        await encoder.close();
        opened = false;
      } catch (_) {
        if (opened) {
          try {
            await encoder.close();
          } catch (_) {
            // 保留原始错误。
          }
        }
        if (await output.exists()) await output.delete();
        rethrow;
      }
    } finally {
      await copy?.close();
      if (await temporaryDb.exists()) await temporaryDb.delete();
    }
  }

  /// 备份文件里声明的 `HEAD`；用于恢复前的提示与校验。
  Future<int?> repositoryHead(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.findFile(_manifestEntry);
    if (file == null) return null;
    final decoded = jsonDecode(utf8.decode(file.content as List<int>));
    if (decoded is! Map) return null;
    final head = decoded['head'];
    return head is int ? head : null;
  }

  /// 恢复版本库之前先在暂存处核对：完整性、schema、`HEAD`、可重建性与附件。
  ///
  /// 返回 false 表示这不是版本库备份（仍可交给旧的当前数据包恢复流程）；
  /// 声明为版本库但校验失败时直接抛错，调用方不得覆盖当前库。
  Future<bool> validateRepositoryBytes(Uint8List bytes) async =>
      await inspectRepository(bytes) != null;

  /// 预检版本库备份：校验通过后返回包内 `HEAD`、提交条数、命名版本数与导出时间。
  ///
  /// 不是版本库备份时返回 null；声明为版本库但校验失败时抛出 [FormatException]。
  /// 恢复入口先调用它，向用户说明包内规模，再决定是否覆盖当前库。
  Future<RepositoryInspection?> inspectRepository(Uint8List bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('这个文件不是知新导出的 zip 数据包');
    }
    final manifestFile = archive.findFile(_manifestEntry);
    if (manifestFile == null) return null;
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
    if (manifest is! Map || manifest['kind'] != 'repository') return null;
    final version = manifest['schema_version'];
    if (version != schemaVersion) {
      throw FormatException('版本库备份是 schema v$version，当前只接受 v$schemaVersion');
    }
    final dbFile = archive.findFile(_databaseEntry);
    if (dbFile == null) throw const FormatException('版本库备份缺少 zhixin.db');
    final data = Uint8List.fromList(dbFile.content as List<int>);
    final digest = manifest['database_sha256'];
    if (digest is String && sha256.convert(data).toString() != digest) {
      throw const FormatException('版本库备份的数据库校验值不一致');
    }
    final dir = await Directory.systemTemp.createTemp(
      'zhixin_repository_check_',
    );
    final path = p.join(dir.path, 'backup.db');
    Database? copy;
    try {
      await File(path).writeAsBytes(data, flush: true);
      copy = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final integrity = await copy.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty ||
          integrity.first.values.first?.toString() != 'ok') {
        throw const FormatException('版本库备份完整性校验失败');
      }
      final userVersion = await copy.rawQuery('PRAGMA user_version');
      if (userVersion.first.values.first != schemaVersion) {
        throw const FormatException('版本库备份的 schema 与当前不一致');
      }
      final unexpected = await unexpectedDatabaseObjects(copy);
      if (unexpected.isNotEmpty) {
        throw FormatException(
          '版本库备份带有当前程序不认识的'
          '${unexpected.take(5).join('、')}${unexpected.length > 5 ? ' 等' : ''}',
        );
      }
      final head = await engine.headId(copy);
      final declaredHead = manifest['head'];
      if (declaredHead is int && declaredHead != head) {
        throw const FormatException('版本库备份声明的 HEAD 与数据库不一致');
      }
      await engine.projectionAt(copy, head);
      final missing = await engine.verifyAssets(copy);
      if (missing.isNotEmpty) {
        throw FormatException(
          '版本库备份的 ${missing.length} 个附件缺失或校验失败'
          '（${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}）',
        );
      }
      final commits = await copy.rawQuery(
        'SELECT COUNT(*) AS count FROM revision_commit',
      );
      final names = await copy.rawQuery(
        'SELECT COUNT(*) AS count FROM revision_ref WHERE name != ?',
        [RevisionRef.headName],
      );
      int countOf(List<Map<String, Object?>> rows) =>
          rows.isEmpty ? 0 : (rows.first['count'] as int? ?? 0);
      final exportedAt = manifest['exported_at'];
      final appVersionOfBackup = manifest['app_version'];
      return RepositoryInspection(
        head: head,
        commitCount: countOf(commits),
        namedCount: countOf(names),
        exportedAt: exportedAt is String ? exportedAt : '',
        appVersion: appVersionOfBackup is String ? appVersionOfBackup : '',
      );
    } finally {
      await copy?.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  String assetPath(String hash) => p.join(_assetPrefix, hash);
}

/// 版本库备份预检的结果：包内规模与导出信息，用于恢复前的影响说明。
class RepositoryInspection {
  const RepositoryInspection({
    required this.head,
    required this.commitCount,
    required this.namedCount,
    required this.exportedAt,
    required this.appVersion,
  });

  final int head;
  final int commitCount;
  final int namedCount;
  final String exportedAt;
  final String appVersion;
}
