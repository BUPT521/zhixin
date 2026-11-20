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
/// 一致性摘要与哈希链的四列（`state_digest`、`hash`、`origin_device`、
/// `authored_at`）也在这里定下：采集路径给出 [digestDelta]，整版恢复与导入直接
/// 给出 [stateDigest]，两条路径都落到同一次写入里（方案 3.5、3.10、3.12）。
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
    this.requestId,
    this.restoredCommitId,
    this.revertedCommitId,
    this.conflicts = const [],
    this.digestDelta,
    this.stateDigest,
    this.parentHash,
    this.originDevice,
    this.authoredAt,
  });

  final int id;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final RevisionKind kind;
  final List<RevisionChange> changes;

  /// 提交身份；为空时由 [_appendCommit] 生成 UUIDv7，远端提交沿用远端的 uid。
  final String? uid;

  /// 同一次用户动作的重试编号；只用于“旧提交仍是 HEAD 且在最近两分钟内创建”
  /// 的重试去重。
  final String? requestId;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final List<RevisionConflict> conflicts;

  /// 采集路径算出的一致性摘要增量；与父提交的摘要相加得到这条提交的摘要。
  final BigInt? digestDelta;

  /// 直接给定这条提交之后的状态摘要；整版恢复与导入用它，因为目标投影当场
  /// 可用，不必再经过暂存表。
  final String? stateDigest;

  /// 直接给定父提交的哈希；为空时读父提交或取哈希链初值。
  final String? parentHash;

  /// 远端提交由服务端带来的设备标识；本机提交为空。
  final String? originDevice;

  /// 远端提交的作者创建时间；本机提交为空，写入时取 `created_at`。
  final DateTime? authoredAt;
}

