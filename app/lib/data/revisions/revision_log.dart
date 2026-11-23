part of 'revision_engine.dart';

/// 提交与查询：命令的开始与收尾、提交编号的预留、提交行的写入，以及历史页与
/// 回执读取的提交、变更查询。
///
/// 拥有者：泳道 A（ADR-0039 第 3.3 节）。

/// 一条待写入的提交。
///
/// 普通写入、撤销、恢复与远端应用都从这里写提交行，不再各自拼一份 INSERT；
/// 撤销提交的回指字段随 [CommitDraft] 一次写入，不再事后补 UPDATE（R10）。
///
/// 一致性摘要在这里定下：采集路径给出各表增量 [tableDeltas]，整版恢复与导入
/// 直接给出 [stateDigest] 与 [tableDigests]，两条路径都落到同一次写入里
/// （方案 3.5、ADR-0054）。
class CommitDraft {
  const CommitDraft({
    required this.id,
    required this.parentId,
    required this.generation,
    required this.actor,
    required this.action,
    required this.kind,
    required this.changes,
    this.uid,
    this.restoredCommitId,
    this.revertedCommitId,
    this.conflicts = const [],
    this.tableDeltas,
    this.stateDigest,
    this.tableDigests,
    this.originDevice,
    this.authoredAt,
    this.serverSeq,
  });

  final int id;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final RevisionKind kind;
  final List<RevisionChange> changes;

  /// 提交身份；界面在动作开始时生成并一路传下来，为空时由 [_appendCommit] 生成
  /// 一个兜底值（ADR-0053 决定第 3 条）。
  final String? uid;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final List<RevisionConflict> conflicts;

  /// 采集路径算出的各表摘要增量；加到父提交的分表摘要上得到这条提交之后的值。
  final Map<String, BigInt>? tableDeltas;

  /// 直接给定这条提交之后的状态摘要；整版恢复与导入用它，因为目标投影当场
  /// 可用，不必再经过暂存表。
  final String? stateDigest;

  /// 直接给定各表摘要；与 [stateDigest] 一起给，各表之和必须等于它。
  final Map<String, String>? tableDigests;

  /// 远端提交由服务端带来的设备标识；本机提交为空。
  final String? originDevice;

  /// 远端提交的作者创建时间；本机提交为空，写入时取这条提交的落库时间。
  final DateTime? authoredAt;

  /// 远端提交对应的服务端序号；本机提交为空，推送成功之后补写。
  final int? serverSeq;
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

  /// 读单行版本状态的原始行；没有这一行时为空。
  Future<Map<String, Object?>?> _stateRow(RawExecutor executor) async {
    final rows = await selectRows(executor, 'revision_state', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// `HEAD` 指向的提交编号，单行直读、不联表（ADR-0054 决定第 4 条）。
  Future<int> headId(RawExecutor executor) async {
    final row = await _stateRow(executor);
    if (row == null) throw StateError('数据版本缺少单行状态');
    return row['head_commit_id'] as int? ?? 0;
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

  /// 读一条提交，并补上现数的变更条数与冲突条数。
  ///
  /// 这两列不存表，读取时从 `revision_change` 与 `revision_conflict` 现数
  /// （ADR-0054 与审查 S1）。
  Future<RevisionCommit?> commitById(RawExecutor executor, int id) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final counts = await _commitCounts(executor, [id]);
    return RevisionCommit.fromRow(_withCounts(rows.first, counts[id]!));
  }

  /// 一组提交的变更条数与冲突条数，一次查询现数；没有明细的提交记 0。
  Future<Map<int, ({int changes, int conflicts})>> _commitCounts(
    RawExecutor executor,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(', ');
    final result = <int, ({int changes, int conflicts})>{
      for (final id in ids) id: (changes: 0, conflicts: 0),
    };
    for (final row in await executor.rawQuery(
      'SELECT commit_id, COUNT(*) AS count FROM revision_change '
      'WHERE commit_id IN ($marks) GROUP BY commit_id',
      ids,
    )) {
      final id = row['commit_id']! as int;
      final current = result[id]!;
      result[id] = (
        changes: row['count']! as int,
        conflicts: current.conflicts,
      );
    }
    for (final row in await executor.rawQuery(
      'SELECT commit_id, COUNT(*) AS count FROM revision_conflict '
      'WHERE commit_id IN ($marks) GROUP BY commit_id',
      ids,
    )) {
      final id = row['commit_id']! as int;
      final current = result[id]!;
      result[id] = (changes: current.changes, conflicts: row['count']! as int);
    }
    return result;
  }

  /// 按提交身份取提交；远端提交是否已经应用、重试是否落到原提交都按它判断。
  Future<RevisionCommit?> commitByUid(RawExecutor executor, String uid) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final id = rows.first['id']! as int;
    final counts = await _commitCounts(executor, [id]);
    return RevisionCommit.fromRow(_withCounts(rows.first, counts[id]!));
  }

  /// 提交行补上现数的条数，键名与 [RevisionCommit.fromRow] 读取的一致。
  Map<String, Object?> _withCounts(
    Map<String, Object?> row,
    ({int changes, int conflicts}) counts,
  ) => {
    ...row,
    'change_count': counts.changes,
    'conflict_count': counts.conflicts,
  };

  /// 按 uid 取提交编号；本机已经没有这条提交时为空。
  Future<int?> commitIdByUid(RawExecutor executor, String uid) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      columns: ['id'],
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
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
    return self._commitsOf(executor, rows);
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
    return self._commitsOf(executor, rows);
  }

