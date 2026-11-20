part of 'revision_engine.dart';

/// 历史下游读者还没读完，清理历史被拒绝。
///
/// [reasons] 是给人看的原因，界面直接显示；清理历史会删掉全部提交，落后于
/// `HEAD` 的阻塞读取位置之后再也读不到这些提交，所以先拒绝、等读者追上。
class RevisionBlocked implements Exception {
  const RevisionBlocked(this.reasons);

  final List<String> reasons;

  @override
  String toString() =>
      reasons.isEmpty ? '暂时不能清理历史' : '暂时不能清理历史：${reasons.join('；')}';
}

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

  /// 登记一条提交或一份检查点引用的附件哈希。
  ///
  /// 同一个主人先删后插，重复登记不会留下重复行；提交与检查点的写入路径都
  /// 在同一个事务里调用这里，所以引用行与明细、检查点一起提交或一起回滚。
  Future<void> recordAssetRefs(
    RawExecutor txn, {
    required String ownerKind,
    required int ownerId,
    required Iterable<String> hashes,
  }) async {
    await deleteRows(
      txn,
      'revision_asset_ref',
      where: 'owner_kind = ? AND owner_id = ?',
      whereArgs: [ownerKind, ownerId],
    );
    for (final hash in hashes.toSet()) {
      await insertRow(txn, 'revision_asset_ref', {
        'owner_kind': ownerKind,
        'owner_id': ownerId,
        'hash': hash,
      }, ignore: true);
    }
  }

  /// 历史下游读者的阻塞原因；[clearing] 为真时对应“清理历史”。
  ///
  /// 裁剪不阻止：下界提前到阻塞位置之后即可，没读完的提交照样留在库里。清理
  /// 历史会删掉全部提交，阻塞的读者之后再也读不到，所以有阻塞位置落后于
  /// `HEAD` 时拒绝执行并给出原因。
  Future<List<String>> historyBlockers(
    RawExecutor executor, {
    required bool clearing,
  }) async {
    if (!clearing) return const [];
    final head = await self.headId(executor);
    final rows = await executor.rawQuery(
      'SELECT name, position FROM revision_cursor '
      'WHERE blocking = 1 AND position < ? ORDER BY position, name',
      [head],
    );
    final reasons = <String>[];
    for (final row in rows) {
      final name = row['name']! as String;
      final position = row['position']! as int;
      final pending = head - position;
      if (name == RevisionCursor.syncPushed) {
        reasons.add('还有 $pending 条修改没有同步到云端，先同步再清理');
      } else {
        reasons.add('读取位置 $name 停在 $position，还有 $pending 条修改没有处理，先处理再清理');
      }
    }
    return reasons;
  }

  /// 命名版本：只写名称与提交的指向，不立即固化检查点。
  ///
  /// 命名之后、裁剪之前的重建仍从更早的检查点回放；只有裁剪跨过这个命名提交
  /// 时才固化一份 `named` 检查点（见 [_pruneOnce]）。
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
      return RevisionRef(
        name: trimmed,
        commitId: commitId,
        note: note?.trim(),
        createdAt: self.clock(),
        updatedAt: self.clock(),
      );
    });
  }

  /// 删除命名版本：只去掉名称与它独占的 `named` 检查点。
  ///
  /// 检查点只在这个命名提交已经固化、且没有别的名字指向它时删除；删检查点时
  /// 连同它的附件引用行一起删，否则引用表会留下没有主人的行。
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
      if (others.isNotEmpty) return;
      final checkpoints = await selectRows(
        txn,
        'revision_checkpoint',
        columns: ['id'],
        where: 'kind = ? AND commit_id = ?',
        whereArgs: ['named', commitId],
      );
      for (final checkpoint in checkpoints) {
        final id = checkpoint['id']! as int;
        await deleteRows(
          txn,
          'revision_asset_ref',
          where: 'owner_kind = ? AND owner_id = ?',
          whereArgs: ['checkpoint', id],
        );
        await deleteRows(
          txn,
          'revision_checkpoint',
          where: 'id = ?',
          whereArgs: [id],
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
  ///
  /// 有阻塞读取位置落后于 `HEAD` 时拒绝执行，抛出带原因的 [RevisionBlocked]。
  /// 提交编号只增不减：这里不再把 `next_commit` 退回 `HEAD + 1`，占过但没有
  /// 落库的编号不会被后来的提交复用。
  Future<void> clearHistory(RawDatabase db) async {
    final blockers = await self.historyBlockers(db, clearing: true);
    if (blockers.isNotEmpty) throw RevisionBlocked(blockers);
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
      // 检查点写入时登记它引用的附件哈希，接着按当前数据回收附件。
      await self._writeCheckpoint(
        txn,
        commitId: head,
        kind: 'initial',
        projection: projection,
      );
      await _collectGarbage(txn, projection);
    });
  }

  /// 有界留存：保留最近若干提交、`HEAD` 与命名版本的提交行，更早的历史先
  /// 固化成基线检查点再删除。
  ///
  /// 下界取“按保留条数算出的最早保留提交”与“所有阻塞读取位置的最小值 + 1”
  /// 中较小者。容量预算先用 `SUM(byte_length)` 与检查点 `length(payload)` 一次
  /// 算出保留条数，只做一次裁剪，最多执行一次 `VACUUM`。
  Future<RevisionRetentionResult> prune(
    RawDatabase db, {
    int keepCommits = 100,
    int? maxBytes,
  }) async {
    if (keepCommits < 1) throw RangeError.range(keepCommits, 1, null);
    var keep = keepCommits;
    if (maxBytes != null) {
      keep = await _keepForBudget(
        db,
        keepCommits: keepCommits,
        maxBytes: maxBytes,
      );
    }
    final result = await _pruneOnce(db, keep);
    if (maxBytes == null) return result;
    var bytes = await self.databaseBytes(db);
    if (bytes <= maxBytes) {
      return RevisionRetentionResult(
        removedCommits: result.removedCommits,
        removedCheckpoints: result.removedCheckpoints,
        removedAssets: result.removedAssets,
        keptFrom: result.keptFrom,
        databaseBytes: bytes,
      );
    }
    // 删除后的页空间不会自动归还；整库只压缩这一次，不再逐次减半循环。
    await db.execute('VACUUM');
    bytes = await self.databaseBytes(db);
    return RevisionRetentionResult(
      removedCommits: result.removedCommits,
      removedCheckpoints: result.removedCheckpoints,
      removedAssets: result.removedAssets,
      keptFrom: result.keptFrom,
      databaseBytes: bytes,
    );
  }

  Future<RevisionRetentionResult> _pruneOnce(RawDatabase db, int keep) async {
    return db.transaction((txn) async {
      final head = await self.headId(txn);
      final idRows = await selectRows(
        txn,
        'revision_commit',
        columns: ['id'],
        orderBy: 'id',
      );
      final ids = [for (final row in idRows) row['id']! as int];
      if (ids.isEmpty) throw RevisionCorruption('提交历史为空');
      final named = await self.refs(txn);
      final namedCommits = {for (final ref in named) ref.commitId};
      final blocking = await _minimumBlockingPosition(txn);
      var oldest = ids.length <= keep ? ids.first : ids[ids.length - keep];
      if (blocking != null && blocking + 1 < oldest) oldest = blocking + 1;
      if (ids.length <= keep || oldest <= ids.first) {
        final projection = await self.readProjection(txn);
        return RevisionRetentionResult(
          removedCommits: 0,
          removedCheckpoints: 0,
          removedAssets: await _collectGarbage(txn, projection),
          keptFrom: ids.first,
          databaseBytes: await self.databaseBytes(txn),
        );
      }

      // 跨过下界的命名提交先固化检查点，再删除它下面的历史；已经固化过的
      // 不再重复写一份。
      final crossing = {
        for (final ref in named)
          if (ref.commitId < oldest) ref.commitId,
      };
      for (final commitId in crossing) {
        final existing = await selectRows(
          txn,
          'revision_checkpoint',
          columns: ['id'],
          where: 'kind = ? AND commit_id = ?',
          whereArgs: ['named', commitId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await self.materializeCheckpoint(txn, commitId, kind: 'named');
        }
      }

      final projection = await self.projectionAt(txn, oldest);
      // 下界没有前进时（例如阻塞位置停住）不重复写同一份基线检查点。
      final existingTrimmed = await selectRows(
        txn,
        'revision_checkpoint',
        columns: ['id'],
        where: 'kind = ? AND commit_id = ?',
        whereArgs: ['trimmed', oldest],
        limit: 1,
      );
      if (existingTrimmed.isEmpty) {
        await self._writeCheckpoint(
          txn,
          commitId: oldest,
          kind: 'trimmed',
          projection: projection,
        );
      }
      final verified = await self.projectionAt(txn, oldest);
      if (!self._sameProjection(projection, verified)) {
        throw RevisionCorruption('裁剪前的新基线校验失败，已取消本次清理');
      }

      final removedCommits = <int>[
        for (final id in ids)
          if (id < oldest && id != head && !namedCommits.contains(id)) id,
      ];
      // 只为计数的查询用 COUNT(*)：下界之前的非命名检查点都会被删掉。
      final removedCheckpoints = await _countRows(
        txn,
        'revision_checkpoint',
        where: 'commit_id < ? AND kind != ?',
        whereArgs: [oldest, 'named'],
      );

      // 引用表没有外键，删除提交或检查点时手工清掉对应的行；变更明细与外键
      // 级联不经过引用表。
      await deleteRows(
        txn,
        'revision_asset_ref',
        where: 'owner_kind = ? AND owner_id < ?',
        whereArgs: ['change', oldest],
      );
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
      for (final id in removedCommits) {
        await deleteRows(
          txn,
          'revision_commit',
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      // 被删掉的中间提交不再作为父提交；保留下来的提交父指针置空。
      await updateRow(
        txn,
        'revision_commit',
        {'parent_id': null},
        where: 'parent_id IS NOT NULL AND parent_id < ?',
        whereArgs: [oldest],
      );
      await _purgeOrphanAssetRefs(txn);

      final keptProjection = await self.readProjection(txn);
      return RevisionRetentionResult(
        removedCommits: removedCommits.length,
        removedCheckpoints: removedCheckpoints,
        removedAssets: await _collectGarbage(txn, keptProjection),
        keptFrom: oldest,
        databaseBytes: await self.databaseBytes(txn),
      );
    });
  }

  Future<int> _countRows(
    RawExecutor executor,
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final buffer = StringBuffer('SELECT COUNT(*) AS count FROM ');
    buffer.write(quoteSqlName(table));
    if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
    final rows = await executor.rawQuery(buffer.toString(), whereArgs);
    return rows.isEmpty ? 0 : (rows.first['count'] as int? ?? 0);
  }

  /// 仍然阻塞裁剪的最小读取位置。
  ///
  /// 与 [RevisionCursors.minimumBlockingPosition] 是同一条查询；part 文件共享
  /// 主文件里的 import，这里直接查库，口径与那边保持一致。
  Future<int?> _minimumBlockingPosition(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT MIN(position) AS position FROM revision_cursor WHERE blocking = 1',
    );
    return rows.isEmpty ? null : rows.first['position'] as int?;
  }

  /// 按容量预算一次算出保留条数：提交按 `byte_length` 求和，检查点按
  /// `length(payload)` 求和，剩余容量除以每条提交的平均字节数。
  Future<int> _keepForBudget(
    RawExecutor executor, {
    required int keepCommits,
    required int maxBytes,
  }) async {
    final commitRows = await executor.rawQuery(
      'SELECT COUNT(*) AS count, COALESCE(SUM(byte_length), 0) AS bytes '
      'FROM revision_commit',
    );
    final checkpointRows = await executor.rawQuery(
      'SELECT COALESCE(SUM(length(payload)), 0) AS bytes '
      'FROM revision_checkpoint',
    );
    int value(List<Map<String, Object?>> rows, String key) =>
        rows.isEmpty ? 0 : (rows.first[key] as int? ?? 0);
    final count = value(commitRows, 'count');
    final commitBytes = value(commitRows, 'bytes');
    final checkpointBytes = value(checkpointRows, 'bytes');
    final available = maxBytes - checkpointBytes;
    if (available <= 0) return 1;
    if (count <= 1 || commitBytes <= 0) return keepCommits;
    final perCommit = commitBytes / count;
    final allowed = (available / perCommit).floor();
    if (allowed >= keepCommits) return keepCommits;
    return allowed < 1 ? 1 : allowed;
  }

  /// 引用表里仍有主人的附件哈希：提交行或检查点行还在，引用才算数。
  Future<Set<String>> _referencedAssetHashes(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT DISTINCT hash FROM revision_asset_ref WHERE '
      "(owner_kind = 'change' AND owner_id IN "
      '(SELECT id FROM revision_commit)) OR '
      "(owner_kind = 'checkpoint' AND owner_id IN "
      '(SELECT id FROM revision_checkpoint))',
    );
    return {for (final row in rows) row['hash']! as String};
  }

  /// 删除没有主人的引用行；删除提交或检查点之后调用。
  Future<void> _purgeOrphanAssetRefs(RawExecutor executor) async {
    await executor.execute(
      'DELETE FROM revision_asset_ref WHERE '
      "(owner_kind = 'change' AND owner_id NOT IN "
      '(SELECT id FROM revision_commit)) OR '
      "(owner_kind = 'checkpoint' AND owner_id NOT IN "
      '(SELECT id FROM revision_checkpoint))',
    );
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

  /// 附件回收：当前投影的附件哈希加上引用表里仍有主人的哈希，其余对象删除。
  ///
  /// 引用表为空而检查点里仍有附件时不做回收：阶段 0 建表的库还没有写过引用
  /// 行，这时回收会删掉仍被历史引用的附件，宁可留下也不误删。
  Future<int> _collectGarbage(RawExecutor executor, Projection current) async {
    final objects = await self.assets.objectHashes(executor);
    if (objects.isEmpty) return 0;
    final referenced = await _referencedAssetHashes(executor);
    if (referenced.isEmpty) {
      final legacy = await executor.rawQuery(
        'SELECT 1 FROM revision_checkpoint '
        "WHERE asset_hashes_json NOT IN ('[]', '') LIMIT 1",
      );
      if (legacy.isNotEmpty) return 0;
    }
    final keep = <String>{
      ...AssetStore.hashesInProjection(current),
      ...referenced,
    };
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
  /// 引用来自 `revision_asset_ref` 里仍有主人的行与当前投影，不再解码全部变更
  /// 明细与检查点清单。备份时把整库带走，所以三类引用都要核对，缺任何一张都
  /// 算备份不完整。
  Future<List<String>> verifyAssets(RawExecutor executor) async {
    final all = <String>{...await _referencedAssetHashes(executor)};
    all.addAll(
      AssetStore.hashesInProjection(await self.readProjection(executor)),
    );
    final missing = <String>[];
    for (final hash in all) {
      if (!await self.assets.verify(executor, hash)) missing.add(hash);
    }
    return missing;
  }
}
