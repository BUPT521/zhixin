import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late TestRig rig;

  late ScheduleRepository schedule;
  late TaskRepository tasks;
  late PlanService plan;
  late int dataChanges;

  setUp(() async {
    dataChanges = 0;
    rig = await openTestRig(
      clock: () => DateTime(2026, 11, 10, 10),
      onDataChanged: () async {
        dataChanges++;
      },
    );
    schedule = ScheduleRepository(rig.db);
    tasks = TaskRepository(rig.db);
    plan = PlanService(
      tasks: tasks,
      schedule: schedule,
      revisions: rig.revisions,
      runtime: testRuntime(
        policy: () => TimePolicy(clock: () => DateTime(2026, 11, 10, 10)),
      ),
      studyPlans: StudyPlanRepository(rig.db),
      transactions: WriteTransactions(rig.db),
    );
  });

  tearDown(() async {
    await rig.close();
  });

  Future<int> item(String title, {int? planId, int? seq}) async {
    return rig.db.insert('plan_item', {
      'study_plan_id': planId,
      'seq': seq,
      'title': title,
      'status': 'todo',
      'source': 'user',
      'priority': 0,
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
  }

  Future<int> block(int planItemId, int hour) {
    return schedule.addBlock(
      planItemId: planItemId,
      start: DateTime(2026, 11, 11, hour),
      end: DateTime(2026, 11, 11, hour + 1),
    );
  }

  Future<({int a, int b})> twoBlocks() async {
    final first = await item('第一项');
    final second = await item('第二项');
    return (a: await block(first, 9), b: await block(second, 11));
  }

  test('一次动作调整多条预约后整组撤销', () async {
    final ids = await twoBlocks();
    final commit = await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: ids.a,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
      ScheduleAdjustment(
        id: ids.b,
        start: DateTime(2026, 11, 11, 15),
        end: DateTime(2026, 11, 11, 16),
      ),
    ]);
    // 界面拿这次写入返回的提交编号撤销，不再从历史里取最近一条。
    expect(commit, await rig.engine.headId(rig.raw));
    final moved = await schedule.blocksBetween(
      DateTime(2026, 11, 11),
      DateTime(2026, 11, 12),
    );
    expect(moved.map((item) => item.block.startAt.hour), containsAll([13, 15]));

    final result = await rig.revisions.undoCommit(commit);
    expect(result.applied, isTrue, reason: result.message);
    // 撤销改了当前数据，应用根要据此推进代次并让三栏重读。
    expect(dataChanges, 1);
    final restored = await schedule.blocksBetween(
      DateTime(2026, 11, 11),
      DateTime(2026, 11, 12),
    );
    expect(
      {for (final item in restored) item.block.id: item.block.startAt.hour},
      {ids.a: 9, ids.b: 11},
    );
  });

  test('事项完成之后不再撤销这次改期', () async {
    final planItemId = await item('完成后再撤销');
    final blockId = await block(planItemId, 9);
    final commit = await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: blockId,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
    ]);
    await rig.db.update(
      'plan_item',
      {'status': 'done', 'updated_at': '2026-11-10T12:00:00'},
      where: 'id = ?',
      whereArgs: [planItemId],
    );

    final result = await rig.revisions.undoCommit(commit);
    expect(result.applied, isFalse);
    expect(result.message, contains('已经完成或暂缓'));
    final blocks = await schedule.blocksBetween(
      DateTime(2026, 11, 11),
      DateTime(2026, 11, 12),
    );
    expect(blocks.single.block.startAt.hour, 13);
  });

  test('取消、固定与删除预约各自可以撤销', () async {
    final planItemId = await item('预约状态可撤销');
    final blockId = await block(planItemId, 9);

    final cancelled = await plan.setBlockStatus(blockId, 'cancelled');
    expect((await schedule.blockById(blockId))!.status, 'cancelled');
    expect((await rig.revisions.undoCommit(cancelled)).applied, isTrue);
    expect((await schedule.blockById(blockId))!.status, 'planned');

    final locked = await plan.setBlockLocked(blockId, true);
    expect((await schedule.blockById(blockId))!.locked, isTrue);
    expect((await rig.revisions.undoCommit(locked)).applied, isTrue);
    expect((await schedule.blockById(blockId))!.locked, isFalse);

    final deleted = await plan.deleteBlock(blockId);
    expect(await schedule.blockById(blockId), isNull);
    expect((await rig.revisions.undoCommit(deleted)).applied, isTrue);
    expect((await schedule.blockById(blockId))!.startAt.hour, 9);
  });

  test('删除课表可以撤销，恢复时核对预约冲突', () async {
    await plan.addTimetable(
      weekday: 3,
      startTime: '08:00',
      endTime: '09:00',
      title: '数据结构',
    );
    final timetableId =
        (await rig.raw.query('timetable_entry')).single['id']! as int;
    final commit = await plan.deleteTimetable(timetableId);
    expect(await rig.raw.query('timetable_entry'), isEmpty);

    final undone = await rig.revisions.undoCommit(commit);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await rig.raw.query('timetable_entry')).single['title'], '数据结构');

    // 再次删除后，有一项待开始预约落在这一节课上，撤销删除应被拒绝。
    final again = await plan.deleteTimetable(timetableId);
    final itemId = await item('与课冲突的复习');
    await schedule.addBlock(
      planItemId: itemId,
      start: DateTime(2026, 11, 11, 8),
      end: DateTime(2026, 11, 11, 9),
    );
    final blocked = await rig.revisions.undoCommit(again);
    expect(blocked.applied, isFalse);
    expect(blocked.message, contains('冲突'));
    expect(await rig.raw.query('timetable_entry'), isEmpty);
  });

  test('单条预约返回自己的提交编号，撤销后这次预约删除', () async {
    final planItemId = await item('单条预约');
    final commit = await plan.scheduleItem(
      planItemId: planItemId,
      start: DateTime(2026, 11, 11, 9),
      end: DateTime(2026, 11, 11, 10),
    );
    // 提示条拿这次写入的编号撤销，不需要再从提交历史里找最近一条。
    expect(commit, await rig.engine.headId(rig.raw));
    expect(
      await schedule.blocksBetween(
        DateTime(2026, 11, 11),
        DateTime(2026, 11, 12),
      ),
      hasLength(1),
    );
    final result = await rig.revisions.undoCommit(commit);
    expect(result.applied, isTrue, reason: result.message);
    expect(
      await schedule.blocksBetween(
        DateTime(2026, 11, 11),
        DateTime(2026, 11, 12),
      ),
      isEmpty,
    );
  });

  test('字段改走又改回仍判定撤销冲突，整组保持当前值', () async {
    final ids = await twoBlocks();
    await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: ids.a,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
      ScheduleAdjustment(
        id: ids.b,
        start: DateTime(2026, 11, 11, 15),
        end: DateTime(2026, 11, 11, 16),
      ),
    ]);
    final target = await rig.engine.headId(rig.raw);
    await plan.moveBlock(
      ids.a,
      start: DateTime(2026, 11, 11, 16),
      end: DateTime(2026, 11, 11, 17),
    );
    await plan.moveBlock(
      ids.a,
      start: DateTime(2026, 11, 11, 13),
      end: DateTime(2026, 11, 11, 14),
    );
    final head = await rig.engine.headId(rig.raw);
    final result = await rig.revisions.undoCommit(target);
    expect(result.applied, isFalse);
    expect(result.message, contains('又被修改'));
    expect(await rig.engine.headId(rig.raw), head);
    final a = await schedule.blockById(ids.a);
    final b = await schedule.blockById(ids.b);
    expect(a!.startAt.hour, 13);
    expect(b!.startAt.hour, 15);
  });

  test('恢复后与后续预约冲突时整组驳回', () async {
    final ids = await twoBlocks();
    await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: ids.a,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
      ScheduleAdjustment(
        id: ids.b,
        start: DateTime(2026, 11, 11, 15),
        end: DateTime(2026, 11, 11, 16),
      ),
    ]);
    final target = await rig.engine.headId(rig.raw);
    final blocker = await item('后来插入');
    await block(blocker, 9);
    final head = await rig.engine.headId(rig.raw);
    final result = await rig.revisions.undoCommit(target);
    expect(result.applied, isFalse);
    expect(result.message, contains('冲突'));
    expect(await rig.engine.headId(rig.raw), head);
    expect((await schedule.blockById(ids.a))!.startAt.hour, 13);
    expect((await schedule.blockById(ids.b))!.startAt.hour, 15);
  });

  test('后续依赖被删除时撤销冲突，其余预约不受影响', () async {
    final ids = await twoBlocks();
    await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: ids.a,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
      ScheduleAdjustment(
        id: ids.b,
        start: DateTime(2026, 11, 11, 15),
        end: DateTime(2026, 11, 11, 16),
      ),
    ]);
    final target = await rig.engine.headId(rig.raw);
    final blockA = await schedule.blockById(ids.a);
    await rig.raw.delete(
      'plan_item',
      where: 'id = ?',
      whereArgs: [blockA!.planItemId],
    );
    final head = await rig.engine.headId(rig.raw);
    final result = await rig.revisions.undoCommit(target);
    expect(result.applied, isFalse);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await schedule.blockById(ids.a), isNull);
    expect((await schedule.blockById(ids.b))!.startAt.hour, 15);
  });

  test('整版恢复处理唯一键交换', () async {
    final planId = await rig.db.insert('study_plan', {
      'title': '交换顺序',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final first = await item('第一步', planId: planId, seq: 1);
    final second = await item('第二步', planId: planId, seq: 2);
    final before = await rig.engine.headId(rig.raw);
    await rig.db.transaction((txn) async {
      // 用临时序号避开唯一键，模拟用户把两步顺序互换。
      await txn.update(
        'plan_item',
        {'seq': 99},
        where: 'id = ?',
        whereArgs: [first],
      );
      await txn.update(
        'plan_item',
        {'seq': 1},
        where: 'id = ?',
        whereArgs: [second],
      );
      await txn.update(
        'plan_item',
        {'seq': 2},
        where: 'id = ?',
        whereArgs: [first],
      );
    });
    final current = await rig.engine.headId(rig.raw);
    expect(current, greaterThan(before));
    await rig.revisions.restore(before, expectedHead: current);
    // 版本恢复同样换了当前数据，代次与三栏要跟着推进。
    expect(dataChanges, 1);
    final rows = await rig.raw.query('plan_item', orderBy: 'seq');
    expect(rows.map((row) => row['id']), [first, second]);
    expect(rows.map((row) => row['seq']), [1, 2]);
  });

  test('预览后 HEAD 变化则拒绝恢复', () async {
    final ids = await twoBlocks();
    final target = await rig.engine.headId(rig.raw);
    final preview = await rig.revisions.previewRestore(target);
    await plan.moveBlock(
      ids.a,
      start: DateTime(2026, 11, 11, 17),
      end: DateTime(2026, 11, 11, 18),
    );
    await expectLater(
      rig.revisions.restore(target, expectedHead: preview.head),
      throwsA(isA<RevisionStaleHead>()),
    );
  });

  test('撤销提交本身不再进入撤销范围', () async {
    final ids = await twoBlocks();
    await plan.rescheduleGroup([
      ScheduleAdjustment(
        id: ids.a,
        start: DateTime(2026, 11, 11, 13),
        end: DateTime(2026, 11, 11, 14),
      ),
    ]);
    final target = await rig.engine.headId(rig.raw);
    final undone = await rig.revisions.undoCommit(target);
    expect(undone.applied, isTrue, reason: undone.message);
    final again = await rig.revisions.undoCommit(undone.commit!.id);
    expect(again.applied, isFalse);
    expect(again.message, contains('不能再撤销'));
  });

  test('提交列表按同一套规则给出不可撤销的原因', () async {
    await twoBlocks();
    final history = await rig.revisions.history();
    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[history.head], isNull);
    expect(reasons[0], '找不到要撤销的提交');

    // 课表已进入单项撤销白名单，这条新增可以撤销；撤销删除时会再核对预约。
    final timetable = await rig.engine.headId(rig.raw);
    final afterTimetable = await rig.revisions.history();
    final timetableReasons = await rig.revisions.undoBlockReasons(
      afterTimetable.commits,
    );
    expect(timetableReasons[timetable], isNull);

    // 撤销之后，目标提交与撤销提交本身都给出各自的原因。
    final undone = await rig.revisions.undoCommit(history.head);
    expect(undone.applied, isTrue, reason: undone.message);
    final afterUndo = await rig.revisions.history();
    final undoReasons = await rig.revisions.undoBlockReasons(afterUndo.commits);
    expect(undoReasons[history.head], '这次操作已经撤销');
    expect(undoReasons[undone.commit!.id], contains('不能再撤销'));

    // 整版恢复推进代次，恢复提交与更早的提交都不能按单项撤销。
    final restored = await rig.revisions.restore(
      undoReasons.keys.reduce((a, b) => a > b ? a : b),
      expectedHead: await rig.engine.headId(rig.raw),
    );
    final afterRestore = await rig.revisions.history();
    final restoreReasons = await rig.revisions.undoBlockReasons(
      afterRestore.commits,
    );
    expect(restoreReasons[restored.commit.id], '整版恢复请用恢复入口，不能按单项撤销处理');
    expect(restoreReasons[history.head], '整版恢复或导入之后，不能撤销更早的提交');
  });
}
