part of 'revision_engine.dart';

/// 投影与检查点：读取当前表、从检查点重建、比较、整版恢复与导入，以及检查点
/// 的写入、编码与校验。
///
/// 拥有者：泳道 C（ADR-0039 第 3.3 节）。

/// 不能只按保留的变更明细合并出 `(from, to]` 的净变化。
///
/// 起点之前的提交已经被裁掉、中间有清理历史留下的基线提交，或者某条提交的
/// `change_count` 与实际的变更明细条数对不上时抛出。[RevisionProjectionMixin
/// .compare] 捕获它之后退回两次重建，因此这种情况不按数据损坏处理
/// （ADR-0039 第 2 条）。
class _FoldUnavailable implements Exception {
  const _FoldUnavailable(this.reason);

  final String reason;

  @override
  String toString() => '无法按变更明细合并：$reason';
}

/// 检查点投影的原文：`json` 直接解 UTF-8，`json+gzip` 先解压。
String decodeCheckpointPayload(RevisionCheckpoint checkpoint) {
  switch (checkpoint.encoding) {
    case 'json':
      return utf8.decode(checkpoint.payload);
    case 'json+gzip':
      return utf8.decode(gzip.decode(checkpoint.payload));
    default:
      throw FormatException('未知的检查点编码 ${checkpoint.encoding}');
  }
}

String encodeProjection(Projection projection) => jsonEncode({
  for (final table in projection.entries)
    table.key: {
      for (final row in table.value.entries) row.key: typedRowToJson(row.value),
    },
});

Projection decodeProjection(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('检查点投影不是对象');
  final projection = <String, Map<String, TypedRow>>{};
  for (final table in decoded.entries) {
    final rows = table.value;
    if (rows is! Map) continue;
    final tableRows = <String, TypedRow>{};
    for (final row in rows.entries) {
      tableRows[row.key as String] = decodeTypedRow(jsonEncode(row.value));
    }
    projection[table.key as String] = tableRows;
  }
  return projection;
}

/// 两份投影的差异：新增与删除给出整行，修改只给出真正发生净变化的列。
///
/// 比较按“表名＋主键”进行，表按 [versionedTableNames] 的依赖顺序、行按主键
/// 字符串排序，结果是唯一的投影比较实现：比较结果、恢复后的逐行核对与整版
/// 恢复的变更明细都从它派生（ADR-0039 第 4 节泳道 C）。[RevisionChange] 的
/// `commitId` 与 `seq` 由调用方按用途补上。
List<RevisionChange> diffProjections(Projection before, Projection after) {
  final changes = <RevisionChange>[];
  var seq = 1;
  for (final table in versionedTableNames) {
    final left = before[table] ?? const <String, TypedRow>{};
    final right = after[table] ?? const <String, TypedRow>{};
    final keys = <String>{...left.keys, ...right.keys}.toList()
      ..sort((a, b) => a.compareTo(b));
    for (final key in keys) {
      final oldRow = left[key];
      final newRow = right[key];
      if (oldRow == null) {
        changes.add(
          RevisionChange(
            commitId: 0,
            seq: seq++,
            table: table,
            rowKey: key,
            op: ChangeOp.insert,
            after: newRow,
          ),
        );
        continue;
      }
      if (newRow == null) {
        changes.add(
          RevisionChange(
            commitId: 0,
            seq: seq++,
            table: table,
            rowKey: key,
            op: ChangeOp.delete,
            before: oldRow,
          ),
        );
        continue;
      }
      final changed = changedColumns(oldRow, newRow);
      if (changed.isEmpty) continue;
      changes.add(
        RevisionChange(
          commitId: 0,
          seq: seq++,
          table: table,
          rowKey: key,
          op: ChangeOp.update,
          before: projectColumns(oldRow, changed),
          after: projectColumns(newRow, changed),
        ),
      );
    }
  }
  return changes;
}

/// 两份投影是否逐行逐列相同。
///
/// 裁剪前的基线校验与恢复后的核对都按“差异为空”判断，不再各自实现一遍比较。
bool projectionsEqual(Projection left, Projection right) =>
    diffProjections(left, right).isEmpty;

