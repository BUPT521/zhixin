import '../../domain/rules/time_policy.dart';
import '../db/guarded_database.dart';
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
    this.onUndoApplied,
    this.onDataChanged,
    this.onCacheFailure,
  }) : assets = assets ?? AssetStore();

  final GuardedDatabase db;
  final RawDatabase Function() raw;
  final RevisionEngine engine;
  final Clock clock;
  final AssetStore assets;
  final AttachmentCache cache;

  /// 撤销成功后通知应用根重新读取设置；每日截止小时会改变时间口径与
  /// 界面分组，不能用启动时缓存的值继续显示。
  final Future<void> Function()? onUndoApplied;

  /// 版本恢复或单项撤销真正改了当前数据之后通知应用根推进代次：恢复前
  /// 发出的模型回答与判断不能再写回，三栏也要重读。
  final Future<void> Function()? onDataChanged;

  /// 图片缓存重建失败只记诊断，不影响已经提交的数据版本；下次启动会重试。
  final void Function(Object error, StackTrace? stack)? onCacheFailure;

  late final RevisionUndoService undo = RevisionUndoService(
    engine: engine,
    clock: clock,
  );

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
  }) async {
    final head = await engine.commitById(db.raw, await engine.headId(db.raw));
    if (head == null) return const [];
    final rows = await db.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      JOIN revision_change ch ON ch.commit_id = c.id
      WHERE ch.table_name = ? AND ch.row_key = ? AND ch.op = 'update'
        AND c.generation = ? AND c.reverted_commit_id IS NULL
      ORDER BY c.id DESC
      LIMIT ?
      ''',
      [table, rowKey, head.generation, limit],
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

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
      final commit = await engine.restore(
        raw(),
        target,
        expectedHead: expectedHead,
      );
      String? cacheWarning;
      try {
        await cache.rebuild(raw(), assets);
      } catch (error, stack) {
        cacheWarning = '数据已恢复，但图片缓存没有重建完成，下次打开应用会再试。';
        onCacheFailure?.call(error, stack);
      }
      await onDataChanged?.call();
      return (commit: commit, cacheWarning: cacheWarning);
    });
  }

  Future<RevisionRef> name(
    int commitId, {
    required String label,
    String? note,
  }) {
    return db.gate.exclusive(
      () => engine.nameCommit(raw(), commitId, name: label, note: note),
    );
  }

  Future<void> deleteName(String label) {
    return db.gate.exclusive(() => engine.deleteName(raw(), label));
  }

  Future<RevisionUndoResult> undoCommit(int commitId) {
    return db.gate.exclusive(() async {
      final result = await undo.undo(raw(), commitId);
      if (result.applied) {
        await cache.rebuild(raw(), assets);
        await onUndoApplied?.call();
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
      return result;
    });
  }

  Future<void> clearHistory() {
    return db.gate.exclusive(() async {
      await engine.clearHistory(raw());
      await _stripDeadReceipts();
    });
  }

  Future<void> _stripDeadReceipts() async {
    await db.command(
      (txn) => engine.stripDeadReceipts(txn),
      label: clearDeadReceiptsAction,
    );
  }

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

  /// 当前数据里引用到的附件哈希，导出与回收都用这一份。
  Future<Set<String>> currentAssetHashes() async {
    final projection = await engine.readProjection(db.raw);
    return AssetStore.hashesInProjection(projection);
  }
}
