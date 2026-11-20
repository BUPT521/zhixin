import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_cursor.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

void main() {
  var memorySeq = 0;

  Future<int> addMemory(TestRig rig, String content) async {
    await insertRow(rig.db, 'memory', {
      'id': 'memory-${++memorySeq}',
      'kind': 'preference',
      'content': content,
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    return rig.engine.headId(rig.raw);
  }

  Future<String> addConversation(TestRig rig, String id) async {
    await insertRow(rig.db, 'conversation', {
      'id': id,
      'title': '图片',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    return id;
  }

  Future<String> addImageMessage(
    TestRig rig, {
    required String id,
    required String conversationId,
    required Uint8List bytes,
  }) async {
    final hash = AssetStore.hashBytes(bytes);
    await rig.engine.assets.putBytes(rig.raw, hash, bytes);
    await insertRow(rig.db, 'message', {
      'id': id,
      'conversation_id': conversationId,
      'role': 'user',
      'content': '',
      'image_paths_json': '["$hash"]',
      'created_at': '2026-11-10T09:00:00',
    });
    return hash;
  }

  Future<int> countCheckpoints(RawExecutor executor, {String? kind}) async {
    final rows = await executor.rawQuery(
      kind == null
          ? 'SELECT COUNT(*) AS count FROM revision_checkpoint'
          : 'SELECT COUNT(*) AS count FROM revision_checkpoint WHERE kind = ?',
      kind == null ? null : [kind],
    );
    return rows.first['count']! as int;
  }

  Future<List<int>> commitIds(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      columns: ['id'],
      orderBy: 'id',
    );
    return [for (final row in rows) row['id']! as int];
  }

  test('阻塞的同步位置限制裁剪下界，位置之后的提交全部保留', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    for (var index = 0; index < 100; index++) {
      await addMemory(rig, '记忆 $index');
    }
    final head = await rig.engine.headId(rig.raw);
    expect(head, 100);
    await RevisionCursors(rig.raw)
        .set(RevisionCursor.syncPushed, 40, blocking: true);

    // 按保留条数会留到第 91 条；同步只推送到第 40 条，下界因此取 41。
    final result = await rig.engine.prune(rig.raw, keepCommits: 10);
    expect(result.keptFrom, 41);
    expect(result.removedCommits, greaterThan(0));
    expect(await commitIds(rig.raw), [for (var id = 41; id <= head; id++) id]);
    // 第 41 条之后一条不少。
    final kept = (await commitIds(rig.raw)).toSet();
    for (var id = 41; id <= head; id++) {
      expect(kept, contains(id));
    }
    // 同步位置本身不随裁剪前进或回退。
    final cursor = await RevisionCursors(rig.raw)
        .read(RevisionCursor.syncPushed);
    expect(cursor!.position, 40);
    expect(cursor.blocking, isTrue);

    // 位置停住时再次裁剪不再删提交，也不重复写基线检查点。
    final checkpoints = await countCheckpoints(rig.raw);
    final again = await rig.engine.prune(rig.raw, keepCommits: 10);
    expect(again.removedCommits, 0);
    expect(await countCheckpoints(rig.raw), checkpoints);
  });

  test('有阻塞位置时清理历史被拒绝并给出原因', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    for (var index = 0; index < 3; index++) {
      await addMemory(rig, '记忆 $index');
    }
    await RevisionCursors(rig.raw)
        .set(RevisionCursor.syncPushed, 1, blocking: true);

    final reasons = await rig.revisions.historyBlockers(clearing: true);
    expect(reasons, hasLength(1));
    expect(reasons.single, contains('2 条修改没有同步到云端'));

    await expectLater(
      rig.revisions.clearHistory(),
      throwsA(
        isA<RevisionBlocked>().having(
          (error) => error.reasons,
          'reasons',
          contains(contains('先同步再清理')),
        ),
      ),
    );
    // 拒绝之后历史原样保留。
    expect(await commitIds(rig.raw), [0, 1, 2, 3]);
    expect(await countCheckpoints(rig.raw), 1);

    // 引擎入口同样拒绝。
    await expectLater(
      rig.engine.clearHistory(rig.raw),
      throwsA(isA<RevisionBlocked>()),
    );

    // 裁剪不受阻止，只把下界提前到读取位置之后。
    final pruned = await rig.engine.prune(rig.raw, keepCommits: 1);
    expect(pruned.keptFrom, 2);
    expect(await commitIds(rig.raw), [2, 3]);
  });

  test('清理历史不回退提交编号', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    for (var index = 0; index < 3; index++) {
      await addMemory(rig, '记忆 $index');
    }
    // 只预留编号、没有净变化的命令也占一个编号，清理历史不能把它退回去复用。
    await rig.db.command(
      (txn) => rig.engine.reserveCommitId(txn),
      label: '预留编号',
    );
    final sequence = await selectRows(rig.raw, 'revision_sequence');
    final maxReserved = (sequence.single['next_commit']! as int) - 1;
    expect(maxReserved, greaterThan(await rig.engine.headId(rig.raw)));

    await rig.engine.clearHistory(rig.raw);
    final next = await addMemory(rig, '清理之后');
    expect(next, greaterThan(maxReserved));
  });

  test('附件回收结果与旧算法一致', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final conversation = await addConversation(rig, 'conv-1');
    final bytesA = Uint8List.fromList(List<int>.generate(200, (i) => i));
    final bytesB = Uint8List.fromList(List<int>.generate(180, (i) => i + 1));
    final bytesC = Uint8List.fromList(List<int>.generate(160, (i) => i + 2));
    final hashA = await addImageMessage(
      rig,
      id: 'msg-a',
      conversationId: conversation,
      bytes: bytesA,
    );
    final hashB = await addImageMessage(
      rig,
      id: 'msg-b',
      conversationId: conversation,
      bytes: bytesB,
    );
    await rig.engine.nameCommit(
      rig.raw,
      await rig.engine.headId(rig.raw),
      name: '有图版本',
    );
    await deleteRows(rig.db, 'message', where: 'id = ?', whereArgs: ['msg-a']);
    final hashC = await addImageMessage(
      rig,
      id: 'msg-c',
      conversationId: conversation,
      bytes: bytesC,
    );
    await deleteRows(rig.db, 'message', where: 'id = ?', whereArgs: ['msg-c']);
    for (var index = 0; index < 4; index++) {
      await addMemory(rig, '后续 $index');
    }
    final all = {hashA, hashB, hashC};
    expect(await rig.engine.assets.objectHashes(rig.raw), all);

    final result = await rig.engine.prune(rig.raw, keepCommits: 2);
    expect(result.removedCommits, greaterThan(0));
    // 只有新基线之前的初始检查点被删，跨界的命名检查点与新基线不计入。
    expect(result.removedCheckpoints, 1);
    // C 只被裁掉的提交引用；A、B 由命名检查点保留。
    final oldKeep = await _oldAlgorithmKeep(rig);
    expect(oldKeep, {hashA, hashB});
    final remaining = await rig.engine.assets.objectHashes(rig.raw);
    // 回收之后剩下的正是旧算法算出的 keep 集合里的对象。
    expect(remaining, all.intersection(oldKeep));
    expect(all.difference(remaining), {hashC});
    expect(remaining, {hashA, hashB});
    expect(result.removedAssets, 1);
    // 新算法读引用表，得到的保留集合与旧算法一致。
    expect(await _referenceKeep(rig), oldKeep);
  });

  test('按容量裁剪只执行一次 VACUUM', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    for (var index = 0; index < 30; index++) {
      await addMemory(rig, '记忆 $index');
    }
    final counted = VacuumCountingDatabase(rig.raw);
    final result = await rig.engine.prune(
      counted,
      keepCommits: 1000,
      maxBytes: 1,
    );
    expect(counted.vacuumCount, 1);
    expect(result.removedCommits, greaterThan(0));
    expect(await selectRows(rig.raw, 'revision_commit'), hasLength(1));

    // 预算宽裕时不再压缩。
    await rig.engine.prune(
      counted,
      keepCommits: 1000,
      maxBytes: 10 * 1024 * 1024,
    );
    expect(counted.vacuumCount, 1);
  });

  test('命名不写检查点，裁剪跨过命名提交后固化并可恢复', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await addMemory(rig, '第一');
    await addMemory(rig, '第二');
    final namedCommit = await rig.engine.headId(rig.raw);
    final namedProjection = await rig.engine.projectionAt(rig.raw, namedCommit);
    final checkpointsBefore = await countCheckpoints(rig.raw);
    await rig.engine.nameCommit(rig.raw, namedCommit, name: '命名版本');
    // 命名只写名称，不立即固化检查点。
    expect(await countCheckpoints(rig.raw), checkpointsBefore);
    expect(await countCheckpoints(rig.raw, kind: 'named'), 0);

    for (var index = 0; index < 6; index++) {
      await addMemory(rig, '后续 $index');
    }
    final head = await rig.engine.headId(rig.raw);
    final result = await rig.engine.prune(rig.raw, keepCommits: 2);
    expect(result.removedCommits, greaterThan(0));
    expect(result.keptFrom, 7);
    // 跨过下界的命名提交多出一份 named 检查点。
    expect(await countCheckpoints(rig.raw, kind: 'named'), 1);
    expect(await countCheckpoints(rig.raw), checkpointsBefore + 1);

    // 命名提交的提交行还在，能按命名检查点重建。
    final rebuilt = await rig.engine.projectionAt(rig.raw, namedCommit);
    expect(rebuilt, namedProjection);

    await rig.engine.restore(rig.raw, namedCommit, expectedHead: head);
    expect(await rig.engine.readProjection(rig.raw), namedProjection);
    final memories = await selectRows(
      rig.raw,
      'memory',
      columns: ['content'],
      orderBy: 'content',
    );
    expect([for (final row in memories) row['content']], ['第一', '第二']);
  });

  test('删除命名版本只删固化后的检查点', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await addMemory(rig, '第一');
    await addMemory(rig, '第二');
    final namedCommit = await rig.engine.headId(rig.raw);
    await rig.engine.nameCommit(rig.raw, namedCommit, name: '命名版本');
    final before = await countCheckpoints(rig.raw);
    // 还没固化时删除名称，检查点不动。
    await rig.engine.deleteName(rig.raw, '命名版本');
    expect(await countCheckpoints(rig.raw), before);
    expect(
      await selectRows(
        rig.raw,
        'revision_ref',
        where: 'name = ?',
        whereArgs: ['命名版本'],
      ),
      isEmpty,
    );

    await rig.engine.nameCommit(rig.raw, namedCommit, name: '命名版本');
    for (var index = 0; index < 6; index++) {
      await addMemory(rig, '后续 $index');
    }
    await rig.engine.prune(rig.raw, keepCommits: 2);
    expect(await countCheckpoints(rig.raw, kind: 'named'), 1);
    await rig.engine.deleteName(rig.raw, '命名版本');
    expect(await countCheckpoints(rig.raw, kind: 'named'), 0);
  });
}

