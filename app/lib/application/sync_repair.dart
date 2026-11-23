part of 'sync_service.dart';

extension SyncRepairFlow on SyncService {
  /// “以云端为准修复”：按云端的提交序列重放出一份投影，把本机被改动、与云端
  /// 不同的行改成云端值，再把本机独有的行作为基线上传（同步方案 3.5）。
  ///
  /// 这里不直接清掉位置重拉：本机已经应用过的远端提交按 uid 去重，重新拉取不会
  /// 再写一遍，漏掉的内容不会自己回来。于是按方案里“按差异重放”的退路实现：
  /// 从服务端第 1 条开始只读地重放全部提交，得到云端投影与云端碰过的行；这些行在
  /// 本机与云端不同的改写成云端值并形成一条本机提交（它的内容云端已经有了，所以
  /// 随后把推送位置一起推进，不再推上去），没有被云端碰过的本机行照旧作为基线
  /// 补传。云端历史被压缩之后第 1 条已经读不到，这时改走快照重新克隆（同步方案
  /// 3.7 第 4 条）。调用方必须先让用户确认。成功之后清掉不一致标记。
  Future<SyncResult> repairFromCloud() async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) throw const AccountSignedOut();
    await _waitForRunningSync();
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    _runEpoch = epoch;
    _pulledSkipped = 0;
    _knownDigestMismatch = false;
    try {
      // 先清掉两个同步位置与遮蔽行：这次修复不从旧位置接着增量，而是按服务端
      // 序列重新对齐一遍，收尾时再写回新的位置。
      await _forgetSyncPosition();
      // 云端历史被压缩过时按第 1 条重放不可行：有快照就走快照重新克隆，没有
      // 快照时给明确说明，不静默清空本机数据。
      final remoteHead = await account.call(
        (client, token) => client.head(token, deviceId: deviceId),
      );
      if (remoteHead.schemaVersion != zhixinSchemaVersion) {
        throw SyncSchemaMismatch(
          server: remoteHead.schemaVersion,
          client: zhixinSchemaVersion,
        );
      }
      if (remoteHead.historyCompacted) {
        final covered = remoteHead.snapshot;
        if (covered == null) throw const SyncSnapshotProblem.unavailable();
        return await _repairFromCloudBySnapshot(covered, deviceId: deviceId);
      }
      final cloud = <String, Map<String, TypedRow>>{};
      final touched = <(String, String)>{};
      var serverHead = 0;
      var pulled = 0;
      try {
        while (true) {
          _ensureIdentity();
          final page = await account.call(
            (client, token) =>
                client.pull(token, after: serverHead, deviceId: deviceId),
          );
          if (page.commits.isEmpty) {
            // 再读一页确认真实的位置：修复期间另一台设备也可能在推，按最后一页
            // 的 head 推送基线才不会撞上 409。
            serverHead = page.head;
            break;
          }
          for (final commit in page.commits) {
            for (final change in commit.changes) {
              touched.add((change.table, change.rowKey));
              _applyChangeToCloudProjection(cloud, change);
            }
          }
          pulled += page.commits.length;
          serverHead = page.commits.last.seq ?? serverHead;
        }
      } on SyncHistoryCompacted {
        // 读 head 时还没压缩、拉取时已经被压缩：按快照重新克隆。
        final covered = (await account.call(
          (client, token) => client.head(token, deviceId: deviceId),
        )).snapshot;
        if (covered == null) throw const SyncSnapshotProblem.unavailable();
        return await _repairFromCloudBySnapshot(covered, deviceId: deviceId);
      }
      // 云端碰过的行按云端值改写，没有被云端碰过的本机行保留下来补传。
      final local = await engine.readProjection(database.raw);
      await database.command((txn) async {
        for (final key in touched) {
          final table = key.$1;
          final rowKey = key.$2;
          final primaryKey = versionedPrimaryKeys[table];
          if (primaryKey == null) continue;
          final target = cloud[table]?[rowKey];
          final current = local[table]?[rowKey];
          if (target == null) {
            if (current == null) continue;
            await deleteRows(
              txn,
              table,
              where: '$primaryKey = ?',
              whereArgs: [rowKey],
            );
            continue;
          }
          if (current == null) {
            await insertRow(txn, table, {
              primaryKey: rowKey,
              ...sqliteRow(target),
            });
            continue;
          }
          if (canonicalRevisionRow(table, rowKey, target) ==
              canonicalRevisionRow(table, rowKey, current)) {
            continue;
          }
          final update = <String, Object?>{};
          for (final entry in target.entries) {
            if (entry.key == primaryKey) continue;
            final before = current[entry.key];
            if (before != null &&
                jsonEncode(before.toJson()) ==
                    jsonEncode(entry.value.toJson())) {
              continue;
            }
            update[entry.key] = entry.value.sqliteValue;
          }
          if (update.isEmpty) continue;
          await updateRow(
            txn,
            table,
            update,
            where: '$primaryKey = ?',
            whereArgs: [rowKey],
          );
        }
      }, label: '以云端为准重新对齐');
      // 重新对齐之后本机没有待推送提交：对齐提交的内容云端已经有了，推送位置
      // 直接推进到当前 HEAD；云端没有行的本机独有行照常作为基线补传。
      final headAfterAlign = await engine.headId(database.raw);
      final projection = await engine.readProjection(database.raw);
      final changes = _baselineChanges(projection, skip: touched);
      final summary = changes.isEmpty ? null : await _baselineSummary();
      final upload = await _uploadBaseline(
        deviceId,
        changes,
        baseSeq: serverHead,
        stateDigest: summary?.digest,
        tableDigests: summary?.tables,
      );
      _ensureIdentity();
      await _saveServerHead(upload.serverHead);
      await _savePushed(headAfterAlign);
      await _shadows.clear();
      await _saveDigestMismatch(false);
      await _markSynced();
      await refreshDevices();
      return SyncResult(
        pulledCommits: pulled,
        pushedCommits: upload.pushed,
        uploadedAssets: upload.uploaded,
      );
    } catch (error, stack) {
      if (error is! SyncIdentityChanged) {
        recordFailure(error, stack, kind: 'cloud_sync');
      }
      rethrow;
    } finally {
      _runEpoch = null;
    }
  }

  /// 云端历史被压缩时的“以云端为准修复”：按快照重新克隆，再补传云端没有的
  /// 本机行（同步方案 3.7 第 4 条，入口口径与 3.5 的差异重放一致）。
  ///
  /// 本机独有的行在替换之前先合并进快照投影一起装入本机，这样修复完成时本机
  /// 仍然有这些行；它们随后作为基线提交补传。云端已有的行一律以快照与快照之后
  /// 的提交为准，本机与云端不同的副本被覆盖，与差异重放路径的“以云端为准”
  /// 相同。
  Future<SyncResult> _repairFromCloudBySnapshot(
    ServerSnapshot snapshot, {
    required String deviceId,
  }) async {
    // 云端没有的本机行照旧补传：替换之前先留一份本机投影。
    final local = await engine.readProjection(database.raw);
    final fetched = await _downloadSnapshotProjection(snapshot);
    _ensureIdentity();
    final projection = fetched.projection;
    final touched = <(String, String)>{
      for (final entry in projection.entries)
        for (final key in entry.value.keys) (entry.key, key),
    };
    // 把本机独有的行并进快照投影：修复完成时本机仍然有这些行，随后按基线补传。
    final merged = <String, Map<String, TypedRow>>{
      for (final entry in projection.entries)
        entry.key: <String, TypedRow>{...entry.value},
    };
    final localOnly = _baselineChanges(local, skip: touched);
    for (final change in localOnly) {
      merged.putIfAbsent(change.table, () => {})[change.rowKey] = change.after!;
    }
    final imported = await _importSnapshotProjection(merged);
    _ensureIdentity();
    await _saveServerHead(snapshot.seq);
    await _savePushed(imported.id);
    final pulled = await _pull(
      serverHead: snapshot.seq,
      deviceId: deviceId,
      downloaded: (_) {},
      touchedRows: touched,
    );
    var serverHead = pulled.serverHead;
    // 快照之后的提交也可能碰到这些行：碰到过的行已经由远端提交表达，不再补传。
    final changes = [
      for (final change in localOnly)
        if (!touched.contains((change.table, change.rowKey))) change,
    ];
    final summary = changes.isEmpty || _pulledSkipped > 0
        ? null
        : await _baselineSummary();
    final upload = await _uploadBaseline(
      deviceId,
      changes,
      baseSeq: serverHead,
      stateDigest: summary?.digest,
      tableDigests: summary?.tables,
    );
    _ensureIdentity();
    await _saveServerHead(upload.serverHead);
    await _savePushed(imported.id);
    await _shadows.clear();
    await _saveDigestMismatch(false);
    await _markSynced();
    return SyncResult(
      pulledCommits: pulled.pulled,
      pushedCommits: upload.pushed,
      uploadedAssets: upload.uploaded,
      downloadedAssets: fetched.downloaded,
    );
  }

  /// “以本机为准修复”：把本机独有的行按首次基线的方式推上去（同步方案 3.5、
  /// 3.6）。
  ///
  /// 先增量拉取云端的新提交，据此知道哪些“表名 + 主键”已经由远端提交表达过，
  /// 这些行在本机的副本不再上传；其余行作为基线提交推送，所以它只补云端缺的
  /// 内容，不删除云端已有的行。已经收到过的远端提交照常在本机应用，本机被直接
  /// 改过、没有提交记录表达的行由基线补上去。成功后且有内容上传时清掉不一致
  /// 标记；一行都没传说明两边只差在云端多出来的内容，标记留着等下一次同步重新
  /// 判断。账号还没有同步位置时按首次基线重新对齐一次。
  Future<SyncResult> repairFromLocal() async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) throw const AccountSignedOut();
    await _waitForRunningSync();
    final deviceId = await account.deviceId();
    final epoch = account.identityEpoch;
    _runEpoch = epoch;
    _pulledSkipped = 0;
    _knownDigestMismatch = false;
    try {
      final pushedCursor = await _cursors.read(RevisionCursor.syncPushed);
      if (!_positionLinked(pushedCursor)) {
        // 还没有同步位置（这个账号第一次同步）：按首次基线重新对齐，确认之后
        // 上传本机独有的行，与“立即同步”的第一步相同。用户已经确认过“以本机
        // 为准修复”，云端历史压缩时按快照重建同样带上确认，不再多问一次。
        final result = await syncNow(
          confirmBaseline: true,
          confirmReclone: true,
        );
        await _verifyRepairDigest(deviceId);
        return result;
      }
      final current = await _pull(
        serverHead: await _serverHeadPosition(),
        deviceId: deviceId,
        downloaded: (count) {},
      );
      final cloud = await _readCloudProjection(
        deviceId,
        through: current.serverHead,
      );
      final pushedRows = cloud.touched;
      if (cloud.compacted) pushedRows.addAll(await _remoteTouchedRows());
      final localHead = await engine.headId(database.raw);
      final projection = await engine.readProjection(database.raw);
      final differentTables =
          (await preferences.syncState())?.differentTables ?? const <String>[];
      final changes = _baselineChanges(
        projection,
        skip: pushedRows,
        tables: differentTables.isEmpty ? null : differentTables.toSet(),
      );
      for (final change in changes) {
        cloud.projection.putIfAbsent(change.table, () => {})[change.rowKey] =
            change.after!;
      }
      final cloudTables = revisionTableDigests(cloud.projection);
      final localTables = revisionTableDigests(projection);
      final matches = versionedTableNames.every(
        (table) => cloudTables[table] == localTables[table],
      );
      final upload = await _uploadBaseline(
        deviceId,
        changes,
        baseSeq: current.serverHead,
        stateDigest: matches
            ? revisionStateDigestHex(revisionTableDigestsSum(cloudTables))
            : null,
        tableDigests: matches ? cloudTables : null,
      );
      _ensureIdentity();
      await _saveServerHead(upload.serverHead);
      await _savePushed(localHead);
      await _shadows.deleteSettled(localHead);
      await _compareRepairDigest(cloudTables);
      await _markSynced();
      await refreshDevices();
      return SyncResult(
        pulledCommits: current.pulled,
        pushedCommits: upload.pushed,
        uploadedAssets: upload.uploaded,
      );
    } catch (error, stack) {
      if (error is! SyncIdentityChanged) {
        recordFailure(error, stack, kind: 'cloud_sync');
      }
      rethrow;
    } finally {
      _runEpoch = null;
    }
  }

  Future<void> _verifyRepairDigest(String deviceId) async {
    final head = await account.call(
      (client, token) => client.head(token, deviceId: deviceId),
    );
    final cloud = await _readCloudProjection(deviceId, through: head.head);
    await _compareRepairDigest(revisionTableDigests(cloud.projection));
  }

  Future<
    ({Projection projection, Set<(String, String)> touched, bool compacted})
  >
  _readCloudProjection(String deviceId, {required int through}) async {
    final head = await account.call(
      (client, token) => client.head(token, deviceId: deviceId),
    );
    final snapshot = head.snapshot;
    final Projection cloud = {};
    final touched = <(String, String)>{};
    var after = 0;
    if (head.historyCompacted) {
      if (snapshot == null || snapshot.seq > through) {
        throw const SyncSnapshotProblem.unavailable();
      }
      final base = (await _downloadSnapshotProjection(snapshot)).projection;
      for (final entry in base.entries) {
        cloud[entry.key] = {...entry.value};
        touched.addAll(entry.value.keys.map((key) => (entry.key, key)));
      }
      after = snapshot.seq;
    }
    while (after < through) {
      final page = await account.call(
        (client, token) => client.pull(token, after: after),
      );
      _ensureIdentity();
      if (page.commits.isEmpty) throw StateError('核对修复结果时云端位置已改变');
      for (final commit in page.commits) {
        if (commit.seq != null && commit.seq! > through) break;
        for (final change in commit.changes) {
          touched.add((change.table, change.rowKey));
          _applyChangeToCloudProjection(cloud, change);
        }
      }
      after = page.commits.last.seq ?? page.head;
    }
    return (
      projection: cloud,
      touched: touched,
      compacted: head.historyCompacted,
    );
  }

  Future<void> _compareRepairDigest(Map<String, String> cloudTables) async {
    final local = await revisions.currentTableDigests();
    final differentTables = [
      for (final table in versionedTableNames)
        if (local[table] != cloudTables[table]) table,
    ];
    _ensureIdentity();
    await _saveDigestMismatch(
      differentTables.isNotEmpty,
      differentTables: differentTables,
    );
  }

  void _applyChangeToCloudProjection(Projection cloud, ServerChange change) {
    final rows = cloud.putIfAbsent(change.table, () => {});
    if (change.op == 'delete') {
      rows.remove(change.rowKey);
      return;
    }
    final after = decodeTypedRow(jsonEncode(change.after));
    rows[change.rowKey] = change.op == 'insert'
        ? after
        : {...?rows[change.rowKey], ...after};
  }

  /// 本机历史里被远端提交碰过的“表名 + 主键”。
  ///
  /// 服务端序列里的每一行都来自某条远端提交，所以这些行在本机的副本不该再进
  /// 基线；“以本机为准修复”据此只推本机独有的行（同步方案 3.6）。
  Future<Set<(String, String)>> _remoteTouchedRows() async {
    final rows = await database.raw.rawQuery(
      'SELECT DISTINCT c.table_name AS table_name, c.row_key AS row_key '
      'FROM revision_change c '
      'JOIN revision_commit m ON m.id = c.commit_id '
      "WHERE m.kind = 'remote'",
    );
    return {
      for (final row in rows)
        (row['table_name']! as String, row['row_key']! as String),
    };
  }
}
