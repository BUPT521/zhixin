import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/rules/package_budget.dart';
import '../../domain/rules/time_policy.dart';
import '../backup/backup_manifest.dart';
import '../../domain/models/restore_inspection.dart';
import '../backup/restore_validation.dart';
import 'asset_store.dart';
import 'revision_engine.dart';
import '../db/raw_executor.dart';
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
    required this.schemaVersion,
    required this.appVersion,
    this.budget = const PackageBudget(),
    this.clock = systemClock,
  });

  final RevisionEngine engine;
  final AssetStore assets;
  final int schemaVersion;
  final String appVersion;

  /// 解压预算；当前数据包在读取 manifest、data 与附件之前执行，
  /// 版本库备份在确认 kind 与 schema 之后、读取 `zhixin.db` 之前执行。
  final PackageBudget budget;
  final Clock clock;

  static const String _manifestEntry = 'manifest.json';
  static const String _dataEntry = 'data.json';
  static const String _assetPrefix = 'assets/';
  static const String _databaseEntry = 'zhixin.db';

  /// 导出当前的业务投影与附件。
  ///
  /// 包内清单按数据库引用生成；有附件读不出或哈希不符时中止导出并列出缺项，
  /// 不生成一个看起来完整的包。否则用户要等到换机恢复时才会发现图片缺失。
  Future<void> exportCurrent(RawDatabase db, String outputPath) async {
    final projection = await engine.readProjection(db);
    final projectionJson = encodeProjection(projection);
    final hashes = AssetStore.hashesInProjection(projection).toList()..sort();
    final missing = <String>[];
    for (final hash in hashes) {
      if (!await assets.verify(db, hash)) missing.add(hash);
    }
    if (missing.isNotEmpty) {
      throw StateError('导出中止：${assetProblem(missing)}');
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
    RawDatabase db,
    Uint8List bytes, {
    required int expectedHead,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    _checkBudget(archive, bytes.length);
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
  Future<void> backupRepository(RawDatabase db, String outputPath) async {
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    final temporaryDb = File(
      '${output.path}.partial-${clock().millisecondsSinceEpoch}.db',
    );
    if (await temporaryDb.exists()) await temporaryDb.delete();
    RawDatabase? copy;
    try {
      await db.execute('VACUUM INTO ?', [temporaryDb.path]);
      copy = openReadOnlyDatabase(temporaryDb.path);
      final stagedProblem = await _stagedProblem(temporaryDb.path);
      if (stagedProblem != null) throw StateError('备份中止：$stagedProblem');
      final head = await engine.headId(copy);
      final assetsProblem = assetProblem(await engine.verifyAssets(copy));
      if (assetsProblem != null) {
        throw StateError('备份中止：$assetsProblem');
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

  /// 预检版本库备份：校验通过后返回包内规模、导出信息与可以恢复的字节。
  ///
  /// 不是版本库备份时返回 null；声明为版本库但校验失败时抛出 [FormatException]。
  /// 恢复入口先调用它，向用户说明包内规模，再决定是否覆盖当前库。结果与当前
  /// 数据包共用 [RestoreInspection]，`schemaVersion` 取 manifest 里已经核对过的值。
  Future<RestoreInspection?> inspectRepository(Uint8List bytes) async {
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
    if (version is! int || version != schemaVersion) {
      throw FormatException('版本库备份是 schema v$version，当前只接受 v$schemaVersion');
    }
    _checkBudget(archive, bytes.length);
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
    RawDatabase? copy;
    try {
      await File(path).writeAsBytes(data, flush: true);
      // 恢复入口不再重跑校验：版本、对象白名单、物理完整性、外键与表结构都在
      // 这里一次做完，恢复只写入已经通过的字节。
      await StagedRestoreValidator(schemaVersion: schemaVersion)
          .validate(path: path, manifestSchemaVersion: version);
      copy = openReadOnlyDatabase(path);
      final head = await engine.headId(copy);
      final declaredHead = manifest['head'];
      if (declaredHead is int && declaredHead != head) {
        throw const FormatException('版本库备份声明的 HEAD 与数据库不一致');
      }
      await engine.projectionAt(copy, head);
      final assetsProblem = assetProblem(await engine.verifyAssets(copy));
      if (assetsProblem != null) {
        throw FormatException('版本库备份校验失败：$assetsProblem');
      }
      final commits = await copy.rawQuery(
        'SELECT COUNT(*) AS count FROM revision_commit',
      );
      final names = await copy.rawQuery(
        'SELECT COUNT(*) AS count FROM revision_ref',
      );
      int countOf(List<Map<String, Object?>> rows) =>
          rows.isEmpty ? 0 : (rows.first['count'] as int? ?? 0);
      final exportedAt = manifest['exported_at'];
      final appVersionOfBackup = manifest['app_version'];
      return RestoreInspection(
        kind: RestorePackageKind.repository,
        schemaVersion: version,
        head: head,
        commitCount: countOf(commits),
        namedCount: countOf(names),
        exportedAt: exportedAt is String ? exportedAt : '',
        appVersion: appVersionOfBackup is String ? appVersionOfBackup : '',
        databaseBytes: data,
        expectedRows: await versionedRowCounts(copy),
      );
    } finally {
      await copy?.close();
      // 清理失败不能顶替校验结论：按当前结构打开失败时文件句柄可能还没归还，
      // 临时目录留给系统清理，预检仍然按发现的问题报告。
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
  }

  /// 在读取任何条目内容之前按 zip 头执行解压预算，超限时以 [FormatException] 报告。
  void _checkBudget(Archive archive, int packageBytes) {
    final problem = budget.problem(
      packageBytes: packageBytes,
      entries: archive.files.map(
        (file) => PackageBudgetEntry(
          name: file.name,
          uncompressedBytes: file.size,
          isDirectory: file.isDirectory,
        ),
      ),
    );
    if (problem != null) throw FormatException(problem);
  }

  /// 暂存库的只读校验：版本、对象白名单、物理完整性与外键。
  ///
  /// 与数据包恢复预检共用 [StagedDatabaseValidator]；返回问题说明，由调用方按
  /// 自己的异常类型报告。
  Future<String?> _stagedProblem(String path) async {
    final problem = await StagedDatabaseValidator(schemaVersion: schemaVersion)
        .readOnlyProblem(path, manifestSchemaVersion: schemaVersion);
    if (problem == null) return null;
    return '${problem.category}：${problem.detail}';
  }
}