  /// 把提交行组装成模型，变更条数与冲突条数现数一次补齐。
  Future<List<RevisionCommit>> _commitsOf(
    RawExecutor executor,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    final counts = await _commitCounts(executor, [
      for (final row in rows) row['id']! as int,
    ]);
    return rows
        .map(
          (row) => RevisionCommit.fromRow(
            _withCounts(row, counts[row['id']! as int]!),
          ),
        )
        .toList(growable: false);
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
  /// 更正仍在结果里，界面按 `RevisionService.activeCommits` 标出状态。
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
    return self._commitsOf(executor, rows);
  }

  /// 当前命令已经预留的提交编号；还没有预留时为空。
  Future<int?> activeCommit(RawExecutor executor) async {
    final row = await _stateRow(executor);
    return row == null ? null : row['active_commit'] as int?;
  }

  /// 开始一次命令：标记采集并清掉暂停标记。
  ///
  /// 这里不分配提交编号：命令里显式要回执时由 [reserveCommitId] 预留，有净
  /// 变化时由 [finishCommand] 就地分配，没有净变化又不预留时序号不动（R1）。
  ///
  /// [uid] 是这个动作的提交身份：本机提交直接写进 `revision_commit.uid`，
  /// 同一个 uid 查到已有提交时抛出 [RevisionDuplicateRequest]，调用方据此返回
  /// 原结果；不再有按参数派生的重试编号与两分钟窗口（ADR-0053 决定第 3 条）。
  Future<void> beginCommand(RawExecutor txn, {String? uid}) async {
    if (uid != null) {
      final existing = await self.commitByUid(txn, uid);
      if (existing != null) throw RevisionDuplicateRequest(existing);
    }
    await updateRow(txn, 'revision_state', {
      'capturing': 1,
      'suppress': 0,
    }, where: 'id = 1');
  }

  /// 为本次命令预留一个提交编号并写进状态行；已经预留过时返回原编号。
  ///
  /// 编号只增不减：预留之后即使没有形成提交，序号也不回退（R1）。
  Future<int> reserveCommitId(RawExecutor txn) async {
    final current = await self.activeCommit(txn);
    if (current != null) return current;
    final row = await _stateRow(txn);
    if (row == null) throw StateError('数据版本缺少单行状态');
    final id = row['next_commit']! as int;
    await updateRow(txn, 'revision_state', {
      'next_commit': id + 1,
      'active_commit': id,
    }, where: 'id = 1');
    return id;
  }

