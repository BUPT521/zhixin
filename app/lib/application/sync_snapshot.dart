part of 'sync_service.dart';

extension SyncSnapshotFlow on SyncService {
  /// 第一次同步：按服务端 head 决定用云端快照浅克隆还是全量回放。
  ///
  /// 保留下界大于 1 说明快照之前的提交已经被压缩删除，全量回放读不到它们，这时
  /// 必须用快照：按 [ServerSnapshot.sha256] 下载快照、核对哈希与整库摘要，把投影
  /// 装进本机并追加一条本机提交，两个位置写成快照位置，再按 `after=snapshot.seq`
  /// 增量拉取（同步方案 3.7）。新库只有空基线，装完之后直接就能继续追加提交与
  /// 同步；本机已有历史时这条路径会替换本机历史，先由用户确认才执行，本机还没有
  /// 推送的提交在快照之上重放。
  ///
  /// 保留下界是 1 时快照之前的提交仍然可以拉取，首次同步继续走全量回放：先拉取
  /// 云端已有的记录，再把本机独有、云端还没有的行作为基线上传（同步方案 3.6）。
  /// 已经在保留期内登记的快照因此不会让落后不多的设备白白改写本机历史。
  /// 保留下界大于 1 却没有快照时无法自动重建，抛出 [SyncSnapshotProblem]。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _bootstrap(
    String deviceId, {
    required ServerHead remoteHead,
    required bool confirmReclone,
  }) async {
    if (remoteHead.historyCompacted) {
      final snapshot = remoteHead.snapshot;
      if (snapshot == null) throw const SyncSnapshotProblem.unavailable();
      return _recloneFromSnapshot(
        snapshot,
        deviceId: deviceId,
        pushedThrough: 0,
        confirmReclone: confirmReclone,
      );
    }
    return _bootstrapByReplay(deviceId);
  }

  /// 首次同步的全量回放：把服务端已有的提交全部拉下来，再把本机独有、云端还
  /// 没有的行作为基线提交上传，最后补齐这些行引用到的附件（同步方案 3.6）。
  ///
  /// 服务端的每一行都来自某条远端提交，所以拉取时记下被远端提交触及过的
  /// “表名 + 主键”，组装基线时跳过这些行：它们已经由服务端序列表达，本机这份
  /// 只是拉下来的副本，再传一遍只会让序列多出一整份数据。全新设备本机投影为空
  /// 时一条基线也不产生，服务端序列长度不变，与 `git clone` 一致。被跳过行的
  /// 附件哈希不单独上传：它的内容随那条远端提交可以在服务端取到；被保留下来的
  /// 行如果也引用同一个哈希，按引用去重之后照常上传。
  ///
  /// 收尾时把两个同步位置写进库里的 `revision_cursor`：拉取之后的本机 `HEAD`
  /// 都已经在服务端序列里（推送位置从这里开始），服务端位置记下基线推完之后的
  /// 序列长度。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _bootstrapByReplay(String deviceId) async {
    var pulled = 0;
    var downloaded = 0;
    var serverHead = 0;
    // 这次拉取触及过的行，按“表名 + 主键”记；只在首次同步里用，收尾即丢弃。
    final touchedRows = <(String, String)>{};
    final remoteHead = await account.call(
      (client, token) => client.head(token, deviceId: deviceId),
    );
    if (remoteHead.head > 0) {
      final result = await _pull(
        serverHead: 0,
        deviceId: deviceId,
        persist: false,
        downloaded: (count) => downloaded += count,
        touchedRows: touchedRows,
      );
      pulled = result.pulled;
      serverHead = result.serverHead;
    }
    final headAfterPull = await engine.headId(database.raw);
    final projection = await engine.readProjection(database.raw);
    // 被远端提交触及过的行已经由服务端序列表达，不进基线。
    final changes = _baselineChanges(projection, skip: touchedRows);
    // 基线推送完成、两个同步位置收尾之后，本机没有待推送提交；这时最后一条
    // 基线提交带上当前整库摘要，其他设备拉到它之后可以比较（同步方案 3.5）。
    // 读 HEAD、整库重算之间又有本机写入，或者这次拉取有被跳过的变化（本机状态
    // 与云端对不上），就不带，避免声明一个不成立的云端状态。
    final summary =
        changes.isEmpty || _pulledSkipped > 0 || _knownDigestMismatch
        ? null
        : await _baselineSummary();
    // 附件只跟着基线里的行走：被跳过行的哈希按“服务端已有”处理，本机保留行
    // 也引用到同一个哈希时仍然上传，集合去重。
    final upload = await _uploadBaseline(
      deviceId,
      changes,
      baseSeq: serverHead,
      stateDigest: summary?.digest,
      tableDigests: summary?.tables,
    );
    _ensureIdentity();
    await _saveServerHead(upload.serverHead);
    await _savePushed(headAfterPull);
    // 首次基线把本机独有的内容上传，编号不大于它的本机提交不再单独推送，
    // 换账号或服务端清空后重建时留下的遮蔽行一并清掉。
    await _shadows.deleteSettled(headAfterPull);
    return (
      serverHead: upload.serverHead,
      pulled: pulled,
      pushed: upload.pushed,
      uploaded: upload.uploaded,
      downloaded: downloaded,
    );
  }

  /// 拉取遇到 410：从服务端解析出快照，本机已有数据时先要用户确认再重建。
  ///
  /// 410 的 `extra` 里没有带上快照（旧版服务端、或者字段缺失）时再读一次 head，
  /// 服务端登记过快照就照常重建；两边都没有快照时抛出 [SyncSnapshotProblem]，
  /// 不静默清空本机数据。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _recloneAfterCompaction(
    SyncHistoryCompacted compaction, {
    required String deviceId,
    required int pushedThrough,
    required bool confirmReclone,
  }) async {
    var snapshot = compaction.snapshot;
    if (snapshot == null) {
      final remoteHead = await account.call(
        (client, token) => client.head(token, deviceId: deviceId),
      );
      snapshot = remoteHead.snapshot;
    }
    if (snapshot == null) throw const SyncSnapshotProblem.unavailable();
    return _recloneFromSnapshot(
      snapshot,
      deviceId: deviceId,
      pushedThrough: pushedThrough,
      confirmReclone: confirmReclone,
    );
  }

  /// 按云端快照重新克隆本机（同步方案 3.7 第 1、2 条）。
  ///
  /// 步骤依次是：取出本机还没有推送的提交与它们的剩余变化；下载快照、核对
  /// 哈希与整库摘要、解出投影并补齐它引用到的附件；用投影替换本机数据并追加
  /// 一条“来自云端快照”的本机提交；两个位置写成快照位置与本机 `HEAD`；按
  /// `after=snapshot.seq` 增量拉取快照之后的提交；最后把本机未推送的提交去掉被
  /// 云端遮蔽的格子之后在快照之上重放，写成本机新提交再按普通推送发上去。
  ///
  /// 本机已有历史（`HEAD` 大于 0）而用户没有确认时抛出
  /// [SyncSnapshotProblem]，替换之前不写任何东西：重建会改写本机的数据
  /// 版本历史，不能静默执行。
  Future<
    ({int serverHead, int pulled, int pushed, int uploaded, int downloaded})
  >
  _recloneFromSnapshot(
    ServerSnapshot snapshot, {
    required String deviceId,
    required int pushedThrough,
    required bool confirmReclone,
  }) async {
    final localHead = await engine.headId(database.raw);
    final pending = await revisions.commitsAfter(pushedThrough);
    if (localHead > 0 && !confirmReclone) {
      throw SyncSnapshotProblem.reclone(
        localCommits: pending.length,
        snapshotSeq: snapshot.seq,
      );
    }
    var downloaded = 0;
    var uploaded = 0;
    // 替换投影之后库里读不到本机原有的提交与遮蔽行，先取出这次要重放的内容。
    final shadowsBefore = await _shadows.list();
    final replay =
        <
          ({int id, String action, String actor, List<RevisionChange> changes})
        >[];
    for (final commit in pending) {
      replay.add((
        id: commit.id,
        action: commit.action,
        actor: commit.actor,
        changes: await engine.changesFor(database.raw, commit.id),
      ));
    }
    final fetched = await _downloadSnapshotProjection(snapshot);
    downloaded += fetched.downloaded;
    _ensureIdentity();
    final imported = await _importSnapshotProjection(fetched.projection);
    // 快照之前的提交已经由快照表达：服务端位置写成快照位置，这条本机提交是
    // 重建起点、不上传，推送位置直接写成它的编号，之后的增量从这里接着走。
    _ensureIdentity();
    await _saveServerHead(snapshot.seq);
    await _savePushed(imported.id);
    final pulled = await _pull(
      serverHead: snapshot.seq,
      deviceId: deviceId,
      downloaded: (count) => downloaded += count,
    );
    var pulledCount = pulled.pulled;
    var serverHead = pulled.serverHead;
    // 重放本机未推送的提交：遮蔽行取替换之后库里的全部（含这次拉取刚登记的），
    // 原来那份只在替换前可用，这里合并两边，按格去掉云端已经覆盖的改动。
    final shadows = [...shadowsBefore, ...await _shadows.list()];
    var skipped = 0;
    for (final item in replay) {
      final remaining = _rebaseChanges(item.changes, item.id, shadows);
      if (remaining.isEmpty) continue;
      final result = await database.gate.exclusive(
        () => engine.replayLocalChanges(
          database.resolve(),
          remaining,
          action: item.action.isEmpty ? '从云端快照重建后重放' : item.action,
          actor: _actorOf(item.actor),
        ),
      );
      skipped += result.skipped;
      if (result.commit != null) {
        database.notifyTables({for (final change in remaining) change.table});
      }
    }
    if (skipped > 0) {
      recordFailure(
        StateError('按云端快照重建时跳过 $skipped 条对不上的本机变化'),
        StackTrace.current,
        kind: 'cloud_sync_reclone_replay',
      );
    }
    final push = await _push(
      serverHead: serverHead,
      pushedThrough: imported.id,
      deviceId: deviceId,
      uploaded: (count) => uploaded += count,
      onPulled: (result) {
        pulledCount += result.pulled;
        downloaded += result.downloaded;
      },
    );
    serverHead = push.serverHead;
    return (
      serverHead: serverHead,
      pulled: pulledCount,
      pushed: push.pushed,
      uploaded: uploaded,
      downloaded: downloaded,
    );
  }

  /// 下载并核对一份云端快照：校验附件哈希、解出投影、比对整库摘要，再把投影
  /// 引用到的附件补齐到本机。
  ///
  /// 快照是内容寻址的附件，服务端不解析内容，正确性由客户端保证（ADR-0043）；
  /// 哈希或摘要对不上时抛出 [SyncSnapshotProblem]，这次不替换本机数据。
  Future<({Projection projection, int downloaded})> _downloadSnapshotProjection(
    ServerSnapshot snapshot,
  ) async {
    final bytes = await account.call(
      (client, token) => client.blobDownload(token, snapshot.sha256),
    );
    if (AssetStore.hashBytes(bytes) != snapshot.sha256) {
      throw const SyncSnapshotProblem.invalid('快照附件的哈希与登记的不一致');
    }
    final Projection projection;
    try {
      projection = decodeSnapshotBytes(bytes);
    } catch (error) {
      throw SyncSnapshotProblem.invalid('快照解不开：$error');
    }
    if (snapshot.digest.isNotEmpty &&
        revisionStateDigest(projection) != snapshot.digest) {
      throw const SyncSnapshotProblem.invalid('快照的整库摘要与登记的不一致');
    }
    final downloaded = await _downloadAssets(
      AssetStore.hashesInProjection(projection),
    );
    _ensureIdentity();
    return (projection: projection, downloaded: downloaded);
  }

  /// 用快照投影替换本机数据并追加一条本机提交；页面按业务表与版本表重读。
  Future<RevisionCommit> _importSnapshotProjection(
    Projection projection,
  ) async {
    late RevisionCommit imported;
    await database.gate.exclusive(() async {
      final connection = database.resolve();
      final head = await engine.headId(connection);
      imported = await engine.importSnapshotProjection(
        connection,
        projection,
        expectedHead: head,
        action: '从云端快照重建',
        actor: 'system',
      );
    });
    database.notifyTables({
      ...versionedTableNames,
      ...revisionHistoryTables,
      'revision_checkpoint',
    });
    return imported;
  }

  /// 空闲登记快照：同步到 [serverHead]、没有待推送提交时把当前投影按检查点格式
  /// 压缩上传，再登记 `{seq, sha256, digest}`，服务端据此可以压缩提交序列。
  ///
  /// 只在服务端声明压缩已打开（[compact]）、完全同步、摘要一致、本机没有绕过
  /// 提交的写入时登记：登记错的快照会让之后克隆的设备得到错误数据，服务端不校验
  /// 内容（ADR-0043）。压缩关闭时登记只写指针、不删提交，上传快照只是白占附件
  /// 配额，所以客户端直接跳过（ADR-0047）。同一位置或更新的位置已有快照、同一份
  /// 内容刚登记过、以及服务端已经有这个附件时都跳过；409 表示服务端已有更新的
  /// 快照（或正在清除云端数据），放弃本次；其他失败只记诊断，不影响这一轮同步
  /// 的结果。
  Future<void> _registerSnapshotQuietly({
    required int serverHead,
    required ServerSnapshot? knownSnapshot,
    required bool compact,
    required String deviceId,
  }) async {
    if (!compact) return;
    try {
      if (serverHead <= 0) return;
      if (_pulledSkipped > 0 || _knownDigestMismatch) return;
      final pushed = await _pushedPosition();
      if ((await revisions.commitsAfter(pushed)).isNotEmpty) return;
      if (knownSnapshot != null && knownSnapshot.seq >= serverHead) return;
      final remoteHead = await account.call(
        (client, token) => client.head(token, deviceId: deviceId),
      );
      if (remoteHead.snapshot != null &&
          remoteHead.snapshot!.seq >= serverHead) {
        return;
      }
      final head = await engine.headId(database.raw);
      final headCommit = await engine.commitById(database.raw, head);
      final projection = await engine.readProjection(database.raw);
      final digest = revisionStateDigest(projection);
      // 本机表与 HEAD 记录的摘要对不上说明有绕过提交的写入，这份状态不作为快照。
      if (headCommit?.stateDigest != digest) return;
      final bytes = encodeSnapshotBytes(projection);
      final hash = AssetStore.hashBytes(bytes);
      if (hash == _lastSnapshotHash) return;
      _ensureIdentity();
      final exists = await account.call(
        (client, token) => client.blobExists(token, hash),
      );
      if (exists == null) {
        await account.call(
          (client, token) => client.blobUpload(token, hash, bytes),
        );
      }
      _ensureIdentity();
      await account.call(
        (client, token) => client.registerSnapshot(
          token,
          seq: serverHead,
          sha256: hash,
          digest: digest,
          deviceId: deviceId,
        ),
      );
      _lastSnapshotHash = hash;
    } on ServerProblem catch (error) {
      if (error.isConflict) {
        // 409：服务端已有更新的快照，或者账号正在清除云端数据；这次放弃，
        // 下一轮同步按当时的位置重新判断。
        return;
      }
      recordFailure(error, StackTrace.current, kind: 'cloud_sync_snapshot');
    } catch (error, stack) {
      recordFailure(error, stack, kind: 'cloud_sync_snapshot');
    }
  }
}