/// 旧算法的 keep 集合：当前投影、全部检查点清单与全部变更明细的附件哈希。
Future<Set<String>> _oldAlgorithmKeep(TestRig rig) async {
  final keep = <String>{
    ...AssetStore.hashesInProjection(await rig.engine.readProjection(rig.raw)),
  };
  final checkpoints = await selectRows(
    rig.raw,
    'revision_checkpoint',
    columns: ['asset_hashes_json'],
  );
  for (final row in checkpoints) {
    keep.addAll(decodeStringList(row['asset_hashes_json'] as String? ?? '[]'));
  }
  final changes = await selectRows(rig.raw, 'revision_change');
  for (final row in changes) {
    keep.addAll(AssetStore.hashesInChanges([RevisionChange.fromRow(row)]));
  }
  return keep;
}

/// 新算法的 keep 集合：当前投影加上引用表里仍有主人的哈希。
Future<Set<String>> _referenceKeep(TestRig rig) async {
  final keep = <String>{
    ...AssetStore.hashesInProjection(await rig.engine.readProjection(rig.raw)),
  };
  final rows = await rig.raw.rawQuery(
    'SELECT DISTINCT hash FROM revision_asset_ref WHERE '
    "(owner_kind = 'change' AND owner_id IN "
    '(SELECT id FROM revision_commit)) OR '
    "(owner_kind = 'checkpoint' AND owner_id IN "
    '(SELECT id FROM revision_checkpoint))',
  );
  keep.addAll([for (final row in rows) row['hash']! as String]);
  return keep;
}

/// 记下 `VACUUM` 执行次数的执行器包装；裁剪只应压缩一次。
class VacuumCountingDatabase implements RawDatabase {
  VacuumCountingDatabase(this._inner);

  final RawDatabase _inner;
  int vacuumCount = 0;

  void _record(String sql) {
    if (sql.trimLeft().toUpperCase().startsWith('VACUUM')) vacuumCount++;
  }

  @override
  DatabaseConnectionUser? get driftConnection => _inner.driftConnection;

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) {
    _record(sql);
    return _inner.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    _record(sql);
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      _inner.selectGenerated(query);

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      _inner.writeGenerated(query);

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) =>
      _inner.transaction((txn) => action(_CountingExecutor(txn, _record)));

  @override
  Future<void> close() => _inner.close();
}

class _CountingExecutor implements RawExecutor {
  _CountingExecutor(this._inner, this._record);

  final RawExecutor _inner;
  final void Function(String sql) _record;

  @override
  DatabaseConnectionUser? get driftConnection => _inner.driftConnection;

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) {
    _record(sql);
    return _inner.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    _record(sql);
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      _inner.selectGenerated(query);

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      _inner.writeGenerated(query);
}
