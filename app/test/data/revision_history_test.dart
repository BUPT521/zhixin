import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database raw;
  late GuardedDatabase db;
  late RevisionEngine engine;

  setUp(() async {
    raw = await openTestDb();
    engine = RevisionEngine(checkpointEvery: 3);
    db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
  });

  tearDown(() async {
    await raw.close();
  });

  Future<Set<String>> lastTables() async {
    final head = await engine.headId(raw);
    return {
      for (final change in await engine.changesFor(raw, head)) change.table,
    };
  }

  test('全部业务表的新增、修改、删除与级联都进入采集', () async {
    await db.update('profile', {'day_cutoff_hour': 5}, where: 'id = 1');
    expect(await lastTables(), {'profile'});

    final goal = await db.insert('learning_goal', {
      'title': '目标',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'learning_goal'});
    final material = await db.insert('material', {
      'title': '材料',
      'kind': 'text',
      'goal_id': goal,
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'material'});
    await db.insert('material_page', {
      'material_id': material,
      'page_no': 1,
      'content': '第一页',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'material_page'});
    final conversation = await db.insert('conversation', {
      'title': '讨论',
      'goal_id': goal,
      'material_id': material,
      'entry_kind': 'text',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'conversation'});
    await db.insert('message', {
      'conversation_id': conversation,
      'role': 'user',
      'content': '问题',
      'created_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'message'});
    final studyPlan = await db.insert('study_plan', {
      'material_id': material,
      'goal_id': goal,
      'conversation_id': conversation,
      'title': '计划',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'study_plan'});
    final planItem = await db.insert('plan_item', {
      'goal_id': goal,
      'conversation_id': conversation,
      'study_plan_id': studyPlan,
      'seq': 1,
      'title': '步骤',
      'status': 'todo',
      'source': 'user',
      'priority': 0,
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'plan_item'});
    await db.insert('timetable_entry', {
      'weekday': 1,
      'start_time': '08:00',
      'end_time': '09:00',
      'title': '课',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'timetable_entry'});
    final block = await db.insert('schedule_block', {
      'plan_item_id': planItem,
      'start_at': '2026-11-10T10:00:00',
      'end_at': '2026-11-10T11:00:00',
      'source': 'user',
      'status': 'planned',
      'locked': 0,
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'schedule_block'});
    final session = await db.insert('study_session', {
      'goal_id': goal,
      'plan_item_id': planItem,
      'started_at': '2026-11-10T10:00:00',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'study_session'});
    final attempt = await db.insert('attempt', {
      'conversation_id': conversation,
      'session_id': session,
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'attempt'});
    await db.insert('assessment', {
      'attempt_id': attempt,
      'kind': 'model',
      'result': '对',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'assessment'});
    await db.insert('memory', {
      'kind': 'preference',
      'content': '先看定义',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'memory'});

    await db.delete('conversation', where: 'id = ?', whereArgs: [conversation]);
    expect(
      await lastTables(),
      containsAll({'conversation', 'message', 'attempt', 'assessment'}),
    );
    expect(block, isPositive);
  });

  test('命名版本跨裁剪保留，附件不被提前回收', () async {
    final conversation = await db.insert('conversation', {
      'title': '图片',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final bytes = Uint8List.fromList(List<int>.generate(300, (i) => i));
    final hash = AssetStore.hashBytes(bytes);
    await db.transaction((txn) async {
      await engine.assets.putBytes(txn, hash, bytes);
      await txn.insert('message', {
        'conversation_id': conversation,
        'role': 'user',
        'content': '',
        'image_paths_json': '["$hash"]',
        'created_at': '2026-11-10T09:00:00',
      });
    });
    final named = await engine.headId(raw);
    await engine.nameCommit(raw, named, name: '有图版本', note: '保留');
    await db.delete('conversation', where: 'id = ?', whereArgs: [conversation]);
    for (var index = 0; index < 6; index++) {
      await db.insert('memory', {
        'kind': 'preference',
        'content': '第 $index 条',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10T10:00:00',
        'updated_at': '2026-11-10T10:00:00',
      });
    }
    final head = await engine.headId(raw);
    final result = await engine.prune(raw, keepCommits: 2);
    expect(result.removedCommits, greaterThan(0));
    expect(await engine.headId(raw), head);
    expect(await engine.refs(raw), hasLength(1));
    expect(await engine.assets.verify(raw, hash), isTrue);

    final projection = await engine.projectionAt(raw, named);
    expect(projection['conversation'], isNotEmpty);
    await engine.restore(raw, named, expectedHead: head);
    expect(await raw.query('conversation'), hasLength(1));
    expect(await engine.assets.verify(raw, hash), isTrue);
  });

  test('清理历史保留当前数据并重置为一条基线', () async {
    final goal = await db.insert('learning_goal', {
      'title': '保留',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await db.insert('memory', {
      'kind': 'preference',
      'content': '保留记忆',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await engine.nameCommit(raw, await engine.headId(raw), name: '命名');
    final projection = await engine.readProjection(raw);
    await engine.clearHistory(raw);
    expect(await raw.query('revision_commit'), hasLength(1));
    expect(await raw.query('revision_change'), isEmpty);
    expect(
      await raw.query('revision_ref', where: 'name != ?', whereArgs: ['HEAD']),
      isEmpty,
    );
    expect(await engine.readProjection(raw), projection);
    final head = await engine.headId(raw);
    expect(await engine.projectionAt(raw, head), projection);
    expect(
      await raw.query('learning_goal', where: 'id = ?', whereArgs: [goal]),
      hasLength(1),
    );
  });
}
