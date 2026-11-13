import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database raw;
  late GuardedDatabase db;
  late RevisionEngine engine;

  setUp(() async {
    raw = await openTestDb();
    engine = RevisionEngine();
    db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
  });

  tearDown(() async {
    await raw.close();
  });

  test('普通写入形成一次带类型的净变化提交', () async {
    final id = await db.insert('learning_goal', {
      'title': '复习线代',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final head = await engine.headId(db);
    expect(head, 1);
    final commit = await engine.commitById(db, head);
    expect(commit!.action, '数据写入');
    expect(commit.changeCount, 1);
    var changes = await engine.changesFor(db, head);
    expect(changes, hasLength(1));
    expect(changes.first.table, 'learning_goal');
    expect(changes.first.op, 'insert');
    expect(changes.first.after!['id']!.type, 'integer');
    expect(changes.first.after!['title']!.value, '复习线代');

    await db.update(
      'learning_goal',
      {'title': '复习线性代数', 'updated_at': '2026-11-10T09:05:00'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final second = await engine.headId(db);
    expect(second, 2);
    changes = await engine.changesFor(db, second);
    expect(changes, hasLength(1));
    expect(changes.first.op, 'update');
    expect(changes.first.before!.keys, {'title', 'updated_at'});
    expect(changes.first.after!['title']!.value, '复习线性代数');
  });

  test('同一字段改走又改回仍保留两次提交', () async {
    final id = await db.insert('learning_goal', {
      'title': 'A',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await db.update(
      'learning_goal',
      {'title': 'B'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await db.update(
      'learning_goal',
      {'title': 'A'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final changes = await engine.changesFor(db, 3);
    expect(changes.single.before!['title']!.value, 'B');
    expect(changes.single.after!['title']!.value, 'A');
  });

  test('命令事务失败时业务行、版本明细与 HEAD 一起回滚', () async {
    final before = await engine.headId(db);
    await expectLater(
      db.transaction((txn) async {
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
    expect(await engine.headId(db), before);
    expect(await db.query('learning_goal'), isEmpty);
    expect(
      await db.query('revision_commit', where: 'id > ?', whereArgs: [0]),
      isEmpty,
    );
  });

  test('版本化表拒绝 REPLACE，避免旧行绕过删除采集', () async {
    expect(
      () => db.insert('learning_goal', {
        'id': 1,
        'title': '替换',
        'status': 'active',
        'created_at': '2026-11-10T09:00:00',
        'updated_at': '2026-11-10T09:00:00',
      }, conflictAlgorithm: ConflictAlgorithm.replace),
      throwsArgumentError,
    );
    expect(
      () => db.rawInsert(
        'INSERT OR REPLACE INTO learning_goal '
        '(id, title, status, created_at, updated_at) VALUES (1, ?, ?, ?, ?)',
        ['替换', 'active', '2026-11-10T09:00:00', '2026-11-10T09:00:00'],
      ),
      throwsArgumentError,
    );
    expect(await db.query('learning_goal'), isEmpty);
  });

  test('同一请求编号重复提交返回原提交', () async {
    var calls = 0;
    final first = await db.command(
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
    final replay = await db.command(
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
    expect(await raw.query('memory'), hasLength(1));
    final commit = await engine.commitByRequest(raw, 'retry-1');
    expect(commit, isNotNull);
    expect(await engine.headId(raw), commit!.id);
  });

  test('命令里能读到本次分配的提交编号，没有净变化时不形成提交', () async {
    final transactions = WriteTransactions(db);
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
    final head = await engine.headId(raw);
    expect(insideId, head);

    final before = await engine.headId(raw);
    int? emptyId;
    await transactions.run((txn) async {
      emptyId = await txn.commitId();
      expect(emptyId, isNotNull);
    }, label: '只有回执');
    expect(await engine.headId(raw), before);
    expect(await engine.commitById(raw, emptyId!), isNull);
  });

  test('从检查点重建并与当前数据逐字段一致', () async {
    final id = await db.insert('learning_goal', {
      'title': '目标',
      'scope_text': '第一章',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await db.update(
      'learning_goal',
      {'scope_text': '第二章'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final projection = await engine.projectionAt(db, 2);
    final now = await engine.readProjection(db);
    expect(projection, now);
  });

  test('整版恢复追加提交，预览后 HEAD 变化会拒绝', () async {
    final id = await db.insert('learning_goal', {
      'title': '恢复前',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final first = await engine.headId(db);
    await db.update(
      'learning_goal',
      {'title': '恢复后'},
      where: 'id = ?',
      whereArgs: [id],
    );
    final second = await engine.headId(db);
    await expectLater(
      engine.restore(db, first, expectedHead: first),
      throwsA(isA<RevisionStaleHead>()),
    );
    final commit = await engine.restore(db, first, expectedHead: second);
    expect(commit.restoredCommitId, first);
    expect(commit.generation, 1);
    final rows = await db.query('learning_goal');
    expect(rows.single['title'], '恢复前');
    expect(await engine.headId(db), commit.id);
  });
}
