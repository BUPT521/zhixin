part of 'revision_engine.dart';

/// 投影与检查点：读取当前表、从检查点重建、比较、整版恢复与导入，以及检查点
/// 的写入、编码与校验。
///
/// 拥有者：泳道 C（ADR-0039 第 3.3 节）。

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

mixin RevisionProjectionMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

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
    final projectionJson = decodeCheckpointPayload(checkpoint);
    final projection = decodeProjection(projectionJson);
    final expected = self._checksum(projectionJson, checkpoint.assetHashes);
    if (expected != checkpoint.checksum) {
      throw RevisionCorruption('检查点 ${checkpoint.id} 校验值不一致');
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

  Future<RevisionDiff> compare(RawExecutor executor, int from, int to) async {
    final before = await self._rebuild(executor, from);
    final after = await self._rebuild(executor, to);
    return self.diffProjections(before, after, from: from, to: to);
  }

  RevisionDiff diffProjections(
    Projection before,
    Projection after, {
    int from = 0,
    int to = 0,
  }) {
    final entries = <RevisionDiffEntry>[];
    for (final table in versionedTableNames) {
      final left = before[table] ?? const <String, TypedRow>{};
      final right = after[table] ?? const <String, TypedRow>{};
      final keys = <String>{...left.keys, ...right.keys};
      for (final key in keys) {
        final oldRow = left[key];
        final newRow = right[key];
        if (oldRow == null && newRow == null) continue;
        if (oldRow == null) {
          entries.add(
            RevisionDiffEntry(table: table, rowKey: key, op: ChangeOp.insert),
          );
          continue;
        }
        if (newRow == null) {
          entries.add(
            RevisionDiffEntry(table: table, rowKey: key, op: ChangeOp.delete),
          );
          continue;
        }
        final changed = changedColumns(oldRow, newRow);
        if (changed.isEmpty) continue;
        entries.add(
          RevisionDiffEntry(
            table: table,
            rowKey: key,
            op: ChangeOp.update,
            columns: changed,
          ),
        );
      }
    }
    return RevisionDiff(before: from, after: to, entries: entries);
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
      diff: self.diffProjections(before, after, from: head, to: target),
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
    for (final table in versionedTableNames) {
      final want = expected[table] ?? const <String, TypedRow>{};
      final got = actual[table] ?? const <String, TypedRow>{};
      if (want.length != got.length) {
        throw RevisionCorruption('恢复后的 $table 行数不一致');
      }
      for (final entry in want.entries) {
        final row = got[entry.key];
        if (row == null || !typedRowsEqual(row, entry.value)) {
          throw RevisionCorruption('恢复后的 $table/${entry.key} 内容不一致');
        }
      }
    }
  }

  List<RevisionChange> _changesFromDiff(
    Projection before,
    Projection after,
    int commitId,
  ) {
    final changes = <RevisionChange>[];
    var seq = 1;
    for (final table in versionedTableNames) {
      final left = before[table] ?? const <String, TypedRow>{};
      final right = after[table] ?? const <String, TypedRow>{};
      final keys = <String>{...left.keys, ...right.keys};
      for (final key in keys) {
        final oldRow = left[key];
        final newRow = right[key];
        if (oldRow == null && newRow == null) continue;
        if (oldRow == null) {
          changes.add(
            RevisionChange(
              commitId: commitId,
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
              commitId: commitId,
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
            commitId: commitId,
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

  Future<int> _writeCheckpoint(
    RawExecutor txn, {
    required int commitId,
    required String kind,
    required Projection projection,
  }) async {
    final projectionJson = encodeProjection(projection);
    final raw = utf8.encode(projectionJson);
    final hashes = AssetStore.hashesInProjection(projection).toList()..sort();
    final id = await insertRow(txn, 'revision_checkpoint', {
      'kind': kind,
      'commit_id': commitId,
      'payload': Uint8List.fromList(raw),
      'encoding': 'json',
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

  /// 提交之后的检查点策略；阶段 0 保留原来的周期检查点，由泳道 C 改成空闲时
  /// 按累计字节数生成。
  Future<void> checkpointAfterCommit(
    RawExecutor txn,
    RevisionCommit commit,
  ) async {
    if (self.checkpointEvery > 0 && commit.id % self.checkpointEvery == 0) {
      final projection = await self.projectionAt(txn, commit.id);
      await self._writeCheckpoint(
        txn,
        commitId: commit.id,
        kind: 'periodic',
        projection: projection,
      );
    }
  }

  /// 一次提交落库、独占区释放之后的空闲工作；阶段 0 为空实现，由泳道 C 接上
  /// 空闲检查点。
  Future<void> afterCommitIdle(RawDatabase db) async {}
}