mixin RevisionProjectionMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 空闲检查点是否正在进行；同一时刻只开一个维护事务，避免重复生成。
  bool _idleCheckpointRunning = false;

  Future<List<RevisionCheckpoint>> checkpoints(
    RawExecutor executor, {
    int? limit,
  }) async {
    final rows = await selectRows(
      executor,
      'revision_checkpoint',
      orderBy: 'commit_id DESC, id DESC',
      limit: limit,
    );
    return rows.map(RevisionCheckpoint.fromRow).toList(growable: false);
  }

  /// 读取当前全部业务表；投影按表名与主键字符串索引。
  Future<Projection> readProjection(RawExecutor executor) async {
    final schema = await self.tables(executor);
    final projection = <String, Map<String, TypedRow>>{};
    for (final table in schema.values) {
      final rows = await selectRows(executor, table.name);
      final tableRows = <String, TypedRow>{};
      for (final row in rows) {
        final key = '${row[table.primaryKey]}';
        tableRows[key] = typedRow(row);
      }
      projection[table.name] = tableRows;
    }
    return projection;
  }

  Future<Projection> projectionAt(RawExecutor executor, int target) {
    return self._rebuild(executor, target);
  }

  Future<Projection> _rebuild(RawExecutor executor, int target) async {
    final targetCommit = await self.commitById(executor, target);
    if (targetCommit == null) throw RevisionCorruption('提交 $target 不存在');
    final checkpoint = await self._latestCheckpoint(executor, target);
    final String projectionJson;
    try {
      projectionJson = decodeCheckpointPayload(checkpoint);
    } catch (error) {
      throw RevisionCorruption('检查点 ${checkpoint.id} 解码失败：$error');
    }
    final expected = self._checksum(projectionJson, checkpoint.assetHashes);
    if (expected != checkpoint.checksum) {
      throw RevisionCorruption('检查点 ${checkpoint.id} 校验值不一致');
    }
    final Projection projection;
    try {
      projection = decodeProjection(projectionJson);
    } catch (error) {
      throw RevisionCorruption('检查点 ${checkpoint.id} 投影格式不正确：$error');
    }
    final rows = await selectRows(
      executor,
      'revision_change',
      where: 'commit_id > ? AND commit_id <= ?',
      whereArgs: [checkpoint.commitId, target],
      orderBy: 'commit_id, seq',
    );
    for (final row in rows) {
      self._applyChange(projection, RevisionChange.fromRow(row));
    }
    return projection;
  }

  Future<RevisionCheckpoint> _latestCheckpoint(
    RawExecutor executor,
    int target,
  ) async {
    final rows = await selectRows(
      executor,
      'revision_checkpoint',
      where: 'commit_id <= ?',
      whereArgs: [target],
      orderBy: 'commit_id DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      throw RevisionCorruption('提交 $target 之前没有可用检查点');
    }
    return RevisionCheckpoint.fromRow(rows.first);
  }

  void _applyChange(Projection projection, RevisionChange change) {
    final table = projection.putIfAbsent(change.table, () => {});
    final current = table[change.rowKey];
    switch (change.op) {
      case ChangeOp.insert:
        if (current != null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期新增但已经存在',
          );
        }
        table[change.rowKey] = Map.of(change.after!);
        return;
      case ChangeOp.delete:
        if (current == null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期删除但已经不存在',
          );
        }
        self._verifyExpected(current, change.before!, change);
        table.remove(change.rowKey);
        return;
      case ChangeOp.update:
        if (current == null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期更新但已经不存在',
          );
        }
        self._verifyExpected(current, change.before!, change);
        final next = Map<String, RevisionValue>.of(current);
        for (final entry in change.after!.entries) {
          next[entry.key] = entry.value;
        }
        table[change.rowKey] = next;
        return;
    }
  }

  void _verifyExpected(
    TypedRow current,
    TypedRow before,
    RevisionChange change,
  ) {
    for (final entry in before.entries) {
      final value = current[entry.key];
      if (value == null || !value.equals(entry.value)) {
        throw RevisionCorruption(
          '${change.table}/${change.rowKey}.${entry.key} 与预期旧值不一致',
        );
      }
    }
  }

  /// 两个提交之间的净变化。
  ///
  /// 优先合并 `(from, to]` 里保留的变更明细，不再做两次重建；起点在保留历史
  /// 之外或中间有基线跳变时退回两次重建，[to] 是当前 `HEAD` 时一侧直接用当前
  /// 表（ADR-0039 第 2 条、方案 R8）。
  Future<RevisionDiff> compare(RawExecutor executor, int from, int to) async {
    try {
      final changes = await foldChanges(executor, from, to);
      return _diffFromChanges(changes, from: from, to: to);
    } on _FoldUnavailable {
      // 保留的变更明细不足以得出可信结果，按两次重建比较。
    }
    final head = await self.headId(executor);
    final after = to == head
        ? await self.readProjection(executor)
        : await self._rebuild(executor, to);
    final before = await self._rebuild(executor, from);
    return _diffFromChanges(diffProjections(before, after), from: from, to: to);
  }

  RevisionDiff _diffFromChanges(
    List<RevisionChange> changes, {
    required int from,
    required int to,
  }) {
    return RevisionDiff(
      before: from,
      after: to,
      entries: [
        for (final change in changes)
          RevisionDiffEntry(
            table: change.table,
            rowKey: change.rowKey,
            op: change.op,
            columns: change.op == ChangeOp.update
                ? (change.before?.keys.toSet() ?? const <String>{})
                : const <String>{},
          ),
      ],
    );
  }

  /// 只按保留的变更明细合并 `(from, to]` 的净变化，不重建任何一份投影。
  ///
  /// 结果与“分别重建 [from] 与 [to] 两份投影再比较”一致，按表名、主键、行级
  /// 新增、修改或删除给出，修改只带真正发生净变化的列。起点之前的提交已经被
  /// 裁掉、中间有清理历史留下的基线提交或缺少明细的提交时抛出私有的
  /// [_FoldUnavailable]，由 [compare] 决定是否退回两次重建；提交本身不存在时
  /// 仍按数据损坏抛出 [RevisionCorruption]。
  Future<List<RevisionChange>> foldChanges(
    RawExecutor executor,
    int from,
    int to,
  ) async {
    final toCommit = await self.commitById(executor, to);
    if (toCommit == null) throw RevisionCorruption('提交 $to 不存在');
    if (from == to) return const [];
    if (to < from) {
      // 反向区间没有可合并的明细，交给两次重建按原本的方向比较。
      throw const _FoldUnavailable('起点晚于终点');
    }
    final fromCommit = await self.commitById(executor, from);
    if (fromCommit == null) {
      throw _FoldUnavailable('起点提交 $from 已不在保留历史内');
    }
    // 起点本身是裁剪留下的断点（父提交已删掉、也不是清理历史写的基线）时，
    // 无法确认起点是保留历史里连续的一环，交给两次重建按检查点核对。
    if (fromCommit.parentId == null &&
        from != 0 &&
        fromCommit.kind != RevisionKind.baseline) {
      throw const _FoldUnavailable('起点之前的提交已被裁掉');
    }

    final commits = await selectRows(
      executor,
      'revision_commit',
      columns: ['id', 'parent_id', 'kind', 'change_count'],
      where: 'id > ? AND id <= ?',
      whereArgs: [from, to],
      orderBy: 'id',
    );
    final detailRows = await executor.rawQuery(
      'SELECT commit_id, COUNT(*) AS count FROM revision_change '
      'WHERE commit_id > ? AND commit_id <= ? GROUP BY commit_id',
      [from, to],
    );
    final detailCounts = {
      for (final row in detailRows)
        row['commit_id']! as int: row['count']! as int,
    };
    var expectedParent = from;
    for (final row in commits) {
      final id = row['id']! as int;
      if (row['parent_id'] != expectedParent) {
        throw _FoldUnavailable('提交 $id 之前有历史被裁掉');
      }
      if (RevisionKind.fromValue(row['kind']! as String) ==
          RevisionKind.baseline) {
        throw _FoldUnavailable('提交 $id 是一次历史清理留下的基线');
      }
      if ((detailCounts[id] ?? 0) != row['change_count']) {
        throw _FoldUnavailable('提交 $id 的变更明细不完整');
      }
      expectedParent = id;
    }

    final rows = await selectRows(
      executor,
      'revision_change',
      where: 'commit_id > ? AND commit_id <= ?',
      whereArgs: [from, to],
      orderBy: 'commit_id, seq',
    );
    final folders = <String, _ChangeFolder>{};
    for (final row in rows) {
      final change = RevisionChange.fromRow(row);
      final key = '${change.table}\u0000${change.rowKey}';
      final folder = folders.putIfAbsent(
        key,
        () => _ChangeFolder(change.table, change.rowKey),
      );
      folder.apply(change);
    }

    final tableOrder = {
      for (var index = 0; index < versionedTableNames.length; index++)
        versionedTableNames[index]: index,
    };
    final ordered = folders.values.toList()
      ..sort((left, right) {
        final byTable = (tableOrder[left.table] ?? 0).compareTo(
          tableOrder[right.table] ?? 0,
        );
        return byTable != 0 ? byTable : left.rowKey.compareTo(right.rowKey);
      });
    final changes = <RevisionChange>[];
    var seq = 1;
    for (final folder in ordered) {
      final change = folder.toChange();
      if (change == null) continue;
      changes.add(
        RevisionChange(
          commitId: 0,
          seq: seq++,
          table: change.table,
          rowKey: change.rowKey,
          op: change.op,
          before: change.before,
          after: change.after,
        ),
      );
    }
    return changes;
  }

  Future<RevisionRestorePreview> previewRestore(
    RawExecutor executor,
    int target,
  ) async {
    final targetCommit = await self.commitById(executor, target);
    if (targetCommit == null) throw RevisionCorruption('提交 $target 不存在');
    final head = await self.headId(executor);
    final before = await self.readProjection(executor);
    final after = await self._rebuild(executor, target);
    return RevisionRestorePreview(
      target: targetCommit,
      head: head,
      diff: _diffFromChanges(
        diffProjections(before, after),
        from: head,
        to: target,
      ),
    );
  }

  /// 整版恢复：清空并装入已校验的目标投影，追加一条恢复提交。
  ///
  /// 清除与装入在同一个事务里完成，触发器在此期间被上下文标记为暂停，避免
  /// 把整库删除与重插记成逐行历史；净变化由事务内比较后一次性写入。
  Future<RevisionCommit> restore(
    RawDatabase db,
    int target, {
    required int expectedHead,
    String action = '恢复版本',
    String actor = 'user',
  }) async {
    final targetProjection = await self._rebuild(db, target);
    final missing = <String>[];
    for (final hash in AssetStore.hashesInProjection(targetProjection)) {
      if (!await self.assets.verify(db, hash)) missing.add(hash);
    }
    if (missing.isNotEmpty) {
      throw RevisionCorruption('目标版本的附件校验失败：${missing.take(3).join(', ')}');
    }
    return self._replaceWithProjection(
      db,
      targetProjection,
      expectedHead: expectedHead,
      action: action,
      actor: actor,
      restoredCommitId: target,
    );
  }

  /// 导入当前数据包：不依赖历史，把已校验的投影装进当前库并追加提交。
  Future<RevisionCommit> importProjection(
    RawDatabase db,
    Projection projection, {
    required int expectedHead,
    Map<String, Uint8List> attachments = const {},
    String action = '导入数据',
    String actor = 'user',
  }) {
    return self._replaceWithProjection(
      db,
      projection,
      expectedHead: expectedHead,
      action: action,
      actor: actor,
      attachments: attachments,
    );
  }

  Future<RevisionCommit> _replaceWithProjection(
    RawDatabase db,
    Projection targetProjection, {
    required int expectedHead,
    required String action,
    required String actor,
    int? restoredCommitId,
    Map<String, Uint8List> attachments = const {},
  }) async {
    return db.transaction((txn) async {
      final head = await self.headId(txn);
      if (head != expectedHead) {
        throw RevisionStaleHead(expected: expectedHead, actual: head);
      }
      await self.beginCommand(txn);
      final commitId = await self.reserveCommitId(txn);
      await updateRow(txn, 'revision_context', {
        'suppress': 1,
      }, where: 'id = 1');
      for (final entry in attachments.entries) {
        await self.assets.putBytes(txn, entry.key, entry.value);
      }
      final current = await self.readProjection(txn);
      await self._replaceProjection(txn, targetProjection);
      await self._verifyProjection(txn, targetProjection);
      final changes = self._changesFromDiff(
        current,
        targetProjection,
        commitId,
      );
      final parent = await self.commitById(txn, head);
      // 整版恢复与导入推进代次，整份数据被换掉：旧的遮蔽行对应的格子可能已经
      // 不存在，清空它免得下一次推送按旧格子去掉本机改动（ADR-0040）。
      await RevisionShadows(txn).clear();
      final commit = await self._appendCommit(
        txn,
        CommitDraft(
          id: commitId,
          parentId: head,
          generation: (parent?.generation ?? 0) + 1,
          actor: actor,
          action: action,
          kind: restoredCommitId != null
              ? RevisionKind.restore
              : RevisionKind.import,
          restoredCommitId: restoredCommitId,
          changes: changes,
        ),
      );
      await self._clearContext(txn);
      return commit;
    });
  }

  /// 整库恢复之后补记一条“回到旧状态”的恢复提交。
  ///
  /// 换库恢复把数据换成备份那一刻的内容，备份之后本机做过的改动不再在库里，
  /// 但它们仍然在服务端的提交序列上；恢复之前保存的恢复点（调用方在换库之前
  /// 读到的 [before] 投影）与恢复后的 [after] 投影之间的差异就是这次恢复的
  /// 净变化。这里不重写业务行，只把这份差异写成一条 `restore` 提交，让下一轮
  /// 同步可以按普通推送把它发上去，删除、新增与修改都会到达其他设备（同步
  /// 方案 3.4 的短期修复）。
  ///
  /// 这条提交的父提交是恢复之后的 `HEAD`，所以本机历史连续；提交身份与普通
  /// 提交一样由引擎生成。没有差异时不形成提交，返回空。
  Future<RevisionCommit?> recordRestoreDiff(
    RawDatabase db, {
    required Projection before,
    required Projection after,
    required int expectedHead,
    String action = '恢复旧备份',
    String actor = 'user',
  }) {
    return db.transaction((txn) async {
      final head = await self.headId(txn);
      if (head != expectedHead) {
        throw RevisionStaleHead(expected: expectedHead, actual: head);
      }
      if (projectionsEqual(before, after)) return null;
      await self.beginCommand(txn);
      final commitId = await self.reserveCommitId(txn);
      final changes = self._changesFromDiff(before, after, commitId);
      final parent = await self.commitById(txn, head);
      // 整份数据被换掉：恢复前记下的遮蔽行已经不对应任何本机提交，不清掉会
      // 让下一轮推送按旧格子去掉本机改动（ADR-0040）。
      await RevisionShadows(txn).clear();
      final commit = await self._appendCommit(
        txn,
        CommitDraft(
          id: commitId,
          parentId: head,
          generation: (parent?.generation ?? 0) + 1,
          actor: actor,
          action: action,
          kind: RevisionKind.restore,
          changes: changes,
        ),
      );
      await self._clearContext(txn);
      return commit;
    });
  }

  Future<void> _replaceProjection(
    RawExecutor txn,
    Projection projection,
  ) async {
    for (final table in versionedTableNames.reversed) {
      await deleteRows(txn, table);
    }
    for (final table in versionedTableNames) {
      final rows = projection[table] ?? const <String, TypedRow>{};
      for (final row in rows.values) {
        await insertRow(txn, table, sqliteRow(row));
      }
    }
    final violations = await txn.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw RevisionCorruption('恢复后的数据存在外键错误');
    }
  }

  Future<void> _verifyProjection(RawExecutor txn, Projection expected) async {
    final actual = await self.readProjection(txn);
    final differences = diffProjections(expected, actual);
    if (differences.isEmpty) return;
    final first = differences.first;
    throw RevisionCorruption('恢复后的 ${first.table}/${first.rowKey} 与目标版本不一致');
  }

  List<RevisionChange> _changesFromDiff(
    Projection before,
    Projection after,
    int commitId,
  ) {
    var seq = 1;
    return [
      for (final change in diffProjections(before, after))
        RevisionChange(
          commitId: commitId,
          seq: seq++,
          table: change.table,
          rowKey: change.rowKey,
          op: change.op,
          before: change.before,
          after: change.after,
        ),
    ];
  }

  Future<int> _writeCheckpoint(
    RawExecutor txn, {
    required int commitId,
    required String kind,
    required Projection projection,
  }) async {
    final projectionJson = encodeProjection(projection);
    final raw = utf8.encode(projectionJson);
    final compressed = Uint8List.fromList(gzip.encode(raw));
    final hashes = AssetStore.hashesInProjection(projection).toList()..sort();
    final id = await insertRow(txn, 'revision_checkpoint', {
      'kind': kind,
      'commit_id': commitId,
      'payload': compressed,
      'encoding': 'json+gzip',
      'raw_bytes': raw.length,
      'asset_hashes_json': jsonEncode(hashes),
      'checksum': self._checksum(projectionJson, hashes),
      'created_at': formatDateTime(self.clock()),
    });
    await self.recordAssetRefs(
      txn,
      ownerKind: 'checkpoint',
      ownerId: id,
      hashes: hashes,
    );
    return id;
  }

  /// 检查点的校验值：按解压后的投影原文与附件清单计算，与编码方式无关。
  String _checksum(String projectionJson, List<String> hashes) {
    final input = '$projectionJson\n${hashes.join(',')}';
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// 把某一提交的投影固化成检查点；命名、裁剪与清理历史都从这里取基线。
  Future<int> materializeCheckpoint(
    RawExecutor txn,
    int commitId, {
    String kind = 'named',
  }) async {
    final projection = await self.projectionAt(txn, commitId);
    return self._writeCheckpoint(
      txn,
      commitId: commitId,
      kind: kind,
      projection: projection,
    );
  }

  /// 提交之后的检查点策略：写事务里不再生成检查点。
  ///
  /// 检查点改由 [afterCommitIdle] 在独占区释放之后按累计字节数生成，写入那次
  /// 事务不再重建整库投影（ADR-0039 第 2 条、方案 R4）。
  Future<void> checkpointAfterCommit(
    RawExecutor txn,
    RevisionCommit commit,
  ) async {}

  /// 一次写入落库、独占区释放之后的空闲工作：空闲检查点与自动留存
  /// （ADR-0039 第 2 条、方案 3.8）。
  ///
  /// 两者共用同一次只读查询：先按距最近检查点累计的变更明细字节数判断要不要
  /// 生成检查点，再用同一份统计判断提交条数与历史字节是否越过自动裁剪的阈值。
  /// 没有越过阈值时不读业务表；越过之后各自单独开维护事务，检查点用
  /// [readProjection] 读当前表，自动裁剪走 [RevisionMaintenanceMixin.autoRetention]。
  /// 两件事互不影响，失败只丢掉这一次机会，下一次写入会重新判断；同一时刻只
  /// 允许一个空闲维护，避免重复生成或重复裁剪。
  Future<void> afterCommitIdle(RawDatabase db) async {
    if (_idleCheckpointRunning) return;
    _idleCheckpointRunning = true;
    try {
      final stats = await _maintenanceStats(db);
      try {
        await _idleCheckpoint(db, stats.pendingBytes);
      } catch (_) {
        // 检查点失败只丢掉这一次机会，下一次写入会重新判断。
      }
      try {
        await self.autoRetention(
          db,
          commitCount: stats.commitCount,
          historyBytes: stats.historyBytes,
        );
      } catch (_) {
        // 自动裁剪失败同样不改变本次写入的结果。
      }
    } catch (_) {
      // 统计查询失败时不改已经落库的写入，下一次写入再判断。
    } finally {
      _idleCheckpointRunning = false;
    }
  }

  /// 空闲检查点：累计字节数达到 [RevisionEngine.idleCheckpointBytes] 时生成
  /// 一份 `periodic` 检查点；生成之前事务里再读一次，避免并发写入重复生成。
  Future<void> _idleCheckpoint(RawDatabase db, int pendingBytes) async {
    if (self.idleCheckpointBytes <= 0 ||
        pendingBytes < self.idleCheckpointBytes) {
      return;
    }
    await db.transaction((txn) async {
      if (await _pendingCheckpointBytes(txn) < self.idleCheckpointBytes) {
        return;
      }
      final head = await self.headId(txn);
      final base = await _latestCheckpointCommit(txn);
      if (head <= base) return;
      final projection = await self.readProjection(txn);
      await self._writeCheckpoint(
        txn,
        commitId: head,
        kind: 'periodic',
        projection: projection,
      );
    });
  }

  /// 空闲维护的一次统计：距最近检查点的累计字节数、提交条数与历史字节数。
  ///
  /// 合成一条只读查询，每次提交之后都判断一次，不额外多读；历史字节是提交
  /// 变更明细与检查点压缩后长度之和，自动留存的阈值按它判断。
  Future<({int pendingBytes, int commitCount, int historyBytes})>
  _maintenanceStats(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT (SELECT COUNT(*) FROM revision_commit) AS commit_count, '
      '(SELECT COALESCE(SUM(byte_length), 0) FROM revision_commit) AS commit_bytes, '
      '(SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM revision_checkpoint) '
      'AS checkpoint_bytes, '
      '(SELECT COALESCE(SUM(byte_length), 0) FROM revision_commit WHERE id > '
      '(SELECT COALESCE(MAX(commit_id), 0) FROM revision_checkpoint)) AS pending',
    );
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    int value(String key) => row[key] as int? ?? 0;
    return (
      pendingBytes: value('pending'),
      commitCount: value('commit_count'),
      historyBytes: value('commit_bytes') + value('checkpoint_bytes'),
    );
  }

  /// 距最近检查点累计的变更明细字节数；没有新提交时为 0。
  Future<int> _pendingCheckpointBytes(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT COALESCE(SUM(byte_length), 0) AS pending FROM revision_commit '
      'WHERE id > (SELECT COALESCE(MAX(commit_id), 0) FROM revision_checkpoint)',
    );
    if (rows.isEmpty) return 0;
    return rows.first['pending'] as int? ?? 0;
  }

  /// 最近检查点对应的提交编号；没有检查点时为 0。
  Future<int> _latestCheckpointCommit(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT COALESCE(MAX(commit_id), 0) AS base FROM revision_checkpoint',
    );
    if (rows.isEmpty) return 0;
    return rows.first['base'] as int? ?? 0;
  }
}

