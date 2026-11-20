import '../../domain/rules/time_policy.dart';
import '../db/guarded_database.dart';
import '../db/sql.dart';
import 'asset_store.dart';
import 'revision_actions.dart';
import 'revision_engine.dart';
import '../db/raw_executor.dart';
import 'revision_models.dart';
import 'revision_undo.dart';

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
/// 本机状态对不上而跳过的条数；[duplicate] 表示这个请求编号已经应用过。
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
  }) : assets = assets ?? AssetStore();

  final GuardedDatabase db;
  final RawDatabase Function() raw;
  final RevisionEngine engine;
  final Clock clock;
  final AssetStore assets;
  final AttachmentCache cache;

  /// 版本恢复或单项撤销真正改了当前数据之后通知应用根推进代次：恢复前
  /// 发出的模型回答与判断不能再写回，三栏也要重读。
  final Future<void> Function()? onDataChanged;

  /// 图片缓存重建失败只记诊断，不影响已经提交的数据版本；下次启动会重试。
  final void Function(Object error, StackTrace? stack)? onCacheFailure;

  late final RevisionUndoService undo = RevisionUndoService(
    engine: engine,
    clock: clock,
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
  Future<Set<int>> activeCommits(Iterable<int> commitIds) =>
      engine.activeCommits(db.raw, commitIds);

  /// 提交列表用的撤销判断：同一套白名单与代次规则，值为不能撤销的原因。
  Future<Map<int, String?>> undoBlockReasons(
    Iterable<RevisionCommit> commits,
  ) => undo.undoBlockReasons(db.raw, commits);

  /// 当前代次里还没撤销的提交，安排页从中挑出要展示的 AI 改动。
  Future<List<RevisionCommit>> undoableCommits() =>
      engine.undoableCommits(db.raw);

  /// 安排页的回执：指定动作且改到指定表的提交，一次查询取回。
  Future<List<RevisionCommit>> receiptCommits({
    required Set<String> actions,
    required Set<String> tables,
  }) => engine.receiptCommits(db.raw, actions: actions, tables: tables);

  Future<RevisionRestorePreview> previewRestore(int target) =>
      engine.previewRestore(db.raw, target);

  /// 恢复到本机版本：数据事务提交后就算成功；图片缓存重建单独处理，失败只
  /// 返回一条说明，不能把已经完成的恢复报成失败。
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
  /// 照常可用；请求编号沿用远端的，服务端重复下发时不会在本机叠加第二次。
  Future<RemoteApplyResult> applyRemoteCommit({
    required String requestId,
    required String action,
    required String actor,
    required List<RevisionChange> changes,
  }) async {
    final existing = await engine.commitByRequest(db.raw, requestId);
    if (existing != null) {
      return RemoteApplyResult(commit: existing, skipped: 0, duplicate: true);
    }
    var skipped = 0;
    await db.command<RevisionCommit?>(
      (txn) async {
        skipped = await engine.applyChanges(txn, changes);
        return null;
      },
      label: action,
      actor: actor,
      requestId: requestId,
      kind: RevisionKind.remote,
      onDuplicate: (_) => null,
    );
    return RemoteApplyResult(
      commit: await engine.commitByRequest(db.raw, requestId),
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
  /// 阶段 0 为空实现，由泳道 S 接上：读 `local_json`，开一条普通写入事务写回，
  /// 在这条提交上记 `resolved_commit_id`。
  Future<RevisionCommit?> keepLocal(int conflictId) async => null;

  /// 历史下游读者是否允许裁剪或清理；[clearing] 为真时对应“清理历史”。
  Future<List<String>> historyBlockers({bool clearing = false}) =>
      engine.historyBlockers(db.raw, clearing: clearing);

  /// 编号大于 [after] 的提交，推送前从这里取；编号已经由版本引擎分配。
  Future<List<RevisionCommit>> commitsAfter(int after) =>
      engine.commitsAfter(db.raw, after);

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

  Future<RevisionUndoResult> undoCommit(int commitId) {
    return db.gate.exclusive(() async {
      final result = await undo.undo(raw(), commitId);
      if (result.applied) {
        await cache.rebuild(raw(), assets);
        await onDataChanged?.call();
      }
      return result;
    });
  }

  /// 默认历史预算；超过时继续减少保留提交数，命名版本与当前数据不裁剪。
  static const int defaultHistoryBudgetBytes = 256 * 1024 * 1024;

  /// 裁剪只删旧提交与变更明细，消息里的回执还要清；回执清理作为清理之后的
  /// 一条普通提交写入，保证检查点与重建结果跟当前数据一致。
  Future<RevisionRetentionResult> prune({
    int keepCommits = 100,
    int? maxBytes = defaultHistoryBudgetBytes,
  }) {
    return db.gate.exclusive(() async {
      final result = await engine.prune(
        raw(),
        keepCommits: keepCommits,
        maxBytes: maxBytes,
      );
      await _stripDeadReceipts();
      db.notifyTables(_historyTables);
      return result;
    });
  }

  Future<void> clearHistory() {
    return db.gate.exclusive(() async {
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

  Future<int> databaseBytes() => engine.databaseBytes(db.raw);
}
