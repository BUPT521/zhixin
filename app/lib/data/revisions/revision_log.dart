part of 'revision_engine.dart';

/// 提交与查询：命令的开始与收尾、提交编号的预留、提交行的写入，以及历史页与
/// 回执读取的提交、变更查询。
///
/// 拥有者：泳道 A（ADR-0039 第 3.3 节）。

/// 一条待写入的提交。
///
/// 普通写入、撤销、恢复与远端应用都从这里写提交行，不再各自拼一份 INSERT；
/// 撤销提交的回指字段随 [CommitDraft] 一次写入，不再事后补 UPDATE（R10）。
class CommitDraft {
  const CommitDraft({
    required this.id,
    required this.parentId,
    required this.generation,
    required this.actor,
    required this.action,
    required this.kind,
    required this.changes,
    this.requestId,
    this.restoredCommitId,
    this.revertedCommitId,
    this.conflicts = const [],
  });

  final int id;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final RevisionKind kind;
  final List<RevisionChange> changes;
  final String? requestId;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final List<RevisionConflict> conflicts;
}

/// 把合并好的净变化补上提交编号；合并时编号还没定下来，先写 0。
List<RevisionChange> _withCommitId(
  List<RevisionChange> changes,
  int commitId,
) => [
  for (final change in changes)
    RevisionChange(
      commitId: commitId,
      seq: change.seq,
      table: change.table,
      rowKey: change.rowKey,
      op: change.op,
      before: change.before,
      after: change.after,
    ),
];

