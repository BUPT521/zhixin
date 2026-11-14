import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../attachment_store.dart';
import '../db/app_database.dart';
import '../../domain/rules/attachments.dart';
import '../db/raw_executor.dart';
import '../../domain/rules/time_policy.dart';
import 'backup_manifest.dart';
import 'restore_journal.dart';
import 'restore_validation.dart';

/// 导出包里的固定文件名。
const String manifestEntryName = 'manifest.json';
const String dbEntryName = 'zhixin.db';
const String imagesEntryDir = questionImagesDirName;

/// 导出与恢复本地库及其仍被引用的图片；格式规则见 01 第 7 章。
///
/// 只碰文件与传入的数据库连接，不依赖 Flutter，测试里用 `openTestDb` 一类入口就能跑。
/// 导出与恢复都只处理当前 schema：恢复入口不接受其他版本的包。
class DataPackageService {
  DataPackageService({
    required this.filesDir,
    required this.dbPath,
    required this.appVersion,
    required this.schemaVersion,
    this.clock = systemClock,
  });

  final String filesDir;
  final String dbPath;
  final String appVersion;
  final int schemaVersion;
  final Clock clock;

  /// 将数据包按文件流写入目标路径，供自动备份和手动导出暂存使用。
  Future<void> exportPackageToFile(RawDatabase db, String outputPath) async {
    final output = File(outputPath);
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      await output.parent.create(recursive: true);
      if (await output.exists()) await output.delete();
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final imagePaths = await _referencedImageFiles(db);
      final manifestImages = <String, String>{};
      for (final entry in imagePaths) {
        final digest = await sha256.bind(entry.openRead()).first;
        manifestImages[_imageEntryPath(entry)] = digest.toString();
      }
      final manifest = BackupManifest(
        schemaVersion: schemaVersion,
        appVersion: appVersion,
        exportedAt: clock().toUtc().toIso8601String(),
        imageCount: manifestImages.length,
        images: manifestImages,
      );
      encoder.create(output.path, level: 6);
      opened = true;
      encoder.addArchiveFile(
        ArchiveFile.bytes(
          manifestEntryName,
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          ),
        ),
      );
      await encoder.addFile(File(dbPath), dbEntryName);
      for (final entry in imagePaths) {
        await encoder.addFile(entry, _imageEntryPath(entry));
      }
      await encoder.close();
      opened = false;
    } catch (error) {
      if (opened) {
        try {
          await encoder.close();
        } catch (_) {
          // 保留原始写入错误。
        }
      }
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {
        // 未完成文件使用临时后缀，不会显示为有效备份。
      }
      if (error is BackupException) rethrow;
      throw BackupException('文件流导出没有完成，文件没有生成。', detail: '$error');
    }
  }

  /// 预检旧格式的数据包：核对 manifest、schema、图片与暂存库，返回导出信息。
  ///
  /// 恢复入口先调用它，确认包能恢复再让用户确认覆盖；校验失败时不碰当前库。
  Future<DataPackageInspection> inspectPackage(Uint8List bytes) async {
    final archive = _decodeArchive(bytes);
    final manifest = _readManifest(archive);
    if (manifest.schemaVersion != schemaVersion) {
      final hint = manifest.schemaVersion > schemaVersion
          ? '请先更新应用再恢复。'
          : '请用当前版本重新导出。';
      throw BackupException(
        '数据包是 schema v${manifest.schemaVersion}，当前只接受 v$schemaVersion；$hint',
      );
    }
    final dbFile = archive.findFile(dbEntryName);
    final dbBytes = dbFile?.readBytes();
    if (dbBytes == null || dbBytes.isEmpty) {
      throw const BackupException('数据包中没有可用的 zhixin.db');
    }
    final images = _readArchiveImages(archive);
    _verifyImages(manifest, images);

    final workDir = await Directory.systemTemp.createTemp(
      'zhixin_package_check_',
    );
    try {
      final stagedDbPath = p.join(workDir.path, 'staged.db');
      await File(stagedDbPath).writeAsBytes(dbBytes, flush: true);
      await StagedRestoreValidator(schemaVersion: schemaVersion).validate(
        path: stagedDbPath,
        manifestSchemaVersion: manifest.schemaVersion,
      );
      final counts = await _countRows(stagedDbPath);
      return DataPackageInspection(
        schemaVersion: manifest.schemaVersion,
        appVersion: manifest.appVersion,
        exportedAt: manifest.exportedAt,
        rowCount: counts.values.fold(0, (sum, value) => sum + value),
      );
    } catch (error) {
      if (error is BackupException) rethrow;
      throw BackupException('数据包校验失败，原数据未改动。', detail: '$error');
    } finally {
      await _deleteQuietly(workDir);
    }
  }

  /// 校验并覆盖当前数据；失败时回滚到恢复前的库与图片。
  ///
  /// 成功返回重新打开的连接，调用方用它替换旧的连接。恢复前先让临时库通过
  /// 版本、结构与业务校验（01 第 7 章），期间把阶段写进 [RestoreJournal]，
  /// 进程中断也能在下次启动回到恢复前的数据。
  Future<RawDatabase> restorePackage(
    Uint8List bytes, {
    required RawDatabase currentDb,
    required Future<RawDatabase> Function() openDb,
  }) async {
    final archive = _decodeArchive(bytes);
    final manifest = _readManifest(archive);
    if (manifest.schemaVersion != schemaVersion) {
      final hint = manifest.schemaVersion > schemaVersion
          ? '请先更新应用再恢复。'
          : '请用当前版本重新导出。';
      throw BackupException(
        '数据包是 schema v${manifest.schemaVersion}，当前只接受 v$schemaVersion；$hint',
      );
    }

    final dbFile = archive.findFile(dbEntryName);
    final dbBytes = dbFile?.readBytes();
    if (dbBytes == null || dbBytes.isEmpty) {
      throw const BackupException('数据包中没有可用的 zhixin.db');
    }
    final images = _readArchiveImages(archive);
    _verifyImages(manifest, images);

    final journal = RestoreJournal(filesDir);
    final rollbackDir = p.join(
      filesDir,
      '.restore-${clock().millisecondsSinceEpoch}',
    );
    final workDir = await Directory.systemTemp.createTemp('zhixin_restore_');
    final stagedDbPath = p.join(workDir.path, 'staged.db');
    try {
      await File(stagedDbPath).writeAsBytes(dbBytes, flush: true);
      await _writeJournal(
        journal,
        RestoreStage.preparing,
        rollbackDir,
        manifest.schemaVersion,
      );
      await StagedRestoreValidator(schemaVersion: schemaVersion).validate(
        path: stagedDbPath,
        manifestSchemaVersion: manifest.schemaVersion,
      );
    } catch (error) {
      await _deleteQuietly(workDir);
      await _clearJournal(journal, rollbackDir);
      if (error is BackupException) rethrow;
      throw BackupException('数据包校验失败，原数据未改动。', detail: '$error');
    }

    var closed = false;
    var committed = false;
    RawDatabase? reopened;
    try {
      await _writeJournal(
        journal,
        RestoreStage.snapshotting,
        rollbackDir,
        manifest.schemaVersion,
      );
      await currentDb.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await _snapshotCurrent(rollbackDir);

      await _writeJournal(
        journal,
        RestoreStage.replacing,
        rollbackDir,
        manifest.schemaVersion,
      );
      await currentDb.close();
      closed = true;

      await _replaceDatabase(stagedDbPath);
      await _replaceImages(images);

      await _writeJournal(
        journal,
        RestoreStage.reopening,
        rollbackDir,
        manifest.schemaVersion,
      );
      reopened = await openDb();

      // 重新打开后核对核心表行数：包里的库在替换或复制时被截断、或打开时
      // 落到新建的空库，这里会发现并退回恢复前的数据，而不是把空库当成功。
      final expected = await _countRows(stagedDbPath);
      final actual = await _countRowsOf(reopened);
      for (final entry in expected.entries) {
        if ((actual[entry.key] ?? 0) < entry.value) {
          throw BackupException('恢复后的数据不完整（${entry.key} 少了记录），已退回原来的数据');
        }
      }

      // 先持久化数据已经提交，再清理回滚副本。进程若在清理期间退出，
      // 下次启动只清理残留文件，不会用旧快照覆盖已经验证的新数据。
      await _writeJournal(
        journal,
        RestoreStage.committed,
        rollbackDir,
        manifest.schemaVersion,
      );
      committed = true;
      await _deleteQuietly(Directory(workDir.path));
      await _clearJournal(journal, rollbackDir);
      return reopened;
    } catch (error) {
      if (committed) {
        // 完成标记已经落盘，清理失败只能留待下次启动处理，不能回滚。
        await _deleteQuietly(Directory(workDir.path));
        return reopened!;
      }
      if (closed) {
        if (reopened != null) {
          try {
            await reopened.close();
          } catch (_) {
            // 文件恢复仍会尝试；失败时保留快照与阶段记录。
          }
        }
        var restored = false;
        try {
          restored = await _rollback(rollbackDir, openDb);
        } catch (_) {
          // 回滚失败时保留快照与阶段记录供下次启动继续恢复。
        }
        if (restored) await _clearJournal(journal, rollbackDir);
      } else {
        await _clearJournal(journal, rollbackDir);
      }
      await _deleteQuietly(Directory(workDir.path));
      if (error is BackupException) rethrow;
      throw BackupException('恢复失败，已保留原数据与可用的回滚副本。', detail: '$error');
    }
  }

  /// 启动时调用：上一次恢复若没走完，回到恢复前的库与图片。
  ///
  /// 返回是否真的回滚了数据；阶段还停在替换之前时，正式库没有被改过，
  /// 只清掉半成品与阶段记录。
  Future<bool> recoverInterruptedRestore() async {
    final journal = RestoreJournal(filesDir);
    RestoreJournalEntry? entry;
    try {
      entry = await journal.read();
    } on RestoreJournalCorruptException catch (error) {
      // 阶段不明时，不能判断正式库是否已替换，因此保留全部回滚文件。
      throw BackupException('恢复阶段记录损坏，回滚副本已保留，请先检查恢复目录。', detail: '$error');
    }
    if (entry == null) {
      // 阶段记录不存在时，正式库尚未进入替换阶段，或上次已完成清理。
      await _cleanStaleRestoreFiles();
      return false;
    }

    var rolledBack = false;
    final rollbackDir = _checkedRollbackDir(entry.rollbackDir);
    if (entry.mayHaveReplacedData) {
      rolledBack = await _restoreSnapshot(rollbackDir);
      if (!rolledBack) {
        throw const BackupException('恢复中断且回滚快照不完整；当前文件与回滚副本均已保留，请先检查恢复目录。');
      }
    }
    if (!await _clearJournal(journal, rollbackDir)) {
      throw const BackupException('恢复状态已确认，但阶段记录无法清理；回滚副本已保留。');
    }
    await _cleanStaleRestoreFiles();
    return rolledBack;
  }

  /// 清掉没写完的阶段记录、残留的回滚目录与替换用的临时文件。
  Future<void> _cleanStaleRestoreFiles() async {
    final incoming = File('$dbPath.incoming');
    if (await incoming.exists()) await incoming.delete();
    final dir = Directory(filesDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory && name.startsWith('.restore-')) {
        await _deleteQuietly(entity);
      } else if (entity is File && name.startsWith('.restore-journal.tmp-')) {
        try {
          await entity.delete();
        } catch (_) {
          // 临时阶段文件没有替换正式库，不影响后续启动。
        }
      }
    }
  }

  String _checkedRollbackDir(String path) {
    final root = p.normalize(p.absolute(filesDir));
    final candidate = p.normalize(p.absolute(path));
    if (!p.isWithin(root, candidate) ||
        !p.basename(candidate).startsWith('.restore-')) {
      throw const BackupException('恢复阶段记录中的回滚目录无效；现有文件已保留。');
    }
    return candidate;
  }

  Future<void> _writeJournal(
    RestoreJournal journal,
    RestoreStage stage,
    String rollbackDir,
    int manifestSchemaVersion,
  ) async {
    try {
      await journal.write(
        RestoreJournalEntry(
          stage: stage,
          rollbackDir: rollbackDir,
          startedAt: clock().toUtc().toIso8601String(),
          manifestSchemaVersion: manifestSchemaVersion,
        ),
      );
    } catch (error) {
      throw BackupException('恢复无法记录阶段，已中止。', detail: '$error');
    }
  }

  Future<bool> _clearJournal(RestoreJournal journal, String rollbackDir) async {
    try {
      await journal.clear();
    } catch (_) {
      // 阶段文件删不掉时保留回滚副本，让下次启动继续判断。
      return false;
    }
    await _deleteQuietly(Directory(rollbackDir));
    return true;
  }

  Archive _decodeArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const BackupException('这个文件不是知新导出的 zip 数据包');
    }
  }

  BackupManifest _readManifest(Archive archive) {
    final file = archive.findFile(manifestEntryName);
    final bytes = file?.readBytes();
    if (bytes == null) {
      throw const BackupException('数据包中没有 manifest.json');
    }
    try {
      return BackupManifest.parse(bytes);
    } on FormatException catch (error) {
      throw BackupException('manifest.json 不完整，无法读取。', detail: error.message);
    }
  }

  Map<String, Uint8List> _readArchiveImages(Archive archive) {
    final images = <String, Uint8List>{};
    for (final file in archive.files) {
      if (file.isDirectory) continue;
      final name = p.posix.normalize(file.name);
      if (!name.startsWith('$imagesEntryDir/')) continue;
      if (p.posix.isAbsolute(name) || name.contains('..')) {
        throw const BackupException('数据包包含非法图片路径');
      }
      final bytes = file.readBytes();
      if (bytes == null) {
        throw BackupException('图片无法读取：$name');
      }
      images[name] = bytes;
    }
    return images;
  }

  void _verifyImages(BackupManifest manifest, Map<String, Uint8List> images) {
    if (manifest.imageCount != images.length) {
      throw BackupException(
        '图片数量不一致：manifest 记录 ${manifest.imageCount} 张，数据包内 ${images.length} 张',
      );
    }
    for (final entry in manifest.images.entries) {
      final bytes = images[entry.key];
      if (bytes == null) {
        throw BackupException('缺少图片：${entry.key}');
      }
      final hash = sha256.convert(bytes).toString();
      if (hash != entry.value) {
        throw BackupException('图片校验失败：${entry.key}');
      }
    }
  }

  /// 数据库仍引用的图片文件；缺文件时中止导出，而不是悄悄少打包一张。
  Future<List<File>> _referencedImageFiles(RawExecutor db) async {
    final imageRoot = p.normalize(p.absolute(p.join(filesDir, imagesEntryDir)));
    final paths = await AttachmentStore(filesDir: filesDir).referencedPaths(db);
    final files = <File>[];
    final missing = <String>[];
    for (final path in paths) {
      if (!p.isWithin(imageRoot, path)) continue;
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        missing.add(p.relative(path, from: imageRoot).replaceAll('\\', '/'));
        continue;
      }
      files.add(File(path));
    }
    if (missing.isNotEmpty) {
      throw BackupException(
        '导出中止：数据库引用的 ${missing.length} 张图片文件已缺失'
        '（${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}）',
      );
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  String _imageEntryPath(File file) {
    final imageRoot = p.normalize(p.absolute(p.join(filesDir, imagesEntryDir)));
    return p.posix.join(
      imagesEntryDir,
      p.relative(file.path, from: imageRoot).replaceAll('\\', '/'),
    );
  }

  /// 恢复时要核对的核心表；只比行数，不比内容。
  static const _countedTables = [
    'profile',
    'attempt',
    'assessment',
    'conversation',
    'message',
    'memory',
    'learning_goal',
    'plan_item',
    'schedule_block',
    'material',
    'material_page',
    'study_plan',
  ];

  Future<Map<String, int>> _countRows(String path) async {
    final db = openReadOnlyDatabase(path);
    try {
      return await _countRowsOf(db);
    } finally {
      await db.close();
    }
  }

  Future<Map<String, int>> _countRowsOf(RawExecutor db) async {
    final counts = <String, int>{};
    for (final table in _countedTables) {
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
      counts[table] = (rows.first['n'] as int?) ?? 0;
    }
    return counts;
  }

  Future<void> _snapshotCurrent(String rollbackDir) async {
    await Directory(rollbackDir).create(recursive: true);
    if (await File(dbPath).exists()) {
      await File(dbPath).copy(p.join(rollbackDir, dbEntryName));
    }
    final imagesDir = Directory(p.join(filesDir, imagesEntryDir));
    final imagesBackup = Directory(p.join(rollbackDir, imagesEntryDir));
    await imagesBackup.create(recursive: true);
    if (await imagesDir.exists()) {
      await _copyDirectory(imagesDir.path, imagesBackup.path);
    }
  }

  /// 用临时文件加重命名替换正式库：任何时刻正式库要么是旧的完整文件，
  /// 要么是新的完整文件，不会出现“删掉了还没拷完”的空窗。
  Future<void> _replaceDatabase(String stagedDbPath) async {
    final incoming = File('$dbPath.incoming');
    if (await incoming.exists()) await incoming.delete();
    await File(stagedDbPath).copy(incoming.path);
    for (final suffix in zhixinDbSideFiles) {
      final file = File('$dbPath$suffix');
      if (await file.exists()) await file.delete();
    }
    await incoming.rename(dbPath);
  }

  Future<void> _replaceImages(Map<String, Uint8List> images) async {
    final imagesDir = Directory(p.join(filesDir, imagesEntryDir));
    if (await imagesDir.exists()) await imagesDir.delete(recursive: true);
    for (final entry in images.entries) {
      final file = File(p.join(filesDir, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
  }

  Future<bool> _rollback(
    String rollbackDir,
    Future<RawDatabase> Function() openDb,
  ) async {
    final restored = await _restoreSnapshot(rollbackDir);
    if (!restored) return false;
    try {
      await openDb();
    } catch (_) {
      // 回滚后仍打不开就只能让上层报错；原文件已经放回去了。
    }
    return true;
  }

  /// 把完整回滚目录里的库与图片放回去；不完整时保留当前文件与快照。
  Future<bool> _restoreSnapshot(String rollbackDir) async {
    final rollbackDb = File(p.join(rollbackDir, dbEntryName));
    final imagesBackup = Directory(p.join(rollbackDir, imagesEntryDir));
    if (!await rollbackDb.exists() || !await imagesBackup.exists()) {
      return false;
    }

    final incoming = File('$dbPath.incoming');
    if (await incoming.exists()) await incoming.delete();
    await rollbackDb.copy(incoming.path);
    for (final suffix in zhixinDbSideFiles) {
      final file = File('$dbPath$suffix');
      if (await file.exists()) await file.delete();
    }
    await incoming.rename(dbPath);

    final imagesDir = Directory(p.join(filesDir, imagesEntryDir));
    if (await imagesDir.exists()) await imagesDir.delete(recursive: true);
    await _copyDirectory(imagesBackup.path, imagesDir.path);
    return true;
  }

  Future<void> _copyDirectory(String from, String to) async {
    final source = Directory(from);
    final target = Directory(to);
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final rel = p.relative(entity.path, from: from);
      final dest = p.join(to, rel);
      if (entity is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(dest)).create(recursive: true);
        await entity.copy(dest);
      }
    }
  }

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响数据正确性。
    }
  }
}

/// 旧格式数据包预检的结果：导出信息与业务表行数，用于恢复前的影响说明。
class DataPackageInspection {
  const DataPackageInspection({
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.rowCount,
  });

  final int schemaVersion;
  final String appVersion;
  final String exportedAt;
  final int rowCount;
}