/// 本机重试去重的时效：同编号的旧提交在这段时间内创建、且仍是 `HEAD` 时，才按
/// 同一次动作的重试处理；超过之后或者中间已有别的提交，同一个编号按新的用户
/// 动作执行（ADR-0040）。
const Duration retryRequestWindow = Duration(minutes: 2);

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

  /// 按提交身份取提交；远端提交是否已经应用按它判断。
  Future<RevisionCommit?> commitByUid(RawExecutor executor, String uid) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCommit.fromRow(rows.first);
  }

  /// 同一次用户动作的重试：是则返回原提交，不是则先把旧提交的编号释放掉。
  ///
  /// 两条同时成立才按重试处理：旧提交在 [retryRequestWindow] 之内创建，且它仍是
  /// 当前 `HEAD`。旧提交还在 `HEAD` 说明这次调用紧接在它之后，是界面双击或网络
  /// 回调造成的重试；之后已经有了别的提交（暂停、恢复之后再次暂停，撤销之后
  /// 重做同一动作），即便编号相同也是用户重新做的一次动作，必须照常执行，
  /// 否则方案 3.1 的验收无法达成（ADR-0040）。
  ///
  /// 时间按本机时钟算，创建时间只精确到秒，所以两者相差按绝对值比较。旧提交的
  /// `request_id` 置空之后，唯一索引与回执查询都按非空值判断，它不再是重试目标；
  /// 编号由这一次的新提交继续使用。
  Future<RevisionCommit?> retryCommit(
    RawExecutor executor,
    String requestId,
  ) async {
    final existing = await self.commitByRequest(executor, requestId);
    if (existing == null) return null;
    final headId = await self.headId(executor);
    final createdAt = existing.createdAt;
    final elapsed = createdAt == null
        ? null
        : self.clock().difference(createdAt).abs();
    if (existing.id == headId &&
        elapsed != null &&
        elapsed <= retryRequestWindow) {
      return existing;
    }
    await updateRow(
      executor,
      'revision_commit',
      {'request_id': null},
      where: 'id = ?',
      whereArgs: [existing.id],
    );
    return null;
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

  /// 开始一次命令：标记采集并清掉暂停标记。
  ///
  /// 这里不分配提交编号：命令里显式要回执时由 [reserveCommitId] 预留，有净
  /// 变化时由 [finishCommand] 就地分配，没有净变化又不预留时序号不动（R1）。
  ///
  /// [requestId] 只用于同一次动作的重试去重：查到仍在时效内的原提交时抛出
  /// [RevisionDuplicateRequest]，调用方据此返回原结果；查到过期的旧提交时先
  /// 释放它的编号，再照常执行（[retryCommit]）。
  Future<void> beginCommand(RawExecutor txn, {String? requestId}) async {
    if (requestId != null) {
      final existing = await self.retryCommit(txn, requestId);
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
  /// [originDevice] 与 [authoredAt] 只在应用远端提交时给：服务端带来的设备标识
  /// 与作者创建时间原样记进提交行；本机提交两者都为空，`authored_at` 写成本次
  /// 提交的创建时间（方案 3.12）。
  ///
  /// [changedTables] 是输出参数：形成提交时填入这次改到的表与版本元数据表，
  /// 由调用方在事务提交之后发布给订阅中的页面（ADR-0014 第 2 条）；没有净
  /// 变化时不填，回滚时调用方也不会发布。
  Future<RevisionCommit?> finishCommand(
    RawExecutor txn, {
    required String action,
    String actor = 'user',
    String? requestId,
    String? uid,
    Set<String>? changedTables,
    RevisionKind kind = RevisionKind.write,
    int? revertedCommitId,
    List<RevisionConflict> conflicts = const [],
    String? originDevice,
    DateTime? authoredAt,
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
        requestId: requestId,
        revertedCommitId: revertedCommitId,
        changes: net,
        conflicts: conflicts,
        digestDelta: captured.digestDelta,
        parentHash: parent?.hash,
        originDevice: originDevice,
        authoredAt: authoredAt,
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
  ///
  /// 提交身份在落库之前定下来：本机提交生成 UUIDv7，远端提交沿用远端的 uid，
  /// 两者都写进 `revision_commit.uid`（ADR-0040）。同一处一次算好四列：
  /// `parent_hash` 接上父提交的哈希，`state_digest` 由父提交摘要加上这次命令的
  /// 增量（整版恢复与导入直接给目标投影的摘要），`hash` 按提交内容重算，
  /// `origin_device` 与 `authored_at` 按本机或远端规则写入（方案 3.5、3.10、
  /// 3.12）。
  Future<RevisionCommit> _appendCommit(
    RawExecutor txn,
    CommitDraft draft,
  ) async {
    final createdAt = self.clock();
    final now = formatDateTime(createdAt);
    final uid = draft.uid ?? newUuidV7();
    final byteLength = self._changesByteLength(draft.changes);
    final parent = draft.parentId == null
        ? null
        : await self.commitById(txn, draft.parentId!);
    final parentHash = draft.parentHash ?? parent?.hash ?? revisionChainGenesis;
    final parentDigest = BigInt.parse(
      parent?.stateDigest ?? revisionEmptyStateDigest,
      radix: 16,
    );
    final stateDigest =
        draft.stateDigest ??
        revisionStateDigestHex(
          (parentDigest + (draft.digestDelta ?? BigInt.zero)) %
              revisionDigestModulus,
        );
    final hash = revisionCommitHash(
      parentHash: parentHash,
      uid: uid,
      kind: draft.kind,
      changes: draft.changes,
    );
    final authoredAt = draft.authoredAt ?? createdAt;
    await insertRow(txn, 'revision_commit', {
      'id': draft.id,
      'uid': uid,
      'parent_id': draft.parentId,
      'parent_hash': parentHash,
      'generation': draft.generation,
      'state_digest': stateDigest,
      'hash': hash,
      'actor': draft.actor,
      'action': draft.action,
      'kind': draft.kind.value,
      'request_id': draft.requestId,
      'restored_commit_id': draft.restoredCommitId,
      'reverted_commit_id': draft.revertedCommitId,
      'change_count': draft.changes.length,
      'byte_length': byteLength,
      'conflict_count': draft.conflicts.length,
      'origin_device': draft.originDevice,
      'authored_at': formatDateTime(authoredAt),
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
      uid: uid,
      parentId: draft.parentId,
      parentHash: parentHash,
      generation: draft.generation,
      stateDigest: stateDigest,
      hash: hash,
      actor: draft.actor,
      action: draft.action,
      kind: draft.kind,
      requestId: draft.requestId,
      restoredCommitId: draft.restoredCommitId,
      revertedCommitId: draft.revertedCommitId,
      changeCount: draft.changes.length,
      byteLength: byteLength,
      conflictCount: draft.conflicts.length,
      originDevice: draft.originDevice,
      authoredAt: authoredAt,
      createdAt: createdAt,
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

  /// 哈希链的锚点：最早保留提交记录的父哈希；空库返回哈希链初值。
  ///
  /// 裁剪之后最早的保留提交指向的父提交已经不在库里，这个哈希就是还能校验的
  /// 边界；命名版本让更早的提交留在库里时，锚点是编号最小的那一行记录的父哈希
  /// （方案 3.10）。
  Future<String> chainAnchor(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      columns: ['parent_hash'],
      orderBy: 'id',
      limit: 1,
    );
    if (rows.isEmpty) return revisionChainGenesis;
    return rows.first['parent_hash']! as String;
  }

  /// 当前数据的摘要，按当前业务表整库重算（方案 3.5）。
  ///
  /// 同步摘要交换与完整性检查都用它；与 `HEAD` 记录的 `state_digest` 比对，
  /// 能发现绕过命令事务的写入。
  Future<String> currentStateDigest(RawExecutor executor) async =>
      revisionStateDigest(await self.readProjection(executor));

  /// 数据完整性检查：核对保留历史的哈希链，再把整库重算的摘要与 `HEAD` 比对。
  ///
  /// 逐条重算 `sha256(parent_hash, uid, kind, 规范化变更明细)`，父提交还在库里
  /// 时顺带核对父哈希；最后按当前表重算摘要，与 `HEAD` 记录的 `state_digest`
  /// 比较，因此改动业务行、改动变更明细、改动提交身份都会进 [problems]。裁剪
  /// 之后的锚点无法回溯，最早保留提交的父哈希只作起点，不参与核对。这个方法只
  /// 读不写，界面入口与导出前检查由后续任务接入（方案 3.10）。
  Future<RevisionIntegrityReport> verifyIntegrity(RawExecutor executor) async {
    final rows = await selectRows(executor, 'revision_commit', orderBy: 'id');
    if (rows.isEmpty) {
      return const RevisionIntegrityReport(
        commitId: 0,
        checkedCommits: 0,
        problems: ['提交历史为空'],
      );
    }
    final changesByCommit = <int, List<RevisionChange>>{};
    for (final row in await selectRows(
      executor,
      'revision_change',
      orderBy: 'commit_id, seq',
    )) {
      final change = RevisionChange.fromRow(row);
      changesByCommit.putIfAbsent(change.commitId, () => []).add(change);
    }
    final commits = <int, RevisionCommit>{};
    for (final row in rows) {
      final commit = RevisionCommit.fromRow(row);
      commits[commit.id] = commit;
    }
    final problems = <String>[];
    for (final commit in commits.values) {
      final expected = revisionCommitHash(
        parentHash: commit.parentHash,
        uid: commit.uid,
        kind: commit.kind,
        changes: changesByCommit[commit.id] ?? const [],
      );
      if (expected != commit.hash) {
        problems.add('提交 ${commit.id} 的哈希与变更明细不一致');
      }
      final parent = commit.parentId == null ? null : commits[commit.parentId];
      if (parent != null && parent.hash != commit.parentHash) {
        problems.add('提交 ${commit.id} 记录的父哈希与提交 ${parent.id} 的哈希不一致');
      }
    }
    final head = commits.values.last;
    final digest = await self.currentStateDigest(executor);
    if (head.stateDigest != digest) {
      problems.add('当前数据的摘要与提交 ${head.id} 的记录不一致');
    }
    return RevisionIntegrityReport(
      commitId: head.id,
      checkedCommits: commits.length,
      problems: problems,
    );
  }
}
