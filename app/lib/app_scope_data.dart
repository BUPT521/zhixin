part of 'app_scope.dart';

/// 数据包与整库恢复：导出、备份、导入、恢复点与清空。
///
/// 这些操作共用同一个独占区与数据代次，从组件状态里拆出来单独成文件；方法
/// 属于应用根这一层装配，不进入 application 层，因为要读应用私有目录与连接。
extension DataPackageOperations on AppScopeState {
  /// 整库恢复：先预检数据包，再把当前状态存成一份恢复点，最后替换库与附件。
  ///
  /// 恢复点与恢复入口使用同一种版本库备份，恢复成功后仍然保留，用户可以从
  /// 数据版本页回到恢复前；恢复点写不出来时中止，当前库不动。库替换成功后
  /// 图片缓存重建失败只返回提醒，不再让界面把整次恢复报成失败。
  Future<String?> restore(Uint8List bytes) async {
    _operationEpoch++;
    String? cacheWarning;
    // 先记一笔“缓存要重补”：还原中途退出时，下次启动会按恢复后的数据重补，
    // 而不是留着一半新的缓存。
    await attachmentCache.markPendingRebuild();
    await gate.exclusive(() async {
      await revisionPackages.validateRepositoryBytes(bytes);
      final summary = await currentRestoreSummary();
      try {
        await restorePoints.capture(
          head: summary.head,
          commitCount: summary.commitCount,
          namedCount: summary.namedCount,
          reason: '整库恢复前自动保存',
          write: (path) =>
              revisionPackages.backupRepository(_connection!, path),
        );
      } catch (error, stack) {
        crashLog.record(error, stack, kind: 'restore_point_capture');
        throw const BackupException('恢复前保存当前状态失败，本次恢复没有执行；当前数据没有改动。');
      }
      // 恢复过程中失败时保留刚写好的恢复点：它要么与回滚后的数据一致，
      // 要么就是回滚没有完成时唯一可用的旧状态，交给用户确认后再删除。
      await packages.restorePackage(bytes, currentDb: db, openDb: _open);
      try {
        await attachmentCache.rebuild(_connection!, revisionsEngine.assets);
        await attachmentCache.clearPendingRebuild();
      } catch (error, stack) {
        crashLog.record(error, stack, kind: 'rebuild_attachments_restore');
        cacheWarning = '数据已恢复，但图片缓存没有重建完成，下次打开应用会再试。';
      }
    });
    dataVersion.value++;
    _refreshSemanticIndex();
    return cacheWarning;
  }

  /// 恢复数据包前的预检：先确认包能通过校验，再返回包内规模。
  ///
  /// 不是版本库备份时交给旧数据包的校验；校验失败会抛出，界面据此拒绝恢复。
  Future<RestoreInspection> inspectRestorePackage(Uint8List bytes) async {
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
    final data = await packages.inspectPackage(bytes);
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
    final head = await revisionsEngine.headId(_connection!);
    return RestoreSummary(
      head: head,
      commitCount: usage.commitCount,
      namedCount: usage.namedCount,
    );
  }

  Future<void> resetAllData() async {
    _operationEpoch++;
    await gate.exclusive(() async {
      await _connection?.close();
      _connection = null;
      await deleteLocalStudyData(
        filesDir: paths.filesDir,
        dbPath: paths.dbPath,
      );
      await paths.ensureDirectories();
      await _open();
    });
    dataVersion.value++;
    _refreshSemanticIndex();
  }

  /// 导出当前数据：业务投影与附件，不含历史。
  Future<void> exportCurrentData(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.exportCurrent(_connection!, outputPath),
    );
  }

  /// 导入当前数据包之前先取 `HEAD`，提交时重新核对。
  Future<int> currentHead() => revisionsEngine.headId(_connection!);

  Future<void> importCurrentData(
    Uint8List bytes, {
    required int expectedHead,
  }) async {
    _operationEpoch++;
    await attachmentCache.markPendingRebuild();
    await gate.exclusive(
      () => revisionPackages.importCurrent(
        _connection!,
        bytes,
        expectedHead: expectedHead,
      ),
    );
    await attachmentCache.rebuild(_connection!, revisionsEngine.assets);
    await attachmentCache.clearPendingRebuild();
    dataVersion.value++;
    _refreshSemanticIndex();
  }

  /// 版本库备份：整库快照，包含历史、命名版本与附件。
  Future<void> backupRepository(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.backupRepository(_connection!, outputPath),
    );
  }

  Future<void> cleanupAttachmentPaths(Iterable<String> candidates) {
    final pathsToCheck = List<String>.unmodifiable(candidates);
    return gate.shared(
      () =>
          AttachmentStore(filesDir: paths.filesDir)
              .cleanupCandidates(db, pathsToCheck),
    );
  }
}
