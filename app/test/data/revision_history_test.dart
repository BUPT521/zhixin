import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

void main() {
  late TestRig rig;

  setUp(() async {
    rig = await openTestRig(engine: RevisionEngine(checkpointEvery: 3));
  });

  tearDown(() => rig.close());

  Future<Set<String>> lastTables() async {
    final head = await rig.engine.headId(rig.raw);
    return {
      for (final change in await rig.engine.changesFor(rig.raw, head))
        change.table,
    };
  }

  test('全部业务表的新增、修改、删除与级联都进入采集', () async {
    await updateRow(rig.db, 'profile', {'day_cutoff_hour': 5}, where: 'id = 1');
    expect(await lastTables(), {'profile'});

    const goal = 'goal-1';
    await insertRow(rig.db, 'learning_goal', {
      'id': goal,
      'title': '目标',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'learning_goal'});
    const material = 'mat-1';
    await insertRow(rig.db, 'material', {
      'id': material,
      'title': '材料',
      'kind': 'text',
      'goal_id': goal,
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'material'});
    await insertRow(rig.db, 'material_page', {
      'id': 'page-1',
      'material_id': material,
      'page_no': 1,
      'content': '第一页',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'material_page'});
    const conversation = 'conv-1';
    await insertRow(rig.db, 'conversation', {
      'id': conversation,
      'title': '讨论',
      'goal_id': goal,
      'material_id': material,
      'entry_kind': 'text',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'conversation'});
    await insertRow(rig.db, 'message', {
      'id': 'msg-1',
      'conversation_id': conversation,
      'role': 'user',
      'content': '问题',
      'created_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'message'});
    const studyPlan = 'plan-1';
    await insertRow(rig.db, 'study_plan', {
      'id': studyPlan,
      'material_id': material,
      'goal_id': goal,
      'conversation_id': conversation,
      'title': '计划',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'study_plan'});
    const planItem = 'item-1';
    await insertRow(rig.db, 'plan_item', {
      'id': planItem,
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
    await insertRow(rig.db, 'timetable_entry', {
      'id': 'entry-1',
      'weekday': 1,
      'start_time': '08:00',
      'end_time': '09:00',
      'title': '课',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(await lastTables(), {'timetable_entry'});
    final block = await insertRow(rig.db, 'schedule_block', {
      'id': 'block-1',
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
    const session = 'session-1';
    await insertRow(rig.db, 'study_session', {
      'id': session,
      'goal_id': goal,
      'plan_item_id': planItem,
      'started_at': '2026-11-10T10:00:00',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'study_session'});
    const attempt = 'attempt-1';
    await insertRow(rig.db, 'attempt', {
      'id': attempt,
      'conversation_id': conversation,
      'session_id': session,
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'attempt'});
    await insertRow(rig.db, 'assessment', {
      'id': 'assessment-1',
      'attempt_id': attempt,
      'kind': 'model',
      'result': '对',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'assessment'});
    await insertRow(rig.db, 'memory', {
      'id': 'memory-1',
      'kind': 'preference',
      'content': '先看定义',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    expect(await lastTables(), {'memory'});

    await deleteRows(
      rig.db,
      'conversation',
      where: 'id = ?',
      whereArgs: [conversation],
    );
    expect(
      await lastTables(),
      containsAll({'conversation', 'message', 'attempt', 'assessment'}),
    );
    expect(block, isPositive);
  });

  test('命名版本跨裁剪保留，附件不被提前回收', () async {
    const conversation = 'conv-1';
    await insertRow(rig.db, 'conversation', {
      'id': conversation,
      'title': '图片',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final bytes = Uint8List.fromList(List<int>.generate(300, (i) => i));
    final hash = AssetStore.hashBytes(bytes);
    await rig.db.transaction((txn) async {
      await rig.engine.assets.putBytes(txn, hash, bytes);
      await insertRow(txn, 'message', {
        'id': 'msg-1',
        'conversation_id': conversation,
        'role': 'user',
        'content': '',
        'image_paths_json': '["$hash"]',
        'created_at': '2026-11-10T09:00:00',
      });
    });
    final named = await rig.engine.headId(rig.raw);
    await rig.engine.nameCommit(rig.raw, named, name: '有图版本', note: '保留');
    await deleteRows(
      rig.db,
      'conversation',
      where: 'id = ?',
      whereArgs: [conversation],
    );
    for (var index = 0; index < 6; index++) {
      await insertRow(rig.db, 'memory', {
        'id': 'memory-${index + 1}',
        'kind': 'preference',
        'content': '第 $index 条',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10T10:00:00',
        'updated_at': '2026-11-10T10:00:00',
      });
    }
    final head = await rig.engine.headId(rig.raw);
    final result = await rig.engine.prune(rig.raw, keepCommits: 2);
    expect(result.removedCommits, greaterThan(0));
    expect(await rig.engine.headId(rig.raw), head);
    expect(await rig.engine.refs(rig.raw), hasLength(1));
    expect(await rig.engine.assets.verify(rig.raw, hash), isTrue);

    final projection = await rig.engine.projectionAt(rig.raw, named);
    expect(projection['conversation'], isNotEmpty);
    await rig.engine.restore(rig.raw, named, expectedHead: head);
    expect(await selectRows(rig.raw, 'conversation'), hasLength(1));
    expect(await rig.engine.assets.verify(rig.raw, hash), isTrue);
  });

  test('清理历史保留当前数据并重置为一条基线', () async {
    const goal = 'goal-1';
    await insertRow(rig.db, 'learning_goal', {
      'id': goal,
      'title': '保留',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await insertRow(rig.db, 'memory', {
      'id': 'memory-1',
      'kind': 'preference',
      'content': '保留记忆',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    await rig.engine.nameCommit(
      rig.raw,
      await rig.engine.headId(rig.raw),
      name: '命名',
    );
    final projection = await rig.engine.readProjection(rig.raw);
    await rig.engine.clearHistory(rig.raw);
    expect(await selectRows(rig.raw, 'revision_commit'), hasLength(1));
    expect(await selectRows(rig.raw, 'revision_change'), isEmpty);
    expect(
      await selectRows(
        rig.raw,
        'revision_ref',
        where: 'name != ?',
        whereArgs: ['HEAD'],
      ),
      isEmpty,
    );
    expect(await rig.engine.readProjection(rig.raw), projection);
    final head = await rig.engine.headId(rig.raw);
    expect(await rig.engine.projectionAt(rig.raw, head), projection);
    expect(
      await selectRows(
        rig.raw,
        'learning_goal',
        where: 'id = ?',
        whereArgs: [goal],
      ),
      hasLength(1),
    );
  });
}