/// `(from, to]` 里同一个“表名＋主键”的合并状态。
///
/// 第一条变化决定这一行在起点是否存在：新增说明起点没有这一行，修改与删除
/// 说明起点有。之后逐条把修改列的原值补进 [_startValues]、新值写进
/// [_nowValues]，区间内改过又改回来的列因此不会出现在净变化里。
class _ChangeFolder {
  _ChangeFolder(this.table, this.rowKey);

  final String table;
  final String rowKey;

  /// 起点是否存在；第一条变化之前为空。
  bool? _existsAtStart;
  bool _existsNow = false;

  /// 起点一侧已知的值，只含区间内改动过的列。
  final Map<String, RevisionValue> _startValues = {};

  /// 当前一侧已知的值，列的集合与 [_startValues] 一致。
  final Map<String, RevisionValue> _nowValues = {};

  void apply(RevisionChange change) {
    switch (change.op) {
      case ChangeOp.insert:
        if (_existsNow) {
          throw _FoldUnavailable('$table/$rowKey 的变更明细顺序不连续');
        }
        _existsAtStart ??= false;
        _existsNow = true;
        _nowValues
          ..clear()
          ..addAll(change.after!);
        return;
      case ChangeOp.update:
        if (_existsAtStart == null) {
          _existsAtStart = true;
          _existsNow = true;
        } else if (!_existsNow) {
          throw _FoldUnavailable('$table/$rowKey 删除之后又出现修改');
        }
        for (final entry in change.before!.entries) {
          _startValues.putIfAbsent(entry.key, () => entry.value);
        }
        for (final entry in change.after!.entries) {
          _nowValues[entry.key] = entry.value;
        }
        return;
      case ChangeOp.delete:
        if (_existsAtStart == null) {
          _existsAtStart = true;
          _existsNow = true;
        } else if (!_existsNow) {
          throw _FoldUnavailable('$table/$rowKey 重复删除');
        }
        for (final entry in change.before!.entries) {
          _startValues.putIfAbsent(entry.key, () => entry.value);
        }
        _existsNow = false;
        _nowValues.clear();
        return;
    }
  }

