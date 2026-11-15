import 'dart:typed_data';

import '../../domain/models/backup_error.dart';
import '../../domain/models/result.dart';
import '../attachment_store.dart';
import '../db/app_database.dart';
import '../db/database_gate.dart';
import '../db/raw_executor.dart';
import '../revisions/asset_store.dart';
import '../revisions/revision_engine.dart';
import '../revisions/revision_package.dart';
import '../revisions/revision_service.dart';
import 'data_package_service.dart';
import 'restore_inspection.dart';
import 'restore_point_store.dart';

/// 数据包与整库恢复：导出、备份、导入、恢复点与清空。
///
/// 这些操作共用同一个独占写入区与数据代次，并且会换掉当前的库连接；连接的
/// 打开、换库之后的通知与平台路径仍由应用根负责，服务通过构造参数拿到它们，
/// 页面只调服务，不再经应用根的扩展方法。恢复点也归这里：列表、保留份数与
/// 删除都由服务给出，页面不再直接读文件存储。
class DataVersionService {
  DataVersionService({
    required this.gate,
    required this.revisions,
    required this.revisionPackages,
    required this.dataPackages,
    required this.restorePointStore,
    required this.engine,
    required this.cache,
    required this.connection,
    required this.database,
    required this.reopen,
    required this.resetStudyData,
    required this.markPendingWorkInvalidated,
    required this.notifyDataChanged,
    required this.recordFailure,
  });

  final DatabaseGate gate;
  final RevisionService revisions;
  final RevisionPackageService revisionPackages;
  final DataPackageService dataPackages;
  final RestorePointStore restorePointStore;
  final RevisionEngine engine;
  final AttachmentCache cache;

  /// 当前库连接；恢复与导入期间会被换掉。
  final RawDatabase Function() connection;

  /// 当前受保护的库；恢复前保存恢复点时读它。
  final RawDatabase Function() database;

  /// 换库之后重新打开连接，返回新的库。
  final Future<RawDatabase> Function() reopen;

  /// 删除本机学习数据并重建目录，最后重开连接。
  final Future<void> Function() resetStudyData;

  /// 数据整份变化：推进操作代次，恢复前发出的回答不再写回。
  final void Function() markPendingWorkInvalidated;

  /// 通知三栏重读并补建语义索引。
  final void Function() notifyDataChanged;

  final void Function(Object error, StackTrace stack, {required String kind})
  recordFailure;

  /// 整库恢复：先预检数据包，再把当前状态存成一份恢复点，最后替换库与附件。
  ///
  /// 恢复点与恢复入口使用同一种版本库备份，恢复成功后仍然保留，用户可以从
  /// 数据版本页回到恢复前；恢复点写不出来时中止，当前库不动。库替换成功后
  /// 图片缓存重建失败只返回提醒，不再让界面把整次恢复报成失败。
  ///
  /// 预检与恢复点写入是可预期失败，按 [Result] 返回；换库等程序错误仍抛出。
  Future<Result<String?>> restore(Uint8List bytes) =>
      _expected(() => _restore(bytes));

  Future<String?> _restore(Uint8List bytes) async {
    String? cacheWarning;
    await gate.exclusive(() async {
      await revisionPackages.validateRepositoryBytes(bytes);
      final summary = await currentRestoreSummary();
      try {
        await restorePointStore.capture(
          head: summary.head,
          commitCount: summary.commitCount,
          namedCount: summary.namedCount,
          reason: '整库恢复前自动保存',
          write: (path) =>
              revisionPackages.backupRepository(connection(), path),
        );
      } catch (error, stack) {
        recordFailure(error, stack, kind: 'restore_point_capture');
        throw const BackupException('恢复前保存当前状态失败，本次恢复没有执行；当前数据没有改动。');
      }
      // 恢复过程中失败时保留刚写好的恢复点：它要么与回滚后的数据一致，
      // 要么就是回滚没有完成时唯一可用的旧状态，交给用户确认后再删除。
      await cache.markPendingRebuild();
      await dataPackages.restorePackage(
        bytes,
        currentDb: database(),
        openDb: reopen,
      );
      markPendingWorkInvalidated();
      cacheWarning = await _rebuildPackageAttachments('数据已恢复');
    });
    notifyDataChanged();
    return cacheWarning;
  }

  /// 恢复数据包前的预检：先确认包能通过校验，再返回包内规模。
  ///
  /// 不是版本库备份时交给旧数据包的校验；校验失败按 [Result] 返回，界面据此
  /// 拒绝恢复。
  Future<Result<RestoreInspection>> inspectRestorePackage(Uint8List bytes) =>
      _expected(() => _inspectRestorePackage(bytes));