  Future<void> _clearContext(RawExecutor txn) async {
    await updateRow(txn, 'revision_state', {
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
  /// [originDevice] 与 [authoredAt] 只在应用远端提交时给：服务端带来的设备标识
  /// 与作者创建时间原样记进提交行；本机提交两者都为空（方案 3.12）。
  ///
  /// [changedTables] 是输出参数：形成提交时填入这次改到的表与版本元数据表，
  /// 由调用方在事务提交之后发布给订阅中的页面（ADR-0014 第 2 条）；没有净
  /// 变化时不填，回滚时调用方也不会发布。
  Future<RevisionCommit?> finishCommand(
    RawExecutor txn, {
    required String action,
    String actor = 'user',
    String? uid,
    Set<String>? changedTables,
    RevisionKind kind = RevisionKind.write,
    int? revertedCommitId,
    List<RevisionConflict> conflicts = const [],
    String? originDevice,
    DateTime? authoredAt,
    int? serverSeq,
  }) async {
    final reserved = await self.activeCommit(txn);
    final captured = await self._collect(txn);
    final drafts = captured.changes;
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
        uid: uid,
        parentId: head,
        generation: parent?.generation ?? 0,
        actor: actor,
        action: action,
        kind: kind,
        revertedCommitId: revertedCommitId,
        changes: net,
        conflicts: conflicts,
        tableDeltas: captured.tableDeltas,
        originDevice: originDevice,
        authoredAt: authoredAt,
        serverSeq: serverSeq,
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

  /// 写入一条提交、它的变更明细与冲突记录，并推进 `HEAD` 与分表摘要。
  ///
  /// 提交身份在落库之前定下来：本机提交沿用界面传下来的 uid，缺失时生成
  /// UUIDv7 兜底；远端提交沿用远端的 uid（ADR-0053）。摘要由父提交的分表值
  /// 加上这次命令的增量，整版恢复与导入直接给目标投影的分表值；`origin_device`
  /// 与 `authored_at` 按本机或远端规则写入（方案 3.5、3.12）。
  Future<RevisionCommit> _appendCommit(
    RawExecutor txn,
    CommitDraft draft,
  ) async {
    final createdAt = self.clock();
    final now = formatDateTime(createdAt);
    final uid = draft.uid ?? newUuidV7();
    final byteLength = self._changesByteLength(draft.changes);
    final state = await _stateRow(txn);
    final parentDigests = state == null
        ? revisionEmptyTableDigests()
        : _decodeTableDigests(state['table_digests_json'] as String?);
    final Map<String, String> tableDigests;
    final String stateDigest;
    if (draft.tableDigests != null) {
      tableDigests = {
        for (final name in versionedTableNames)
          name:
              draft.tableDigests![name] ?? revisionStateDigestHex(BigInt.zero),
      };
      stateDigest =
          draft.stateDigest ??
          revisionStateDigestHex(revisionTableDigestsSum(tableDigests));
      if (!revisionTableDigestsMatch(tableDigests, stateDigest)) {
        throw StateError('各表摘要之和与整库摘要不一致');
      }
    } else if (draft.stateDigest != null) {
      // 只给总值时把它记在首张业务表上，其余表写零：各表之和仍等于总值，总摘要
      // 的比对不受影响；按表比较在这条提交上退回整条应用（ADR-0054）。
      tableDigests = {
        for (final name in versionedTableNames)
          name: revisionStateDigestHex(BigInt.zero),
      };
      final first = versionedTableNames.isEmpty
          ? null
          : versionedTableNames.first;
      if (first != null) tableDigests[first] = draft.stateDigest!;
      stateDigest = draft.stateDigest!;
    } else {
      final deltas = draft.tableDeltas ?? const <String, BigInt>{};
      tableDigests = {
        for (final name in versionedTableNames)
          name: revisionStateDigestHex(
            (BigInt.parse(
                      parentDigests[name] ??
                          revisionStateDigestHex(BigInt.zero),
                      radix: 16,
                    ) +
                    (deltas[name] ?? BigInt.zero)) %
                revisionDigestModulus,
          ),
      };
      stateDigest = revisionStateDigestHex(
        revisionTableDigestsSum(tableDigests),
      );
    }
    final authoredAt = draft.authoredAt;
    await insertRow(txn, 'revision_commit', {
      'id': draft.id,
      'uid': uid,
      'parent_id': draft.parentId,
      'generation': draft.generation,
      'state_digest': stateDigest,
      'actor': draft.actor,
      'action': draft.action,
      'kind': draft.kind.value,
      'restored_commit_id': draft.restoredCommitId,
      'reverted_commit_id': draft.revertedCommitId,
      'byte_length': byteLength,
      'server_seq': draft.serverSeq,
      'origin_device': draft.originDevice,
      'authored_at': authoredAt == null ? null : formatDateTime(authoredAt),
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
    await updateRow(txn, 'revision_state', {
      'head_commit_id': draft.id,
      'table_digests_json': jsonEncode(tableDigests),
    }, where: 'id = 1');
    return RevisionCommit(
      id: draft.id,
      uid: uid,
      parentId: draft.parentId,
      generation: draft.generation,
      stateDigest: stateDigest,
      actor: draft.actor,
      action: draft.action,
      kind: draft.kind,
      restoredCommitId: draft.restoredCommitId,
      revertedCommitId: draft.revertedCommitId,
      changeCount: draft.changes.length,
      byteLength: byteLength,
      conflictCount: draft.conflicts.length,
      serverSeq: draft.serverSeq,
      originDevice: draft.originDevice,
      authoredAt: authoredAt,
      createdAt: createdAt,
    );
  }

  /// 读 `HEAD` 上各表摘要；缺的表按零补齐。
  Map<String, String> _decodeTableDigests(String? raw) {
    final fallback = revisionEmptyTableDigests();
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return fallback;
      return {
        for (final name in versionedTableNames)
          name:
              decoded[name] is String && validDigestHex(decoded[name] as String)
              ? decoded[name] as String
              : fallback[name]!,
      };
    } on FormatException {
      return fallback;
    }
  }

  /// `HEAD` 上各表的一致性摘要；分表比较与诊断读它。
  Future<Map<String, String>> tableDigests(RawExecutor executor) async {
    final row = await _stateRow(executor);
    return _decodeTableDigests(row?['table_digests_json'] as String?);
  }

  /// 在推送成功之后补写一组提交的服务端序号（ADR-0054 决定第 2 条）。
  ///
  /// 序号来自推送响应的逐条位置，与本机提交按 uid 对应；不在这里形成提交，
  /// 也不改摘要。写不进去只意味着显示不到这条信息，不影响同步正确性。
  Future<void> recordServerSeqs(
    RawExecutor executor,
    Map<String, int> seqsByUid,
  ) async {
    for (final entry in seqsByUid.entries) {
      await updateRow(
        executor,
        'revision_commit',
        {'server_seq': entry.value},
        where: 'uid = ?',
        whereArgs: [entry.key],
      );
    }
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

  /// 当前数据的摘要，按当前业务表整库重算（方案 3.5）。
  ///
  /// 同步摘要交换与完整性检查都用它；与 `HEAD` 记录的 `state_digest` 比对，
  /// 能发现绕过命令事务的写入。
  Future<String> currentStateDigest(RawExecutor executor) async =>
      revisionStateDigest(await self.readProjection(executor));

  /// 当前数据的分表摘要，按当前业务表整库重算。
  Future<Map<String, String>> currentTableDigests(RawExecutor executor) async =>
      revisionTableDigests(await self.readProjection(executor));

  /// 数据完整性检查：从最近的检查点把变更明细重放到 `HEAD`，核对两次摘要。
  ///
  /// 重放得到的摘要必须等于 `HEAD` 记录的 `state_digest`，也等于按当前业务表
  /// 重算的摘要；改动业务行、改动变更明细或改动提交身份都会让某个摘要对不上
  /// （ADR-0054 与审查 S1）。这个方法只读不写，诊断入口与导出前检查接在这里。
  Future<RevisionIntegrityReport> verifyIntegrity(RawExecutor executor) async {
    final headId = await self.headId(executor);
    final head = await self.commitById(executor, headId);
    if (head == null) {
      return const RevisionIntegrityReport(
        commitId: 0,
        checkedCommits: 0,
        problems: ['提交历史为空'],
      );
    }
    final problems = <String>[];
    Projection? replay;
    try {
      replay = await self.projectionAt(executor, headId);
    } on RevisionCorruption catch (error) {
      problems.add(error.message);
    }
    if (replay != null) {
      final replayed = revisionStateDigest(replay);
      if (replayed != head.stateDigest) {
        problems.add('重放结果的摘要与提交 $headId 的记录不一致');
      }
    }
    final current = await self.readProjection(executor);
    final digest = revisionStateDigest(current);
    if (digest != head.stateDigest) {
      problems.add('当前数据的摘要与提交 $headId 的记录不一致');
    } else {
      final expected = await tableDigests(executor);
      final actual = revisionTableDigests(current);
      for (final name in versionedTableNames) {
        if (expected[name] != actual[name]) problems.add('$name 的摘要与记录不一致');
      }
    }
    final rows = await executor.rawQuery(
      'SELECT COUNT(*) AS count FROM revision_commit',
    );
    final total = rows.isEmpty ? 0 : (rows.first['count'] as int? ?? 0);
    return RevisionIntegrityReport(
      commitId: headId,
      checkedCommits: total,
      problems: problems,
    );
  }
}

/// 64 位小写十六进制的摘要格式。
bool validDigestHex(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
