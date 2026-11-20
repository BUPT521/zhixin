import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/capacity_service.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/time_format.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/domain/models/time_values.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

PlanService _service(TestRig rig, {required TimePolicy policy, Clock? clock}) {
  return PlanService(
    tasks: TaskRepository(rig.db),
    schedule: ScheduleRepository(rig.db),
    revisions: rig.revisions,
    runtime: testRuntime(policy: () => policy),
    studyPlans: StudyPlanRepository(rig.db, clock: clock ?? systemClock),
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
  );
}

void main() {
  test('V2：暂停目标可以只取消该目标的弹性安排', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final now = DateTime(2026, 11, 6, 18);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final goalA = await tasks.createGoal(title: '概率论期末');
    final goalB = await tasks.createGoal(title: '线性代数作业');
    final itemA = await tasks.createItem(title: '概率论作业', goalId: goalA);
    final itemATwo = await tasks.createItem(title: '概率论复习', goalId: goalA);
    final itemB = await tasks.createItem(title: '线代作业', goalId: goalB);
    final tomorrow = DateTime(2026, 11, 7, 10);
    final flexible = await schedule.addBlock(
      planItemId: itemA,
      start: tomorrow,
      end: tomorrow.add(const Duration(minutes: 30)),
    );
    final fixed = await schedule.addBlock(
      planItemId: itemATwo,
      start: tomorrow.add(const Duration(hours: 2)),
      end: tomorrow.add(const Duration(hours: 3)),
    );
    await schedule.setLocked(fixed, true);
    final other = await schedule.addBlock(
      planItemId: itemB,
      start: tomorrow.add(const Duration(hours: 4)),
      end: tomorrow.add(const Duration(hours: 5)),
    );

    expect(await service.flexibleFutureCount(goalA), 1);

    final pauseResult = await service.pauseGoal(
      goalA,
      cancelFlexibleFuture: true,
    );
    expect(pauseResult.commitId, isNotNull);
    final pauseId = pauseResult.commitId!;

    expect((await tasks.goalById(goalA))!.status, LearningGoalStatus.paused);
    expect((await tasks.goalById(goalB))!.status, LearningGoalStatus.active);
    expect(
      (await schedule.blockById(flexible))!.status,
      ScheduleBlockStatus.cancelled,
    );
    expect(
      (await schedule.blockById(fixed))!.status,
      ScheduleBlockStatus.planned,
    );
    expect(
      (await schedule.blockById(other))!.status,
      ScheduleBlockStatus.planned,
    );
    expect(
      (await tasks.items()).map((item) => item.status),
      everyElement(PlanItemStatus.todo),
    );

    // 取消的弹性块不再占用容量。
    final capacity = CapacityService(
      settings: SettingsRepository(rig.db),
      tasks: tasks,
      schedule: schedule,
      runtime: testRuntime(policy: () => policy),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
    );
    await capacity.setWindow(
      start: ClockTime.parse('10:00'),
      end: ClockTime.parse('11:00'),
    );
    final plan = await capacity.compute(days: 2);
    expect(plan.availableMinutes, 60);

    // 暂停目标的提交同时改了目标与预约，撤销后一起回到暂停前。
    final pause = await rig.engine.commitById(rig.db, pauseId);
    expect(pause!.action, '暂停目标');
    final undone = await rig.revisions.undoCommit(pauseId);
    expect(undone.applied, isTrue);
    expect(
      (await schedule.blockById(flexible))!.status,
      ScheduleBlockStatus.planned,
    );
    expect((await tasks.goalById(goalA))!.status, LearningGoalStatus.active);
  });

  test('暂停目标时多条弹性安排一次取消，撤销后一起回到暂停前', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final now = DateTime(2026, 11, 6, 18);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final goal = await tasks.createGoal(title: '概率论期末');
    final item = await tasks.createItem(title: '概率论作业', goalId: goal);
    final tomorrow = DateTime(2026, 11, 7, 10);
    final first = await schedule.addBlock(
      planItemId: item,
      start: tomorrow,
      end: tomorrow.add(const Duration(minutes: 30)),
    );
    final second = await schedule.addBlock(
      planItemId: item,
      start: tomorrow.add(const Duration(hours: 1)),
      end: tomorrow.add(const Duration(hours: 2)),
    );

    final pauseResult = await service.pauseGoal(
      goal,
      cancelFlexibleFuture: true,
    );
    final pauseId = pauseResult.commitId!;

    expect(
      (await schedule.blockById(first))!.status,
      ScheduleBlockStatus.cancelled,
    );
    expect(
      (await schedule.blockById(second))!.status,
      ScheduleBlockStatus.cancelled,
    );
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.paused);

    // 目标状态与两条取消落在同一条提交里，撤销一次全部恢复。
    final details = await rig.revisions.details(pauseId);
    expect(details!.commit.action, '暂停目标');
    expect(details.changes, hasLength(3));
    final undone = await rig.revisions.undoCommit(pauseId);
    expect(undone.applied, isTrue);
    expect(
      (await schedule.blockById(first))!.status,
      ScheduleBlockStatus.planned,
    );
    expect(
      (await schedule.blockById(second))!.status,
      ScheduleBlockStatus.planned,
    );
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.active);
  });

  test('V2：不勾选取消时，暂停不改动任何未来安排', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final now = DateTime(2026, 11, 6, 18);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final goal = await tasks.createGoal(title: '只暂停不改安排');
    final item = await tasks.createItem(title: '作业', goalId: goal);
    final tomorrow = DateTime(2026, 11, 7, 10);
    final block = await schedule.addBlock(
      planItemId: item,
      start: tomorrow,
      end: tomorrow.add(const Duration(minutes: 30)),
    );
    await service.pauseGoal(goal);
    expect(
      (await schedule.blockById(block))!.status,
      ScheduleBlockStatus.planned,
    );
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.paused);
  });

  test('完成事项只把实际学习过的预约记为结束，没学的旧预约取消', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final study = StudyRepository(rig.db);
    final now = DateTime(2026, 11, 6, 18);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy, clock: () => now);

    final item = await tasks.createItem(title: '整理错题');
    final missed = await schedule.addBlock(
      planItemId: item,
      start: now.subtract(const Duration(hours: 3)),
      end: now.subtract(const Duration(hours: 2)),
    );
    final started = await schedule.addBlock(
      planItemId: item,
      start: now.subtract(const Duration(minutes: 30)),
      end: now.add(const Duration(minutes: 30)),
    );
    final upcoming = await schedule.addBlock(
      planItemId: item,
      start: now.add(const Duration(hours: 2)),
      end: now.add(const Duration(hours: 3)),
    );
    // 只有第二段预约期间真的开过场次，第一段虽然到过开始时间却没有学习。
    final session = await study.start(planItemId: item, goalId: null);
    await updateRow(
      rig.raw,
      'study_session',
      {'started_at': formatDateTime(now.subtract(const Duration(minutes: 20)))},
      where: 'id = ?',
      whereArgs: [session.id],
    );

    await service.setStatus(item, PlanItemStatus.done);

    expect(
      (await schedule.blockById(started))!.status,
      ScheduleBlockStatus.done,
    );
    expect(
      (await schedule.blockById(missed))!.status,
      ScheduleBlockStatus.cancelled,
    );
    expect(
      (await schedule.blockById(upcoming))!.status,
      ScheduleBlockStatus.cancelled,
    );
  });

  test('安排页按自然周读取时间块，周一凌晨不回到上一周', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final now = DateTime(2026, 11, 9, 0, 56);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final item = await tasks.createItem(title: '复习');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 2, 10),
      end: DateTime(2026, 11, 2, 11),
    );
    final thisWeek = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 9, 10),
      end: DateTime(2026, 11, 9, 11),
    );

    final week = await service.loadWeek(now);

    expect(week.blocks.map((block) => block.block.id), [thisWeek]);
  });

  test('安排页默认只读未完成事项，已完成按页读取', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final studyPlans = StudyPlanRepository(rig.db);
    final now = DateTime(2026, 11, 9, 12);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final open = await tasks.createItem(title: '未完成的一项');
    final done = <String>[];
    for (var index = 0; index < 3; index++) {
      final id = await tasks.createItem(title: '已完成 $index');
      await studyPlans.setItemStatus(id, PlanItemStatus.done);
      done.add(id);
    }

    final week = await service.loadWeek(now);
    expect(week.items.map((item) => item.id), [open]);
    expect(week.doneItemCount, 3);

    final firstPage = await service.doneItems(limit: 2);
    final secondPage = await service.doneItems(limit: 2, offset: 2);
    expect(firstPage, hasLength(2));
    expect(secondPage, hasLength(1));
    expect(
      {...firstPage, ...secondPage}.map((item) => item.id).toSet(),
      done.toSet(),
    );
  });

  test('安排页只读未完成计划的步骤，已完成计划的摘要仍按计数显示', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final studyPlans = StudyPlanRepository(rig.db);
    final now = DateTime(2026, 11, 9, 12);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final openPlan = await studyPlans.createWithDrafts(
      title: '进行中的计划',
      drafts: const [
        StudyStepDraft(title: '第一步', pageFrom: 1, pageTo: 2),
        StudyStepDraft(title: '第二步', pageFrom: 3, pageTo: 4),
      ],
    );
    final donePlan = await studyPlans.createWithDrafts(
      title: '已完成的计划',
      drafts: const [StudyStepDraft(title: '唯一一步', pageFrom: 1, pageTo: 1)],
    );
    final doneSteps = await studyPlans.steps(donePlan);
    await studyPlans.setItemStatus(doneSteps.single.id, PlanItemStatus.done);

    final week = await service.loadWeek(now);
    final summaries = {
      for (final summary in week.studyPlans) summary.plan.id: summary,
    };

    expect(summaries[openPlan]!.nextStep!.title, '第一步');
    // 已完成计划不再读回步骤，下一步为空，进度仍由计划行的计数带出。
    expect(summaries[donePlan]!.nextStep, isNull);
    expect(summaries[donePlan]!.plan.progressLabel, contains('1/1 步'));
    expect(summaries[donePlan]!.plan.done, isTrue);
  });

  test('安排页保留并显示全部 AI 改动，不截断较早的记录', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final now = DateTime(2026, 11, 9, 12);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);

    for (var index = 0; index < 35; index++) {
      await transactions.run((txn) async {
        await memories.create(
          kind: MemoryKind.difficulty,
          content: '第 $index 条记忆',
          sourceKind: MemorySourceKind.message,
          transaction: txn,
        );
      }, label: writeMemoryAction);
    }
    // 用户自己写的记忆不在这个列表里。
    await memories.create(
      kind: MemoryKind.preference,
      content: '自己记下的一条',
      sourceKind: MemorySourceKind.user,
    );

    final week = await service.loadWeek(now);

    expect(week.operations, hasLength(35));
    expect(week.operations.first.id, 35);
    expect(week.operations.last.id, 1);
    expect(
      week.operations.every((commit) => commit.action == writeMemoryAction),
      isTrue,
    );
  });

  test('搭子建议的时间块记为搭子来源，默认仍是用户', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    final item = await tasks.createItem(title: '搭子建议的一步');
    await service.scheduleItem(
      planItemId: item,
      start: DateTime(2026, 11, 11, 9),
      end: DateTime(2026, 11, 11, 9, 30),
      source: PlanItemSource.ai,
    );
    var blocks = await schedule.blocksForItem(item);
    expect(blocks.single.source, PlanItemSource.ai);

    await service.scheduleItem(
      planItemId: item,
      start: DateTime(2026, 11, 11, 11),
      end: DateTime(2026, 11, 11, 11, 30),
    );
    blocks = await schedule.blocksForItem(item);
    expect(
      {for (final block in blocks) block.source},
      {PlanItemSource.ai, PlanItemSource.user},
    );
  });

  test('固定安排冲突时单条预约与改期都拒绝，也不生成提交', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    final fixedItem = await tasks.createItem(title: '固定复习');
    final fixed = await schedule.addBlock(
      planItemId: fixedItem,
      start: DateTime(2026, 11, 11, 9),
      end: DateTime(2026, 11, 11, 10),
    );
    await schedule.setLocked(fixed, true);
    final other = await tasks.createItem(title: '另一项');
    final head = await rig.engine.headId(rig.raw);

    // 新建的预约撞上固定安排：拒绝写入，提交历史不动。
    await expectLater(
      service.scheduleItem(
        planItemId: other,
        start: DateTime(2026, 11, 11, 9, 30),
        end: DateTime(2026, 11, 11, 10, 30),
      ),
      throwsA(isA<ScheduleConflictException>()),
    );
    expect(await schedule.blocksForItem(other), isEmpty);
    expect(await rig.engine.headId(rig.raw), head);

    // 改期撞上固定安排：原时间保持不变。
    final movable = await schedule.addBlock(
      planItemId: other,
      start: DateTime(2026, 11, 11, 13),
      end: DateTime(2026, 11, 11, 14),
    );
    final beforeMove = await rig.engine.headId(rig.raw);
    await expectLater(
      service.moveBlock(
        movable,
        start: DateTime(2026, 11, 11, 9, 30),
        end: DateTime(2026, 11, 11, 10, 30),
      ),
      throwsA(isA<ScheduleConflictException>()),
    );
    expect((await schedule.blockById(movable))!.startAt.hour, 13);
    expect(await rig.engine.headId(rig.raw), beforeMove);
  });

  test('整组顺延中任一条冲突时整组保持原样，也不生成提交', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    Future<String> block(String title, int hour) async {
      final item = await tasks.createItem(title: title);
      return schedule.addBlock(
        planItemId: item,
        start: DateTime(2026, 11, 11, hour),
        end: DateTime(2026, 11, 11, hour + 1),
      );
    }

    final first = await block('第一项', 9);
    final second = await block('第二项', 11);
    // 这一条不参与这次调整，但与第一项顺延之后的时间重叠。
    await block('第三项', 13);
    final head = await rig.engine.headId(rig.raw);

    await expectLater(
      service.rescheduleGroup([
        ScheduleAdjustment(
          id: first,
          start: DateTime(2026, 11, 11, 13, 30),
          end: DateTime(2026, 11, 11, 14, 30),
        ),
        ScheduleAdjustment(
          id: second,
          start: DateTime(2026, 11, 11, 15),
          end: DateTime(2026, 11, 11, 16),
        ),
      ]),
      throwsA(isA<ScheduleConflictException>()),
    );

    // 任一条冲突时整组不改，另一条也没有被写进去。
    expect((await schedule.blockById(first))!.startAt.hour, 9);
    expect((await schedule.blockById(second))!.startAt.hour, 11);
    expect(await rig.engine.headId(rig.raw), head);
  });

  test('一次改期只生成一条提交，撤销后回到原时间', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    final item = await tasks.createItem(title: '改期的一项');
    final id = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 11, 9),
      end: DateTime(2026, 11, 11, 10),
    );

    final moveResult = await service.moveBlock(
      id,
      start: DateTime(2026, 11, 11, 11),
      end: DateTime(2026, 11, 11, 12),
    );
    final commit = moveResult.commitId!;
    // 这次改期就是最新提交，提示条据此撤销，不会撤到别的动作。
    expect(commit, await rig.engine.headId(rig.raw));
    final details = await rig.revisions.details(commit);
    expect(details!.changes, hasLength(1));
    expect((await schedule.blockById(id))!.startAt.hour, 11);

    final undone = await rig.revisions.undoCommit(commit);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await schedule.blockById(id))!.startAt.hour, 9);
  });

  test('同一动作重试沿用原提交，不再写一遍', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    final first = await service.addGoal(title: '重试不重复', scopeText: '整章');
    final head = await rig.engine.headId(rig.raw);
    // 重试走同一个编号：返回原提交，目标只留一条。
    final retry = await service.addGoal(title: '重试不重复', scopeText: '整章');
    expect(retry.commitId, first.commitId);
    expect(await rig.engine.headId(rig.raw), head);
    expect(
      (await tasks.goals()).where((goal) => goal.title == '重试不重复'),
      hasLength(1),
    );

    final item = await tasks.createItem(title: '改状态的一项');
    final done = await service.setStatus(item, PlanItemStatus.done);
    expect(done.changed, isTrue);
    final doneHead = await rig.engine.headId(rig.raw);
    // 状态迁移不用编号去重，重试由事务内的状态比对跳过。
    final doneRetry = await service.setStatus(item, PlanItemStatus.done);
    expect(doneRetry.changed, isFalse);
    expect(await rig.engine.headId(rig.raw), doneHead);

    final block = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 11, 9),
      end: DateTime(2026, 11, 11, 10),
    );
    final cancel = await service.deleteBlock(block);
    final cancelRetry = await service.deleteBlock(block);
    expect(cancelRetry.commitId, cancel.commitId);
    expect(await schedule.blockById(block), isNull);
  });
}
