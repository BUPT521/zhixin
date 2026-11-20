import '../../domain/rules/time_policy.dart';
import '../db/guarded_database.dart';
import '../db/sql.dart';
import 'asset_store.dart';
import 'revision_actions.dart';
import 'revision_digest.dart';
import 'revision_engine.dart';
import '../db/raw_executor.dart';
import 'revision_models.dart';
import 'revision_undo.dart';

/// 把同步冲突里的本机值写回时留的提交说明；只给人看，不参与类型判断。
const String _keepLocalAction = '保留本机修改';

/// 提交详情：一条提交与它的净变化。
class RevisionDetails {
  const RevisionDetails({required this.commit, required this.changes});

  final RevisionCommit commit;
  final List<RevisionChange> changes;
}

/// 历史页需要的提交、`HEAD` 与命名版本。
class RevisionHistory {
  const RevisionHistory({
    required this.head,
    required this.commits,
    required this.refs,
  });

  final int head;
  final List<RevisionCommit> commits;
  final List<RevisionRef> refs;

  Map<int, List<RevisionRef>> get refsByCommit {
    final result = <int, List<RevisionRef>>{};
    for (final ref in refs) {
      result.putIfAbsent(ref.commitId, () => []).add(ref);
    }
    return result;
  }
}

/// 应用一条远端提交的结果：本机新生成的提交编号（没有净变化时为空）与因
/// 本机状态对不上而跳过的条数；[duplicate] 表示这个提交身份已经应用过。
///
/// 被远端值覆盖的本机格子由版本引擎在同一个事务里登记进 `sync_shadow`，
/// 不经过这一层（ADR-0040）。
class RemoteApplyResult {
  const RemoteApplyResult({
    required this.commit,
    required this.skipped,
    required this.duplicate,
  });

  final RevisionCommit? commit;
  final int skipped;
  final bool duplicate;
}

/// 页面与设置入口使用的一层：历史、比较、命名、撤销、整版恢复、留存与清理。
///
/// 读写都经同一个 [GuardedDatabase]，恢复和清理走独占区；重建与比较在独占区
/// 外完成，提交时再核对预览时的 `HEAD`。
class RevisionService {
  RevisionService({
    required this.db,
    required this.raw,
    required this.engine,
    required this.clock,
    required this.cache,
    AssetStore? assets,
    this.onDataChanged,
    this.onCacheFailure,
    this.undoGuards = const [],
  }) : assets = assets ?? AssetStore();

  final GuardedDatabase db;
  final RawDatabase Function() raw;
  final RevisionEngine engine;
  final Clock clock;
  final AssetStore assets;
  final AttachmentCache cache;

  /// 撤销的业务约束与可撤销表白名单；由应用层在装配时传入
  /// （`lib/application/undo_guards/`），数据层不内置业务规则（ADR-0039）。
  final List<UndoGuard> undoGuards;

  /// 版本恢复或单项撤销真正改了当前数据之后通知应用根推进代次：恢复前
  /// 发出的模型回答与判断不能再写回，三栏也要重读。
  final Future<void> Function()? onDataChanged;

  /// 图片缓存重建失败只记诊断，不影响已经提交的数据版本；下次启动会重试。
  final void Function(Object error, StackTrace? stack)? onCacheFailure;

  late final RevisionUndoService undo = RevisionUndoService(
    engine: engine,
    clock: clock,
    guards: undoGuards,
  );

  /// 命名版本、裁剪与清理会改到的版本表；历史页订阅的就是这几张。
  static const Set<String> _historyTables = {
    ...revisionHistoryTables,
    'revision_checkpoint',
  };

  Future<RevisionHistory> history({int limit = 200}) async {
    final head = await engine.headId(db.raw);
    final commits = await engine.commits(db.raw, limit: limit);
    final refs = await engine.refs(db.raw);
    return RevisionHistory(head: head, commits: commits, refs: refs);
  }

  Future<RevisionDetails?> details(int commitId) async {
    final commit = await engine.commitById(db.raw, commitId);
    if (commit == null) return null;
    return RevisionDetails(
      commit: commit,
      changes: await engine.changesFor(db.raw, commitId),
    );
  }

