part of 'revision_engine.dart';

/// 留存与维护：命名版本、清理历史、按条数或容量裁剪、附件回收与核对、占用
/// 统计，以及历史下游读取位置的阻塞判断。
///
/// 拥有者：泳道 B（ADR-0039 第 3.3 节）。

mixin RevisionMaintenanceMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  Future<List<RevisionRef>> refs(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_ref',
      where: 'name != ?',
      whereArgs: [RevisionRef.headName],
      orderBy: 'created_at DESC',
    );
    return rows.map(RevisionRef.fromRow).toList(growable: false);
  }

  /// 登记一条提交或一份检查点引用的附件哈希；阶段 0 为空实现，由泳道 B 填上。
  Future<void> recordAssetRefs(
    RawExecutor txn, {
    required String ownerKind,
    required int ownerId,
    required Iterable<String> hashes,
  }) async {}

  /// 历史下游读者的阻塞原因；阶段 0 返回空，由泳道 B 填上。
  Future<List<String>> historyBlockers(
    RawExecutor executor, {
    required bool clearing,
  }) async => const [];

  Future<RevisionRef> nameCommit(
    RawDatabase db,
    int commitId, {
    required String name,
    String? note,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == RevisionRef.headName) {
      throw ArgumentError('版本名称不能为空，也不能叫 HEAD');
    }
    final commit = await self.commitById(db, commitId);
    if (commit == null) throw RevisionCorruption('提交 $commitId 不存在');
    return db.transaction((txn) async {
      final now = formatDateTime(self.clock());
      await insertRow(txn, 'revision_ref', {
        'name': trimmed,
        'commit_id': commitId,
        'note': note?.trim(),
        'created_at': now,
        'updated_at': now,
      }, replace: true);
      await self.materializeCheckpoint(txn, commitId);
      return RevisionRef(
        name: trimmed,
        commitId: commitId,
        note: note?.trim(),
        createdAt: self.clock(),
        updatedAt: self.clock(),
      );
    });
  }

  Future<void> deleteName(RawDatabase db, String name) async {
    if (name == RevisionRef.headName) throw ArgumentError('不能删除 HEAD');
    await db.transaction((txn) async {
      final rows = await selectRows(
        txn,
        'revision_ref',
        where: 'name = ?',
        whereArgs: [name],
      );
      if (rows.isEmpty) return;
      final commitId = rows.first['commit_id']! as int;
      await deleteRows(
        txn,
        'revision_ref',
        where: 'name = ?',
        whereArgs: [name],
      );
      final others = await selectRows(
        txn,
        'revision_ref',
        where: 'commit_id = ?',
        whereArgs: [commitId],
      );
      if (others.isEmpty) {
        await deleteRows(
          txn,
          'revision_checkpoint',
          where: 'kind = ? AND commit_id = ?',
          whereArgs: ['named', commitId],
        );
      }
    });
  }

  /// 去掉消息里指向已删除提交或已失去撤销入口的回执编号。
  ///
  /// 清理与裁剪在维护事务里直接删历史，不经过触发器；消息如果在同一个事务里
  /// 静默改写，检查点与重建结果就和当前数据不一致。因此回执清理放在清理之后，
  /// 由调用方开一条普通提交，让触发器照常采集这次改写。没有需要清理的编号时
  /// 不更新任何消息，也不会形成提交。
  Future<int> stripDeadReceipts(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT DISTINCT commit_id FROM revision_change',
    );
    final live = {for (final row in rows) row['commit_id']! as int};
    final messages = await selectRows(
      executor,
      'message',
      columns: ['id', 'structured_json'],
      where: "structured_json LIKE '%commit_id%'",
    );
    var changed = 0;
    for (final row in messages) {
      final payload = ChatMessagePayload.decode(
        row['structured_json'] as String?,
      );
      final updated = payload?.withoutDeadReceipts(live);
      if (updated == null) continue;
      await updateRow(
        executor,
        'message',
        {'structured_json': updated.encode()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      changed++;
    }
    return changed;
  }

  /// 清理历史：以当前数据为新基线，删除全部提交明细、命名版本与检查点。
  Future<void> clearHistory(RawDatabase db) async {
    await db.transaction((txn) async {
      final head = await self.headId(txn);
      final projection = await self.readProjection(txn);
      final commit = await self.commitById(txn, head);
      if (commit == null) throw RevisionCorruption('HEAD $head 不存在');
      await deleteRows(txn, 'revision_change');
      await deleteRows(txn, 'revision_checkpoint');
      await deleteRows(txn, 'revision_asset_ref');
      await deleteRows(
        txn,
        'revision_commit',
        where: 'id != ?',
        whereArgs: [head],
      );
      await deleteRows(
        txn,
        'revision_ref',
        where: 'name != ?',
        whereArgs: [RevisionRef.headName],
      );
      final now = formatDateTime(self.clock());
      await updateRow(
        txn,
        'revision_commit',
        {
          'parent_id': null,
          'generation': commit.generation + 1,
          'kind': RevisionKind.baseline.value,
          'action': '清理后保留',
          'reverted_commit_id': null,
          'restored_commit_id': null,
          'change_count': 0,
          'byte_length': 0,
          'conflict_count': 0,
        },
        where: 'id = ?',
        whereArgs: [head],
      );
      await updateRow(
        txn,
        'revision_ref',
        {'commit_id': head, 'updated_at': now},
        where: 'name = ?',
        whereArgs: [RevisionRef.headName],
      );
      await self._writeCheckpoint(
        txn,
        commitId: head,
        kind: 'initial',
        projection: projection,
      );
      await updateRow(txn, 'revision_sequence', {
        'next_commit': head + 1,
      }, where: 'id = 1');
      await self._collectGarbage(txn, projection, currentHead: head);
    });
  }

  /// 有界留存：保留最近若干提交、命名版本与 `HEAD`，更早的历史先固化成
  /// 基线检查点再删除。达到容量上限时继续减少保留提交数。
  Future<RevisionRetentionResult> prune(
    RawDatabase db, {
    int keepCommits = 100,
    int? maxBytes,
  }) async {
    if (keepCommits < 1) throw RangeError.range(keepCommits, 1, null);
    var keep = keepCommits;
    while (true) {
      final result = await self._pruneOnce(db, keep);
      if (maxBytes == null) return result;
      var size = await self.databaseBytes(db);
      if (size > maxBytes) {
        // 删除后的页空间不会自动归还；预算判断前先回收一次。
        await db.execute('VACUUM');
        size = await self.databaseBytes(db);
      }
      if (size <= maxBytes || keep <= 1) {
        return RevisionRetentionResult(
          removedCommits: result.removedCommits,
          removedCheckpoints: result.removedCheckpoints,
          removedAssets: result.removedAssets,
          keptFrom: result.keptFrom,
          databaseBytes: size,
        );
      }
      keep = keep ~/ 2;
      if (keep < 1) keep = 1;
    }
  }

  Future<RevisionRetentionResult> _pruneOnce(RawDatabase db, int keep) async {
    return db.transaction((txn) async {
      final head = await self.headId(txn);
      final all = await self.commits(txn);
      final named = await self.refs(txn);
      final namedCommits = {for (final ref in named) ref.commitId};
      final ids = all.map((commit) => commit.id).toList()..sort();
      final keepIds = <int>{head, ...namedCommits};
      for (final id in ids.reversed) {
        if (keepIds.length >= keep + namedCommits.length + 1) break;
        keepIds.add(id);
      }
      if (ids.length <= keepIds.length) {
        final projection = await self.readProjection(txn);
        await self._collectGarbage(txn, projection, currentHead: head);
        return RevisionRetentionResult(
          removedCommits: 0,
          removedCheckpoints: 0,
          removedAssets: 0,
          keptFrom: ids.isEmpty ? 0 : ids.first,
          databaseBytes: await self.databaseBytes(txn),
        );
      }
      final oldest = keepIds.reduce((a, b) => a < b ? a : b);
      final projection = await self.projectionAt(txn, oldest);
      await self._writeCheckpoint(
        txn,
        commitId: oldest,
        kind: 'trimmed',
        projection: projection,
      );
      final verified = await self.projectionAt(txn, oldest);
      if (!self._sameProjection(projection, verified)) {
        throw RevisionCorruption('裁剪前的新基线校验失败，已取消本次清理');
      }
      final beforeCommits = await selectRows(txn, 'revision_commit');
      final beforeCheckpoints = await selectRows(txn, 'revision_checkpoint');
      await deleteRows(
        txn,
        'revision_change',
        where: 'commit_id < ?',
        whereArgs: [oldest],
      );
      await deleteRows(
        txn,
        'revision_checkpoint',
        where: 'commit_id < ? AND kind != ?',
        whereArgs: [oldest, 'named'],
      );
      final removed = <int>[];
      for (final commit in beforeCommits) {
        final id = commit['id']! as int;
        if (id >= oldest || id == head || namedCommits.contains(id)) continue;
        await deleteRows(
          txn,
          'revision_commit',
          where: 'id = ?',
          whereArgs: [id],
        );
        removed.add(id);
      }
      // 被删掉的中间提交不再作为父提交；保留提交的父指针置空。
      if (removed.isEmpty) {
        await updateRow(
          txn,
          'revision_commit',
          {'parent_id': null},
          where: 'id = ?',
          whereArgs: [oldest],
        );
      } else {
        await updateRow(
          txn,
          'revision_commit',
          {'parent_id': null},
          where:
              'id = ? OR parent_id IN (${removed.map((_) => '?').join(',')})',
          whereArgs: [oldest, ...removed],
        );
      }
      final keptProjection = await self.readProjection(txn);
      final removedAssets = await self._collectGarbage(
        txn,
        keptProjection,
        currentHead: head,
      );
      return RevisionRetentionResult(
        removedCommits: removed.length,
        removedCheckpoints:
            beforeCheckpoints.length -
            (await selectRows(txn, 'revision_checkpoint')).length,
        removedAssets: removedAssets,
        keptFrom: oldest,
        databaseBytes: await self.databaseBytes(txn),
      );
    });
  }

  bool _sameProjection(Projection left, Projection right) {
    for (final table in versionedTableNames) {
      final a = left[table] ?? const <String, TypedRow>{};
      final b = right[table] ?? const <String, TypedRow>{};
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        final row = b[entry.key];
        if (row == null || !typedRowsEqual(row, entry.value)) return false;
      }
    }
    return true;
  }

  Future<int> _collectGarbage(
    RawExecutor executor,
    Projection current, {
    required int currentHead,
  }) async {
    final keep = <String>{...AssetStore.hashesInProjection(current)};
    final checkpoints = await selectRows(
      executor,
      'revision_checkpoint',
      columns: ['asset_hashes_json'],
    );
    for (final row in checkpoints) {
      keep.addAll(
        decodeStringList(row['asset_hashes_json'] as String? ?? '[]'),
      );
    }
    final changes = await selectRows(
      executor,
      'revision_change',
      columns: ['before_json', 'after_json'],
    );
    for (final row in changes) {
      keep.addAll(
        AssetStore.hashesInChanges([
          RevisionChange(
            commitId: currentHead,
            seq: 0,
            table: '',
            rowKey: '',
            op: ChangeOp.update,
            before: decodeTypedRow(row['before_json'] as String?),
            after: decodeTypedRow(row['after_json'] as String?),
          ),
        ]),
      );
    }
    return self.assets.collectGarbage(executor, keep: keep);
  }

  Future<int> databaseBytes(RawExecutor executor) async {
    final page = await executor.rawQuery('PRAGMA page_count');
    final size = await executor.rawQuery('PRAGMA page_size');
    final count = page.isEmpty ? 0 : page.first.values.first! as int;
    final bytes = size.isEmpty ? 0 : size.first.values.first! as int;
    return count * bytes;
  }

  /// 检查点、变更明细与当前投影引用的附件是否都能读出并通过哈希校验。
  ///
  /// 只查检查点会漏掉检查点之间提交里引用的附件；备份时把整库带走，所以
  /// 三类引用都要核对，缺任何一张都算备份不完整。
  Future<List<String>> verifyAssets(RawExecutor executor) async {
    final missing = <String>[];
    final all = <String>{};
    final checkpoints = await selectRows(
      executor,
      'revision_checkpoint',
      columns: ['asset_hashes_json'],
    );
    for (final row in checkpoints) {
      all.addAll(decodeStringList(row['asset_hashes_json'] as String? ?? '[]'));
    }
    final changes = await selectRows(
      executor,
      'revision_change',
      columns: ['before_json', 'after_json'],
    );
    for (final row in changes) {
      all.addAll(
        AssetStore.hashesInChanges([
          RevisionChange(
            commitId: 0,
            seq: 0,
            table: '',
            rowKey: '',
            op: ChangeOp.update,
            before: decodeTypedRow(row['before_json'] as String?),
            after: decodeTypedRow(row['after_json'] as String?),
          ),
        ]),
      );
    }
    all.addAll(
      AssetStore.hashesInProjection(await self.readProjection(executor)),
    );
    for (final hash in all) {
      if (!await self.assets.verify(executor, hash)) missing.add(hash);
    }
    return missing;
  }
}