  /// 这一行在区间两端的净变化；净变化为空时返回空。
  RevisionChange? toChange() {
    final existsAtStart = _existsAtStart;
    if (existsAtStart == null) return null;
    if (!existsAtStart) {
      if (!_existsNow) return null;
      return RevisionChange(
        commitId: 0,
        seq: 0,
        table: table,
        rowKey: rowKey,
        op: ChangeOp.insert,
        after: Map<String, RevisionValue>.of(_nowValues),
      );
    }
    if (!_existsNow) {
      return RevisionChange(
        commitId: 0,
        seq: 0,
        table: table,
        rowKey: rowKey,
        op: ChangeOp.delete,
        before: Map<String, RevisionValue>.of(_startValues),
      );
    }
    final columns = <String>{..._startValues.keys, ..._nowValues.keys};
    final changed = <String>{
      for (final column in columns)
        if (_startValues[column] == null ||
            _nowValues[column] == null ||
            !_startValues[column]!.equals(_nowValues[column]!))
          column,
    };
    if (changed.isEmpty) return null;
    return RevisionChange(
      commitId: 0,
      seq: 0,
      table: table,
      rowKey: rowKey,
      op: ChangeOp.update,
      before: projectColumns(_startValues, changed),
      after: projectColumns(_nowValues, changed),
    );
  }
}