  /// 某一行在提交历史里的修改，按提交编号倒序；只取当前代次。
  ///
  /// 材料详情用它列出每一页的更正记录。撤销提交本身不进入列表，已经撤销的
  /// 更正仍在结果里，界面按 [activeCommits] 标出状态。
  Future<List<RevisionCommit>> rowHistory({
    required String table,
    required String rowKey,
    int limit = 20,
  }) => engine.rowHistory(db.raw, table: table, rowKey: rowKey, limit: limit);

  /// 两个提交之间的净变化；`HEAD` 一侧直接读当前表，不再做两次重建。
  ///
  /// 起点在保留历史之外或中间有基线跳变时退回两次重建，见
  /// [RevisionEngine.foldChanges] 与 [RevisionEngine.compare]。
  Future<RevisionDiff> compare(int from, int to) =>
      engine.compare(db.raw, from, to);

  /// 界面的回执是否仍然可以撤销；整版恢复之后的旧提交不在结果里。
  ///
  /// 判断走撤销服务：撤销提交可以再撤销（重做），所以“被回指过”不等于永久
  /// 失效，重做之后原提交重新可撤销（方案 3.11）。
  Future<Set<int>> activeCommits(Iterable<int> commitIds) =>
      undo.activeCommits(db.raw, commitIds);

  /// 提交列表用的撤销判断：同一套白名单与代次规则，值为不能撤销的原因。
  Future<Map<int, String?>> undoBlockReasons(
    Iterable<RevisionCommit> commits,
  ) => undo.undoBlockReasons(db.raw, commits);

  /// 当前代次里还没撤销的提交，安排页从中挑出要展示的 AI 改动。
  ///
  /// 与回执同一口径：重做之后原提交重新进入结果，撤销提交本身不在这里。
  Future<List<RevisionCommit>> undoableCommits() =>
      undo.undoableCommits(db.raw);

  /// 安排页的回执：指定动作且改到指定表的提交，一次查询取回。
  ///
  /// 撤销链的判断在撤销服务里：撤销提交可以再撤销（重做），重做之后原提交
  /// 重新可撤销，安排页据此重新给出回执。
  Future<List<RevisionCommit>> receiptCommits({
    required Set<String> actions,
    required Set<String> tables,
  }) => undo.receiptCommits(db.raw, actions: actions, tables: tables);

  /// 恢复预览：与恢复读同一份反向净变化，不再重建两份整库投影。
  ///
  /// 目标提交在保留历史内、能按提交明细折叠出净变化时，恢复就是把这份变化反
  /// 过来写，预览直接按同一份反向变化给出新增、修改与删除的数量；起点被裁掉、
  /// 中间有基线跳变或明细不完整时退回整库替换，预览也跟着比较两份投影
  /// （方案 3.9）。
  Future<RevisionRestorePreview> previewRestore(int target) =>
      engine.previewRestore(db.raw, target);

  /// 恢复到本机版本：先按净变化反向写入有差异的行，不可用时整库替换。
  ///
  /// 两段路径都在同一个命令事务里追加一条 `restore` 提交并推进代次；数据事务
  /// 提交后就算成功，图片缓存重建单独处理，失败只返回一条说明，不能把已经完成
  /// 的恢复报成失败。
  Future<({RevisionCommit commit, String? cacheWarning})> restore(
    int target, {
    required int expectedHead,
  }) {
    return db.gate.exclusive(() async {
      await cache.markPendingRebuild();
      final commit = await engine.restore(
        raw(),
        target,
        expectedHead: expectedHead,
      );
      String? cacheWarning;
      try {
        await cache.rebuild(raw(), assets);
        await cache.clearPendingRebuild();
      } catch (error, stack) {
        cacheWarning = '数据已恢复，但图片缓存没有重建完成，下次打开应用会再试。';
        onCacheFailure?.call(error, stack);
      }
      await onDataChanged?.call();
      return (commit: commit, cacheWarning: cacheWarning);
    });
  }