mixin RevisionLogMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  Future<int> headId(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_ref',
      columns: ['commit_id'],
      where: 'name = ?',
      whereArgs: [RevisionRef.headName],
    );
    if (rows.isEmpty) throw StateError('数据版本缺少 HEAD');
    return rows.first['commit_id']! as int;
  }

  /// 当前数据代次：`HEAD` 所在提交的 `generation`。
  ///
  /// 普通写入沿用父提交的代次，整版恢复、导入与清理历史各加一，因此它只在
  /// 整份数据被替换时变化，并且随库保存、重启之后仍然一致。语义索引用它判断
  /// 是否整份重建，不能用 `HEAD` 代替：`HEAD` 每次写入都会变。
  Future<int> currentGeneration(RawExecutor executor) async {
    final head = await self.commitById(executor, await self.headId(executor));
    return head?.generation ?? 0;
  }

  Future<RevisionCommit?> commitById(RawExecutor executor, int id) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCommit.fromRow(rows.first);
  }

  Future<RevisionCommit?> commitByRequest(
    RawExecutor executor,
    String requestId,
  ) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCommit.fromRow(rows.first);
  }

  Future<List<RevisionCommit>> commits(
    RawExecutor executor, {
    int? limit,
  }) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  /// 编号大于 [after] 的提交，按编号升序；推送远端提交时从这里取。
  Future<List<RevisionCommit>> commitsAfter(
    RawExecutor executor,
    int after, {
    int? limit,
  }) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'id > ?',
      whereArgs: [after],
      orderBy: 'id',
      limit: limit,
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  Future<List<RevisionChange>> changesFor(
    RawExecutor executor,
    int commitId,
  ) async {
    final rows = await selectRows(
      executor,
      'revision_change',
      where: 'commit_id = ?',
      whereArgs: [commitId],
      orderBy: 'seq',
    );
    return rows.map(RevisionChange.fromRow).toList(growable: false);
  }

  /// 编号大于 [after] 的行级变化，按提交与序号升序；[tables] 给出时只取这些表。
  ///
  /// 检索索引的增量刷新用这个方法：已处理提交之后的改动就是需要重新解析来源键
  /// 的行，按提交编号与序号排好序之后，删除与重建的先后不影响最终按来源键去重
  /// 的结果。只筛选索引关心的表，其他业务表的提交不会让索引做多余的工作。
  Future<List<RevisionChange>> changesAfter(
    RawExecutor executor,
    int after, {
    Set<String>? tables,
    int? limit,
  }) async {
    final filter = tables?.toList(growable: false);
    if (filter != null && filter.isEmpty) return const [];
    final where = StringBuffer('commit_id > ?');
    final whereArgs = <Object?>[after];
    if (filter != null) {
      where.write(
        ' AND table_name IN (${List.filled(filter.length, '?').join(', ')})',
      );
      whereArgs.addAll(filter);
    }
    final rows = await selectRows(
      executor,
      'revision_change',
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'commit_id, seq',
      limit: limit,
    );
    return rows.map(RevisionChange.fromRow).toList(growable: false);
  }

  /// 某一行在提交历史里的修改，按提交编号倒序；只取当前代次。
  ///
  /// 材料详情用它列出每一页的更正记录。撤销提交本身不进入列表，已经撤销的
  /// 更正仍在结果里，界面按 `activeCommits` 标出状态。
  Future<List<RevisionCommit>> rowHistory(
    RawExecutor executor, {
    required String table,
    required String rowKey,
    int limit = 20,
  }) async {
    final head = await self.commitById(executor, await self.headId(executor));
    if (head == null) return const [];
    final rows = await executor.rawQuery(
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

  /// 当前命令已经预留的提交编号；还没有预留时为空。
  Future<int?> activeCommit(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_context',
      columns: ['active_commit'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['active_commit'] as int?;
  }

  /// 仍然可以按提交撤销的编号：存在、属于当前代次、没有被撤销过。
  ///
  /// 整版恢复或导入会推进代次，更早的提交不再进入可撤销范围；界面的回执
  /// 也用这个方法判断是否还显示撤销按钮。
  Future<Set<int>> activeCommits(
    RawExecutor executor,
    Iterable<int> ids,
  ) async {
    final values = ids.toSet().toList(growable: false);
    if (values.isEmpty) return const {};
    final head = await self.commitById(executor, await self.headId(executor));
    if (head == null) return const {};
    final placeholders = List.filled(values.length, '?').join(', ');
    final rows = await executor.rawQuery(
      '''
      SELECT c.id FROM revision_commit c
      WHERE c.id IN ($placeholders) AND c.generation = ?
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ''',
      [...values, head.generation],
    );
    return {for (final row in rows) row['id']! as int};
  }

  /// 当前代次里还没被撤销的提交，按编号倒序；撤销提交本身不在其中。
  ///
  /// 安排页的“AI 的改动”从这里挑出要展示的写入，数据版本页读的是完整历史。
  Future<List<RevisionCommit>> undoableCommits(RawExecutor executor) async {
    final head = await self.commitById(executor, await self.headId(executor));
    if (head == null) return const [];
    final rows = await executor.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      WHERE c.id != 0 AND c.generation = ? AND c.reverted_commit_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ORDER BY c.id DESC
      ''',
      [head.generation],
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  /// 指定动作、且改动落在指定表里的可撤销提交，按编号倒序。
  ///
  /// 与 [undoableCommits] 的区别是筛选放在同一条查询里：安排页只展示真正写入
  /// 记忆或学习事项的提交，原先要先读全部可撤销提交，再为每条读一次变更明细。
  Future<List<RevisionCommit>> receiptCommits(
    RawExecutor executor, {
    required Set<String> actions,
    required Set<String> tables,
  }) async {
    if (actions.isEmpty || tables.isEmpty) return const [];
    final head = await self.commitById(executor, await self.headId(executor));
    if (head == null) return const [];
    final actionSlots = List.filled(actions.length, '?').join(', ');
    final tableSlots = List.filled(tables.length, '?').join(', ');
    final rows = await executor.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      WHERE c.id != 0 AND c.generation = ? AND c.reverted_commit_id IS NULL
        AND c.action IN ($actionSlots)
        AND EXISTS (
          SELECT 1 FROM revision_change ch
          WHERE ch.commit_id = c.id AND ch.table_name IN ($tableSlots)
        )
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ORDER BY c.id DESC
      ''',
      [head.generation, ...actions, ...tables],
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  /// 开始一次命令：标记采集并清掉暂停标记。
  ///
  /// 这里不分配提交编号：命令里显式要回执时由 [reserveCommitId] 预留，有净
  /// 变化时由 [finishCommand] 就地分配，没有净变化又不预留时序号不动（R1）。
  Future<void> beginCommand(RawExecutor txn, {String? requestId}) async {
    if (requestId != null) {
      final existing = await self.commitByRequest(txn, requestId);
      if (existing != null) throw RevisionDuplicateRequest(existing);
    }
    await updateRow(txn, 'revision_context', {
      'capturing': 1,
      'suppress': 0,
    }, where: 'id = 1');
  }

  /// 为本次命令预留一个提交编号并写进上下文；已经预留过时返回原编号。
  ///
  /// 编号只增不减：预留之后即使没有形成提交，序号也不回退（R1）。
  Future<int> reserveCommitId(RawExecutor txn) async {
    final current = await self.activeCommit(txn);
    if (current != null) return current;
    final rows = await selectRows(txn, 'revision_sequence', limit: 1);
    if (rows.isEmpty) throw StateError('数据版本缺少提交编号');
    final id = rows.first['next_commit']! as int;
    await updateRow(txn, 'revision_sequence', {
      'next_commit': id + 1,
    }, where: 'id = 1');
    await updateRow(txn, 'revision_context', {
      'active_commit': id,
    }, where: 'id = 1');
    return id;
  }

  Future<void> _clearContext(RawExecutor txn) async {
    await updateRow(txn, 'revision_context', {
      'active_commit': null,
      'capturing': 0,
      'suppress': 0,
    }, where: 'id = 1');
  }

  /// 结束一次命令：合并暂存变化，有净变化才追加提交并推进 `HEAD`。
  ///
  /// 提交编号在确定有净变化之后才分配：命令里预留过就沿用预留的编号，没有
  /// 预留就地分配；没有净变化且没有预留时序号不动，预留过也不回退。
  ///
  /// [changedTables] 是输出参数：形成提交时填入这次改到的表与版本元数据表，
  /// 由调用方在事务提交之后发布给订阅中的页面（ADR-0014 第 2 条）；没有净
  /// 变化时不填，回滚时调用方也不会发布。
  Future<RevisionCommit?> finishCommand(
    RawExecutor txn, {
    required String action,
    String actor = 'user',
    String? requestId,
    Set<String>? changedTables,
    RevisionKind kind = RevisionKind.write,
    int? revertedCommitId,
    List<RevisionConflict> conflicts = const [],
  }) async {
    final reserved = await self.activeCommit(txn);
    final drafts = await self._collect(txn);
    await self._clearStage(txn);

    if (drafts.isEmpty) {
      // 没有业务净变化的写入不形成提交，也不留下可撤销的回执；已经预留的
      // 编号留在序号里，后续提交不会复用（R1）。
      await self._clearContext(txn);
      return null;
    }

    final commitId = reserved ?? await self.reserveCommitId(txn);
    final net = _withCommitId(drafts, commitId);
    final head = await self.headId(txn);
    final parent = await self.commitById(txn, head);
    final commit = await self._appendCommit(
      txn,
      CommitDraft(
        id: commitId,
        parentId: head,
        generation: parent?.generation ?? 0,
        actor: actor,
        action: action,
        kind: kind,
        requestId: requestId,
        revertedCommitId: revertedCommitId,
        changes: net,
        conflicts: conflicts,
      ),
    );
    // 这次提交改到的表与版本元数据表；发布由调用方在提交之后做。
    changedTables?.addAll({
      for (final change in net) change.table,
      ...revisionHistoryTables,
    });
    await self._clearContext(txn);
    await self.checkpointAfterCommit(txn, commit);
    return commit;
  }

  /// 写入一条提交、它的变更明细与冲突记录，并推进 `HEAD`。
  Future<RevisionCommit> _appendCommit(
    RawExecutor txn,
    CommitDraft draft,
  ) async {
    final now = formatDateTime(self.clock());
    final byteLength = self._changesByteLength(draft.changes);
    await insertRow(txn, 'revision_commit', {
      'id': draft.id,
      'parent_id': draft.parentId,
      'generation': draft.generation,
      'actor': draft.actor,
      'action': draft.action,
      'kind': draft.kind.value,
      'request_id': draft.requestId,
      'restored_commit_id': draft.restoredCommitId,
      'reverted_commit_id': draft.revertedCommitId,
      'change_count': draft.changes.length,
      'byte_length': byteLength,
      'conflict_count': draft.conflicts.length,
      'created_at': now,
    });
    for (final change in draft.changes) {
      await insertRow(txn, 'revision_change', change.toRow());
    }
    await self.recordAssetRefs(
      txn,
      ownerKind: 'change',
      ownerId: draft.id,
      hashes: AssetStore.hashesInChanges(draft.changes),
    );
    for (final conflict in draft.conflicts) {
      await insertRow(txn, 'revision_conflict', {
        ...conflict.toRow(),
        'commit_id': draft.id,
      });
    }
    await updateRow(
      txn,
      'revision_ref',
      {'commit_id': draft.id, 'updated_at': now},
      where: 'name = ?',
      whereArgs: [RevisionRef.headName],
    );
    return RevisionCommit(
      id: draft.id,
      parentId: draft.parentId,
      generation: draft.generation,
      actor: draft.actor,
      action: draft.action,
      kind: draft.kind,
      requestId: draft.requestId,
      restoredCommitId: draft.restoredCommitId,
      revertedCommitId: draft.revertedCommitId,
      changeCount: draft.changes.length,
      byteLength: byteLength,
      conflictCount: draft.conflicts.length,
      createdAt: self.clock(),
    );
  }

  /// 一次提交里变更明细的字节数：主键、变化前后的行各算一次 UTF-8 长度。
  int _changesByteLength(List<RevisionChange> changes) {
    var total = 0;
    for (final change in changes) {
      total += utf8.encode(change.rowKey).length;
      final before = change.before;
      if (before != null) total += utf8.encode(encodeTypedRow(before)).length;
      final after = change.after;
      if (after != null) total += utf8.encode(encodeTypedRow(after)).length;
    }
    return total;
  }
}
