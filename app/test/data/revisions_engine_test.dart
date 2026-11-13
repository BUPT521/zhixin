import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late TestRig rig;

  setUp(() async {
    rig = await openTestRig();
  });

  tearDown(() => rig.close());

  test('普通写入形成一次带类型的净变化提交', () async {
    final id = await rig.db.insert('learning_goal', {
      'title': '复习线代',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final head = await rig.engine.headId(rig.db);
    expect(head, 1);
    final commit = await rig.engine.commitById(rig.db, head);
    expect(commit!.action, '数据写入');
    expect(commit.changeCount, 1);
    var changes = await rig.engine.changesFor(rig.db, head);
    expect(changes, hasLength(1));
    expect(changes.first.table, 'learning_goal');
    expect(changes.first.op, 'insert');
    expect(changes.first.after!['id']!.type, 'integer');
    expect(changes.first.after!['title']!.value, '复习线代');

    await rig.db.update(
      'learning_goal',
      {'title': '复习线性代数', 'updated_at': '2026-11-10T09:05:00'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final second = await rig.engine.headId(rig.db);
    expect(second, 2);
    changes = await rig.engine.changesFor(rig.db, second);
    expect(changes, hasLength(1));
    expect(changes.first.op, 'update');
    expect(changes.first.before!.keys, {'title', 'updated_at'});
    expect(changes.first.after!['title']!.value, '复习线性代数');
  });

  test('同一字段改走又改回仍保留两次提交', () async {
    final id = await rig.db.insert('learning_goal', {
      'title': 'A',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await rig.db.update(
      'learning_goal',
      {'title': 'B'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await rig.db.update(
      'learning_goal',
      {'title': 'A'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final changes = await rig.engine.changesFor(rig.db, 3);
    expect(changes.single.before!['title']!.value, 'B');
    expect(changes.single.after!['title']!.value, 'A');
  });

  test('命令事务失败时业务行、版本明细与 HEAD 一起回滚', () async {
    final before = await rig.engine.headId(rig.db);
    await expectLater(
      rig.db.transaction((txn) async {
        await txn.insert('learning_goal', {
          'title': '不会保留',
          'status': 'active',
          'created_at': '2026-11-10T09:00:00',
          'updated_at': '2026-11-10T09:00:00',
        });
        throw StateError('模拟写入中断');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await rig.engine.headId(rig.db), before);
    expect(await rig.db.query('learning_goal'), isEmpty);
    expect(
      await rig.db.query('revision_commit', where: 'id > ?', whereArgs: [0]),
      isEmpty,
    );
  });

  test('版本化表拒绝 REPLACE，避免旧行绕过删除采集', () async {
    expect(
      () => rig.db.insert('learning_goal', {
        'id': 1,
        'title': '替换',
        'status': 'active',
        'created_at': '2026-11-10T09:00:00',
        'updated_at': '2026-11-10T09:00:00',
      }, conflictAlgorithm: ConflictAlgorithm.replace),
      throwsArgumentError,
    );
    expect(
      () => rig.db.rawInsert(
        'INSERT OR REPLACE INTO learning_goal '
        '(id, title, status, created_at, updated_at) VALUES (1, ?, ?, ?, ?)',
        ['替换', 'active', '2026-11-10T09:00:00', '2026-11-10T09:00:00'],
      ),
      throwsArgumentError,
    );
    expect(await rig.db.query('learning_goal'), isEmpty);
  });

  test('同一请求编号重复提交返回原提交', () async {
    var calls = 0;
    final first = await rig.db.command(
      (txn) async {
        calls++;
        await txn.insert('memory', {
          'kind': 'preference',
          'content': '重试一次',
          'source_kind': 'user',
          'status': 'active',
          'created_at': '2026-11-10T09:00:00',
          'updated_at': '2026-11-10T09:00:00',
        });
        return 'first';
      },
      label: '写入记忆',
      requestId: 'retry-1',
    );
    final replay = await rig.db.command(
      (txn) async {
        calls++;
        return 'second';
      },
      label: '写入记忆',
      requestId: 'retry-1',
      onDuplicate: (commit) => 'replay:${commit.id}',
    );
    expect(first, 'first');
    expect(replay, startsWith('replay:'));
    expect(calls, 1);
    expect(await rig.raw.query('memory'), hasLength(1));
    final commit = await rig.engine.commitByRequest(rig.raw, 'retry-1');
    expect(commit, isNotNull);
    expect(await rig.engine.headId(rig.raw), commit!.id);
  });

  test('命令里能读到本次分配的提交编号，没有净变化时不形成提交', () async {
    final transactions = WriteTransactions(rig.db);
    int? insideId;
    await transactions.run((txn) async {
      insideId = await txn.commitId();
      await txn.executor.insert('memory', {
        'kind': 'preference',
        'content': '带回执',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10T09:00:00',
        'updated_at': '2026-11-10T09:00:00',
      });
    }, label: '写入记忆');
    final head = await rig.engine.headId(rig.raw);
    expect(insideId, head);

    final before = await rig.engine.headId(rig.raw);
    int? emptyId;
    await transactions.run((txn) async {
      emptyId = await txn.commitId();
      expect(emptyId, isNotNull);
    }, label: '只有回执');
    expect(await rig.engine.headId(rig.raw), before);
    expect(await rig.engine.commitById(rig.raw, emptyId!), isNull);
  });

  test('从检查点重建并与当前数据逐字段一致', () async {
    final id = await rig.db.insert('learning_goal', {
      'title': '目标',
      'scope_text': '第一章',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await rig.db.update(
      'learning_goal',
      {'scope_text': '第二章'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final projection = await rig.engine.projectionAt(rig.db, 2);
    final now = await rig.engine.readProjection(rig.db);
    expect(projection, now);
  });

  test('整版恢复追加提交，预览后 HEAD 变化会拒绝', () async {
    final id = await rig.db.insert('learning_goal', {
      'title': '恢复前',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final first = await rig.engine.headId(rig.db);
    await rig.db.update(
      'learning_goal',
      {'title': '恢复后'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final second = await rig.engine.headId(rig.db);
    await expectLater(
      rig.engine.restore(rig.db, first, expectedHead: first),
      throwsA(isA<RevisionStaleHead>()),
    );
    final commit = await rig.engine.restore(
      rig.db,
      first,
      expectedHead: second,
    );
    expect(commit.restoredCommitId, first);
    expect(commit.generation, 1);
    final rows = await rig.db.query('learning_goal');
    expect(rows.single['title'], '恢复前');
    expect(await rig.engine.headId(rig.db), commit.id);
  });
}