  Future<RestoreInspection> _inspectRestorePackage(Uint8List bytes) async {
    final repository = await revisionPackages.inspectRepository(bytes);
    if (repository != null) {
      return RestoreInspection(
        kind: RestorePackageKind.repository,
        schemaVersion: zhixinSchemaVersion,
        appVersion: repository.appVersion,
        exportedAt: repository.exportedAt,
        head: repository.head,
        commitCount: repository.commitCount,
        namedCount: repository.namedCount,
      );
    }
    final data = await dataPackages.inspectPackage(bytes);
    return RestoreInspection(
      kind: RestorePackageKind.currentData,
      schemaVersion: data.schemaVersion,
      appVersion: data.appVersion,
      exportedAt: data.exportedAt,
      rowCount: data.rowCount,
    );
  }

  /// 当前库的规模；恢复前的说明与恢复点里的记录共用这一份。
  Future<RestoreSummary> currentRestoreSummary() async {
    final usage = await revisions.storageUsage();
    final head = await engine.headId(connection());
    return RestoreSummary(
      head: head,
      commitCount: usage.commitCount,
      namedCount: usage.namedCount,
    );
  }

  /// 恢复点按保存时间倒序；数据版本页用它列出恢复前自动保存的状态。
  Future<List<RestorePoint>> restorePoints() => restorePointStore.list();

  /// 恢复点最多保留的份数；超出时由存储按时间删掉最早的，页面只读这个数。
  int get restorePointKeep => restorePointStore.keep;

  /// 读出某份恢复点的版本库备份，交给同一条整库恢复流程。
  Future<Uint8List> readRestorePoint(RestorePoint point) =>
      restorePointStore.read(point);

  /// 删除一份恢复点；文件与同名说明一起删除。
  Future<void> deleteRestorePoint(RestorePoint point) =>
      restorePointStore.delete(point);

  /// 清空本机学习数据，并按当前结构重开一个空库。
  Future<void> resetAllData() async {
    markPendingWorkInvalidated();
    await gate.exclusive(resetStudyData);
    notifyDataChanged();
  }

  /// 导出当前数据：业务投影与附件，不含历史。
  Future<void> exportCurrentData(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.exportCurrent(connection(), outputPath),
    );
  }

  /// 导入当前数据包之前先取 `HEAD`，提交时重新核对。
  Future<int> currentHead() => engine.headId(connection());

  /// 导入当前数据包；导入前先取 `HEAD`，提交时重新核对。
  ///
  /// 校验与导入的可预期失败按 [Result] 返回；版本已经前进等程序性冲突仍抛出。
  Future<Result<String?>> importCurrentData(
    Uint8List bytes, {
    required int expectedHead,
  }) => _expected(() => _importCurrentData(bytes, expectedHead: expectedHead));

  Future<String?> _importCurrentData(
    Uint8List bytes, {
    required int expectedHead,
  }) async {
    final cacheWarning = await gate.exclusive(() async {
      await cache.markPendingRebuild();
      await revisionPackages.importCurrent(
        connection(),
        bytes,
        expectedHead: expectedHead,
      );
      markPendingWorkInvalidated();
      return _rebuildPackageAttachments('数据已导入');
    });
    notifyDataChanged();
    return cacheWarning;
  }

  /// 版本库备份：整库快照，包含历史、命名版本与附件。
  Future<void> backupRepository(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.backupRepository(connection(), outputPath),
    );
  }

  /// 清理数据库不再引用的图片文件；发送失败与恢复之后共用这一处。
  Future<void> cleanupAttachmentPaths(Iterable<String> candidates) {
    final pathsToCheck = List<String>.unmodifiable(candidates);
    return gate.shared(
      () =>
          AttachmentStore(filesDir: dataPackages.filesDir)
              .cleanupCandidates(database(), pathsToCheck),
    );
  }

  /// 把可预期的备份失败换成失败结果；程序错误原样抛出。
  ///
  /// 包格式问题由 zip 与清单解析抛出 [FormatException]，校验与写盘失败抛出
  /// [BackupException]，两者都是给用户看的说明，统一进 [Failure]。
  Future<Result<T>> _expected<T>(Future<T> Function() action) async {
    try {
      return Success(await action());
    } on BackupException catch (error) {
      return Failure(FailureReason.backup(error));
    } on FormatException catch (error) {
      return Failure(FailureReason(error.message));
    }
  }

  Future<String?> _rebuildPackageAttachments(String result) async {
    try {
      await cache.rebuild(connection(), engine.assets);
      await cache.clearPendingRebuild();
      return null;
    } catch (error, stack) {
      recordFailure(error, stack, kind: 'rebuild_attachments_package');
      return '$result，但图片缓存没有重建完成，下次打开应用会再试。';
    }
  }
}
