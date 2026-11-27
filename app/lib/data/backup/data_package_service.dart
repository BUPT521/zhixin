import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../db/app_database.dart';
import '../../domain/rules/attachments.dart';
import '../../domain/rules/package_budget.dart';
import '../db/raw_executor.dart';
import '../../domain/rules/time_policy.dart';
import 'backup_manifest.dart';
import '../../domain/models/restore_inspection.dart';
import 'restore_journal.dart';
import 'restore_validation.dart';

/// 导出包里的固定文件名。
const String manifestEntryName = 'manifest.json';
const String dbEntryName = 'zhixin.db';
const String imagesEntryDir = questionImagesDirName;

/// 恢复推进到了哪一步：只有正式库关闭之后才需要回滚。
enum _RestorePhase {
  /// 写阶段记录与回滚快照，正式库还开着；失败时原数据没有被改过。
  snapshotting,

  /// 正式库已经关闭，库与附件可能已经被替换。
  replacing,

  /// 替换完成并重新打开了连接，正在核对。
  reopening,
}

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
    this.budget = const PackageBudget(),
    this.clock = systemClock,
  });

  final String filesDir;
  final String dbPath;
  final String appVersion;
  final int schemaVersion;

  /// 解压预算；在读取 manifest、数据库与附件之前执行。
  final PackageBudget budget;
  final Clock clock;

  /// 预检旧格式的数据包：核对 manifest、schema、图片与暂存库，返回包内规模。
  ///
  /// 恢复入口先调用它，确认包能恢复再让用户确认覆盖；校验失败时不碰当前库。
  /// 结果与版本库备份共用 [RestoreInspection]，`schemaVersion` 取 manifest 里
  /// 已经核对过的值，不用当前常量顶替。
  Future<RestoreInspection> inspectPackage(Uint8List bytes) async {
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
      return RestoreInspection(
        kind: RestorePackageKind.currentData,
        schemaVersion: manifest.schemaVersion,
        appVersion: manifest.appVersion,
        exportedAt: manifest.exportedAt,
        databaseBytes: dbBytes,
        images: images,
        expectedRows: counts,
      );
    } catch (error) {
      if (error is BackupException) rethrow;
      throw BackupException('数据包校验失败，原数据未改动。', detail: '$error');
    } finally {
      await _deleteQuietly(workDir);
    }
  }

  /// 用预检过的包覆盖当前数据；失败时回滚到恢复前的库与图片。
  ///
  /// [inspection] 是 [inspectPackage] 或版本库预检的产物：包已经解出并通过版本、
  /// 结构与业务校验，这里只写入它的库字节与附件，不再解包或重跑校验。成功返回
  /// 重新打开的连接，调用方用它替换旧的连接。期间把阶段写进 [RestoreJournal]，
  /// 进程中断也能在下次启动回到恢复前的数据。
  ///
  /// 失败分两种：替换开始之前失败时当前库没有被改过，只清阶段记录；正式库关闭
  /// 之后失败时把回滚目录里的库与附件放回去，回滚也没有完成时把原因连同原始错误
  /// 一起带进 [BackupException]，并保留阶段记录与回滚副本。
  Future<RawDatabase> restorePackage(
    RestoreInspection inspection, {
    required RawDatabase currentDb,
    required Future<RawDatabase> Function() openDb,
  }) async {
    final journal = RestoreJournal(filesDir);
    final rollbackDir = p.join(
      filesDir,
      '.restore-${clock().millisecondsSinceEpoch}',
    );
    var phase = _RestorePhase.snapshotting;
    RawDatabase? reopened;
    try {
      await _writeJournal(
        journal,
        RestoreStage.snapshotting,
        rollbackDir,
        inspection.schemaVersion,
      );
      await currentDb.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await _snapshotCurrent(rollbackDir);

      await _writeJournal(
        journal,
        RestoreStage.replacing,
        rollbackDir,
        inspection.schemaVersion,
      );
      await currentDb.close();
      phase = _RestorePhase.replacing;

      await _installDatabase(
        (incoming) =>
            incoming.writeAsBytes(inspection.databaseBytes, flush: true),
      );
      await _replaceImages(inspection.images);

      await _writeJournal(
        journal,
        RestoreStage.reopening,
        rollbackDir,
        inspection.schemaVersion,
      );
      final opened = await openDb();
      reopened = opened;
      phase = _RestorePhase.reopening;

      // 重新打开后核对核心表行数：包里的库在替换或复制时被截断、或打开时
      // 落到新建的空库，这里会发现并退回恢复前的数据，而不是把空库当成功。
      final actual = await _countRowsOf(opened);
      for (final entry in inspection.expectedRows.entries) {
        if ((actual[entry.key] ?? 0) < entry.value) {
          throw BackupException('恢复后的数据不完整（${entry.key} 少了记录），已退回原来的数据');
        }
      }

      // 先持久化数据已经提交，再清理回滚副本。进程若在清理期间退出，
      // 下次启动只清理残留文件，不会用旧快照覆盖已经验证的新数据。完成标记
      // 落盘之后的清理都自行吞掉失败，所以这里不再有另一条“假失败”分支。
      await _writeJournal(
        journal,
        RestoreStage.committed,
        rollbackDir,
        inspection.schemaVersion,
      );
      await _clearJournal(journal, rollbackDir);
      return opened;
    } catch (error) {
      if (phase == _RestorePhase.snapshotting) {
        await _clearJournal(journal, rollbackDir);
        if (error is BackupException) rethrow;
        throw BackupException('恢复失败，原数据未改动。', detail: '$error');
      }
      throw await _failReplace(
        error,
        journal: journal,
        rollbackDir: rollbackDir,
        openDb: openDb,
        reopened: reopened,
      );
    }
  }

  /// 替换开始之后的失败：关掉新连接、把快照放回去，并把失败原因带进异常。
  ///
  /// 返回要抛出的 [BackupException]，不在内部吞掉回滚失败：回滚没有完成时保留
  /// 阶段记录与回滚副本，原因写进 `detail`，下次启动仍会按阶段记录继续回滚。
  Future<BackupException> _failReplace(
    Object error, {
    required RestoreJournal journal,
    required String rollbackDir,
    required Future<RawDatabase> Function() openDb,
    required RawDatabase? reopened,
  }) async {
    String? closeProblem;
    if (reopened != null) {
      try {
        await reopened.close();
      } catch (error) {
        closeProblem = '关闭替换后打开的连接失败：$error';
      }
    }
    final rollbackProblem = await _rollback(rollbackDir, openDb);
    if (rollbackProblem == null) {
      await _clearJournal(journal, rollbackDir);
      return BackupException(
        '恢复失败，已退回原来的数据。',
        detail: _failureDetail(error, [?closeProblem]),
      );
    }
    return BackupException(
      '恢复失败，回滚也没有完成；当前文件与回滚副本均已保留，请先检查恢复目录。',
      detail: _failureDetail(error, [?closeProblem, rollbackProblem]),
    );
  }

  /// 失败说明：原始错误在前，回滚与关闭的补充说明依次跟在后面。
  String _failureDetail(Object error, List<String> notes) =>
      ['$error', ...notes].join('；');

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
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const BackupException('这个文件不是知新导出的 zip 数据包');
    }
    final problem = budget.problem(
      packageBytes: bytes.length,
      entries: archive.files.map(
        (file) => PackageBudgetEntry(
          name: file.name,
          uncompressedBytes: file.size,
          isDirectory: file.isDirectory,
        ),
      ),
    );
    if (problem != null) throw BackupException(problem);
    return archive;
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

  /// 恢复时要核对的核心表；只比行数，不比内容。
  ///
  /// 取版本化业务表清单，与数据版本采集和撤销使用同一份表名，不再另抄一张。
  Future<Map<String, int>> _countRows(String path) async {
    final db = openReadOnlyDatabase(path);
    try {
      return await _countRowsOf(db);
    } finally {
      await db.close();
    }
  }

  Future<Map<String, int>> _countRowsOf(RawExecutor db) =>
      versionedRowCounts(db);

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

  /// 原子替换正式库：先把新库写进同目录的 `.incoming`，删掉旧的 side 文件，
  /// 再重命名发布；任何时刻正式库要么是旧的完整文件，要么是新的完整文件，不会
  /// 出现“删掉了还没拷完”的空窗。
  ///
  /// 恢复与回滚共用这一处，写入方式由 [write] 决定：恢复写预检产物里的字节，
  /// 回滚复制快照里的库。`.incoming` 与正式库在同一个目录，重命名因此是原子的。
  Future<void> _installDatabase(
    Future<void> Function(File incoming) write,
  ) async {
    final incoming = File('$dbPath.incoming');
    if (await incoming.exists()) await incoming.delete();
    await write(incoming);
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

  /// 把回滚目录里的库与图片放回去并重新打开；返回没有完成的原因，空表示成功。
  ///
  /// 原因交给调用方写进 [BackupException]，不再吞掉：回滚失败与替换失败同样
  /// 重要，用户需要知道当前文件与回滚副本都还在。
  Future<String?> _rollback(
    String rollbackDir,
    Future<RawDatabase> Function() openDb,
  ) async {
    final bool restored;
    try {
      restored = await _restoreSnapshot(rollbackDir);
    } catch (error) {
      return '回滚快照没有放回去：$error';
    }
    if (!restored) return '回滚目录里的库或附件不完整（$rollbackDir）';
    try {
      await openDb();
    } catch (error) {
      // 原文件已经放回去了；打不开只影响本次进程，下次启动会重新打开。
      return '回滚后的库打不开：$error';
    }
    return null;
  }

  /// 把完整回滚目录里的库与图片放回去；不完整时保留当前文件与快照。
  Future<bool> _restoreSnapshot(String rollbackDir) async {
    final rollbackDb = File(p.join(rollbackDir, dbEntryName));
    final imagesBackup = Directory(p.join(rollbackDir, imagesEntryDir));
    if (!await rollbackDb.exists() || !await imagesBackup.exists()) {
      return false;
    }

    await _installDatabase((incoming) => rollbackDb.copy(incoming.path));

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