  /// 应用一条远端提交：本机因此生成一条同样的净变化提交，撤销与数据版本页
  /// 照常可用；提交身份沿用远端的 uid，服务端重复下发时不会在本机叠加第二次。
  ///
  /// [originDevice] 与 [authoredAt] 是服务端带来的设备标识与作者创建时间，原样
  /// 记进本机提交行；两者都是可选参数，调用方没有时按本机提交处理，`authored_at`
  /// 取落库时间、`origin_device` 留空（方案 3.12）。取值的接线由后续同步任务做，
  /// 这一层只留接口。
  ///
  /// 事务自己开，而不是走 `db.command`，因为被覆盖的本机修改要与提交行一起
  /// 写进 `revision_conflict`（由 `finishCommand` 的 `conflicts` 参数写入），
  /// 提交的 `conflict_count` 也随之更新；被远端取代的本机格子同样在这个事务里
  /// 登记进 `sync_shadow`（由 `applyChanges` 写入，ADR-0040）。
  Future<RemoteApplyResult> applyRemoteCommit({
    required String uid,
    required String action,
    required String actor,
    required List<RevisionChange> changes,
    String? originDevice,
    DateTime? authoredAt,
  }) async {
    final existing = await engine.commitByUid(db.raw, uid);
    if (existing != null) {
      return RemoteApplyResult(commit: existing, skipped: 0, duplicate: true);
    }
    var skipped = 0;
    var duplicate = false;
    final changed = <String>{};
    await db.gate.exclusive(() async {
      await raw().transaction((txn) async {
        // 独占区外已经查过一次；并发调用可能在这之间先落库，事务里再确认一次。
        final appliedBefore = await engine.commitByUid(txn, uid);
        if (appliedBefore != null) {
          duplicate = true;
          return;
        }
        await engine.beginCommand(txn);
        final applied = await engine.applyChanges(txn, changes);
        skipped = applied.skipped;
        await engine.finishCommand(
          txn,
          action: action,
          actor: actor,
          uid: uid,
          changedTables: changed,
          kind: RevisionKind.remote,
          conflicts: applied.conflicts,
          originDevice: originDevice,
          authoredAt: authoredAt,
        );
      });
      if (changed.isNotEmpty) {
        db.notifyTables(changed);
        db.onCommitted?.call(changed);
      }
    });
    if (duplicate) {
      return RemoteApplyResult(
        commit: await engine.commitByUid(db.raw, uid),
        skipped: 0,
        duplicate: true,
      );
    }
    final commit = await engine.commitByUid(db.raw, uid);
    // 独占区已经释放；空闲检查点与索引补建在这里做（ADR-0039 第 2 条）。
    await engine.afterCommitIdle(db);
    return RemoteApplyResult(
      commit: commit,
      skipped: skipped,
      duplicate: false,
    );
  }

  /// 本机被远端提交覆盖的修改；[unresolved] 为真时只列还没处理过的。
  Future<List<RevisionConflict>> conflicts({bool unresolved = true}) async {
    final rows = await selectRows(
      db.raw,
      'revision_conflict',
      where: unresolved ? 'resolved_commit_id IS NULL' : null,
      orderBy: 'id DESC',
    );
    return rows.map(RevisionConflict.fromRow).toList(growable: false);
  }

  /// 把一条冲突记录里的本机值作为新的普通提交写回，并把冲突标为已处理。
  ///
  /// 写回的是冲突行 `local_json` 里的值：并发更新只写冲突列，新增撞上本机
  /// 已有主键与远端删掉本机改过的行写回整行。写回的提交照常推送，在其他设备
  /// 上就是一次正常的后到覆盖。本机已经删掉那一行（`deleted_locally`）时没有
  /// 可以写回的本机值，接口返回空并保留记录；记录不存在或已经处理时同样返回空。
  Future<RevisionCommit?> keepLocal(int conflictId) async {
    final rows = await selectRows(
      db.raw,
      'revision_conflict',
      where: 'id = ?',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final conflict = RevisionConflict.fromRow(rows.first);
    if (conflict.isResolved) return null;
    RevisionCommit? commit;
    final changed = <String>{};
    await db.gate.exclusive(() async {
      await raw().transaction((txn) async {
        final fresh = await selectRows(
          txn,
          'revision_conflict',
          where: 'id = ? AND resolved_commit_id IS NULL',
          whereArgs: [conflictId],
          limit: 1,
        );
        if (fresh.isEmpty) return;
        await engine.beginCommand(txn);
        final written = await engine.restoreConflictLocal(txn, conflict);
        final applied = await engine.finishCommand(
          txn,
          action: _keepLocalAction,
          kind: RevisionKind.write,
          changedTables: changed,
        );
        if (written && applied != null) {
          await updateRow(
            txn,
            'revision_conflict',
            {'resolved_commit_id': applied.id},
            where: 'id = ?',
            whereArgs: [conflictId],
          );
          commit = applied;
        }
      });
      if (changed.isNotEmpty) {
        db.notifyTables(changed);
        db.onCommitted?.call(changed);
      }
    });
    if (commit != null) await engine.afterCommitIdle(db);
    return commit;
  }

  /// 消解一条没有可写回本机值的冲突记录（本机已经删掉那一行）。
  ///
  /// 这条记录只说明远端的修改没有写入，用户确认之后直接删除，不形成提交，
  /// 也不改业务数据；其余三种冲突要写回本机值，走 [keepLocal]，这里返回 false。
  Future<bool> dismissConflict(int conflictId) async {
    final rows = await selectRows(
      db.raw,
      'revision_conflict',
      where: 'id = ? AND resolved_commit_id IS NULL',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final conflict = RevisionConflict.fromRow(rows.first);
    if (conflict.reason != RevisionConflict.deletedLocally) return false;
    final removed = await db.execute(
      'DELETE FROM revision_conflict WHERE id = ?',
      [conflictId],
    );
    return removed > 0;
  }

  /// 历史下游读者是否允许裁剪或清理；[clearing] 为真时对应“清理历史”。
  Future<List<String>> historyBlockers({bool clearing = false}) =>
      engine.historyBlockers(db.raw, clearing: clearing);

  /// 编号大于 [after] 的提交，推送前从这里取；编号已经由版本引擎分配。
  ///
  /// 远端提交（`kind = remote`）对应服务端已有的提交，不在待推送范围里。
  Future<List<RevisionCommit>> commitsAfter(int after) async {
    final commits = await engine.commitsAfter(db.raw, after);
    return [
      for (final commit in commits)
        if (commit.kind != RevisionKind.remote) commit,
    ];
  }

  Future<RevisionRef> name(
    int commitId, {
    required String label,
    String? note,
  }) {
    return db.gate.exclusive(() async {
      final ref = await engine.nameCommit(
        raw(),
        commitId,
        name: label,
        note: note,
      );
      db.notifyTables(_historyTables);
      return ref;
    });
  }

  Future<void> deleteName(String label) {
    return db.gate.exclusive(() async {
      await engine.deleteName(raw(), label);
      db.notifyTables(_historyTables);
    });
  }

  /// 撤销一次提交：数据事务提交后就算成功；图片缓存重建单独处理，失败只返回
  /// 一条说明，不能把已经生效的撤销报成失败（与 [restore] 同一处理方式）。
  Future<RevisionUndoResult> undoCommit(int commitId) {
    return db.gate.exclusive(() async {
      final result = await undo.undo(raw(), commitId);
      if (!result.applied) return result;
      String? cacheWarning;
      try {
        await cache.markPendingRebuild();
        await cache.rebuild(raw(), assets);
        await cache.clearPendingRebuild();
      } catch (error, stack) {
        // 撤销与重做共用这一条：动作名取自数据层的结果，缓存失败时不说反。
        cacheWarning = '${result.message}，但图片缓存没有重建完成，下次打开应用会再试。';
        onCacheFailure?.call(error, stack);
      }
      await onDataChanged?.call();
      return RevisionUndoResult(
        applied: true,
        message: cacheWarning ?? result.message,
        commit: result.commit,
      );
    });
  }

  /// 默认历史预算；更早的提交在这个预算之内保留，命名版本与当前数据不裁剪。
  static const int defaultHistoryBudgetBytes = revisionHistoryBudgetBytes;

  /// 裁剪只删旧提交与变更明细，消息里的回执还要清；回执清理作为清理之后的
  /// 一条普通提交写入，保证检查点与重建结果跟当前数据一致。
  ///
  /// [retentionDays] 天以内的提交全部保留，更早的按 [maxBytes] 预算保留；
  /// 自动裁剪与这里共用 [RevisionMaintenanceMixin.retentionBoundary] 算出的
  /// 下界，所以手动与自动的结果一致。
  Future<RevisionRetentionResult> prune({
    int retentionDays = revisionDefaultRetentionDays,
    int? maxBytes = defaultHistoryBudgetBytes,
  }) {
    return db.gate.exclusive(() async {
      final result = await engine.prune(
        raw(),
        retentionDays: retentionDays,
        maxBytes: maxBytes,
      );
      await _stripDeadReceipts();
      db.notifyTables(_historyTables);
      return result;
    });
  }

  /// 清理历史；有阻塞的历史读取位置时抛出 [RevisionBlocked]，界面据此显示
  /// 原因并禁用确认。
  Future<void> clearHistory() {
    return db.gate.exclusive(() async {
      final blockers = await engine.historyBlockers(raw(), clearing: true);
      if (blockers.isNotEmpty) throw RevisionBlocked(blockers);
      await engine.clearHistory(raw());
      await _stripDeadReceipts();
      db.notifyTables(_historyTables);
    });
  }

  Future<void> _stripDeadReceipts() async {
    await db.command(
      (txn) => engine.stripDeadReceipts(txn),
      label: clearDeadReceiptsAction,
      kind: RevisionKind.maintenance,
    );
  }

  /// 检查点按提交编号倒序；`payload` 是压缩后的投影，由版本引擎按 `encoding`
  /// 解码，调用方不需要自己解压。
  Future<List<RevisionCheckpoint>> checkpoints() => engine.checkpoints(db.raw);

  Future<RevisionStorageUsage> storageUsage() async {
    final databaseBytes = await engine.databaseBytes(db.raw);
    final assetRows = await db.rawQuery(
      'SELECT COUNT(*) AS count, COALESCE(SUM(byte_length), 0) AS bytes '
      'FROM asset_object',
    );
    final checkpoints = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM revision_checkpoint',
    );
    final commits = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM revision_commit',
    );
    final names = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM revision_ref WHERE name != ?',
      [RevisionRef.headName],
    );
    int value(List<Map<String, Object?>> rows, String key) =>
        rows.isEmpty ? 0 : (rows.first[key] as int? ?? 0);
    return RevisionStorageUsage(
      databaseBytes: databaseBytes,
      assetBytes: value(assetRows, 'bytes'),
      assetCount: value(assetRows, 'count'),
      checkpointCount: value(checkpoints, 'count'),
      commitCount: value(commits, 'count'),
      namedCount: value(names, 'count'),
    );
  }

  Future<List<String>> verifyAssets() => engine.verifyAssets(db.raw);

  /// 当前数据的摘要，按当前业务表整库重算（方案 3.5）。
  ///
  /// 同步摘要交换与完整性检查从这里取；它与 `HEAD` 记录的 `state_digest` 相等
  /// 表示当前数据就是从提交历史来的。
  Future<String> currentStateDigest() => engine.currentStateDigest(db.raw);

  /// 哈希链的锚点：最早保留提交记录的父哈希；空库返回哈希链初值（方案 3.10）。
  Future<String> chainAnchor() => engine.chainAnchor(db.raw);

  /// 数据完整性检查：保留历史的哈希链与当前摘要（方案 3.10）。
  ///
  /// 只读，不改数据；“检查数据完整性”入口与导出前检查由后续任务接在这里。
  Future<RevisionIntegrityReport> verifyIntegrity() =>
      engine.verifyIntegrity(db.raw);

  Future<int> databaseBytes() => engine.databaseBytes(db.raw);
}
