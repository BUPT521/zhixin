import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

PlanService _service(TestRig rig, {required TimePolicy policy, Clock? clock}) {
  return PlanService(
    tasks: TaskRepository(rig.db),
    schedule: ScheduleRepository(rig.db),
    revisions: rig.revisions,
    runtime: testRuntime(policy: () => policy),
    studyPlans: StudyPlanRepository(rig.db, clock: clock ?? systemClock),
    transactions: WriteTransactions(rig.db),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('V2：暂停目标可以只取消该目标的弹性安排', () async {
    final rig = await openTestRig();
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

    final pauseId = await service.pauseGoal(goalA, cancelFlexibleFuture: true);
    expect(pauseId, isNotNull);

    expect((await tasks.goalById(goalA))!.status, LearningGoalStatus.paused);
    expect((await tasks.goalById(goalB))!.status, LearningGoalStatus.active);
    expect((await schedule.blockById(flexible))!.status, 'cancelled');
    expect((await schedule.blockById(fixed))!.status, 'planned');
    expect((await schedule.blockById(other))!.status, 'planned');
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
      transactions: WriteTransactions(rig.db),
    );
    await capacity.setWindow(start: '10:00', end: '11:00');
    final plan = await capacity.compute(days: 2);
    expect(plan.availableMinutes, 60);

    // 暂停目标的提交同时改了目标与预约，撤销后一起回到暂停前。
    final pause = await rig.engine.commitById(rig.db, pauseId!);
    expect(pause!.action, '暂停目标');
    final undone = await rig.revisions.undoCommit(pauseId);
    expect(undone.applied, isTrue);
    expect((await schedule.blockById(flexible))!.status, 'planned');
    expect((await tasks.goalById(goalA))!.status, LearningGoalStatus.active);
  });

  test('暂停目标时多条弹性安排一次取消，撤销后一起回到暂停前', () async {
    final rig = await openTestRig();
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

    final pauseId = await service.pauseGoal(goal, cancelFlexibleFuture: true);

    expect((await schedule.blockById(first))!.status, 'cancelled');
    expect((await schedule.blockById(second))!.status, 'cancelled');
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.paused);

    // 目标状态与两条取消落在同一条提交里，撤销一次全部恢复。
    final details = await rig.revisions.details(pauseId!);
    expect(details!.commit.action, '暂停目标');
    expect(details.changes, hasLength(3));
    final undone = await rig.revisions.undoCommit(pauseId);
    expect(undone.applied, isTrue);
    expect((await schedule.blockById(first))!.status, 'planned');
    expect((await schedule.blockById(second))!.status, 'planned');
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.active);
  });

  test('V2：不勾选取消时，暂停不改动任何未来安排', () async {
    final rig = await openTestRig();
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
    expect((await schedule.blockById(block))!.status, 'planned');
    expect((await tasks.goalById(goal))!.status, LearningGoalStatus.paused);
  });

  test('完成事项只把实际学习过的预约记为结束，没学的旧预约取消', () async {
    final rig = await openTestRig();
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
    await rig.raw.update(
      'study_session',
      {'started_at': formatDateTime(now.subtract(const Duration(minutes: 20)))},
      where: 'id = ?',
      whereArgs: [session.id],
    );

    await service.setStatus(item, PlanItemStatus.done);

    expect((await schedule.blockById(started))!.status, 'done');
    expect((await schedule.blockById(missed))!.status, 'cancelled');
    expect((await schedule.blockById(upcoming))!.status, 'cancelled');
  });

  test('安排页按自然周读取时间块，周一凌晨不回到上一周', () async {
    final rig = await openTestRig();
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
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final studyPlans = StudyPlanRepository(rig.db);
    final now = DateTime(2026, 11, 9, 12);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);

    final open = await tasks.createItem(title: '未完成的一项');
    final done = <int>[];
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
    final rig = await openTestRig();
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
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final now = DateTime(2026, 11, 9, 12);
    final policy = TimePolicy(clock: () => now);
    final service = _service(rig, policy: policy);
    final transactions = WriteTransactions(rig.db);

    for (var index = 0; index < 35; index++) {
      await transactions.run((txn) async {
        await memories.create(
          kind: MemoryKind.difficulty,
          content: '第 $index 条记忆',
          sourceKind: 'message',
          transaction: txn,
        );
      }, label: writeMemoryAction);
    }
    // 用户自己写的记忆不在这个列表里。
    await memories.create(
      kind: MemoryKind.preference,
      content: '自己记下的一条',
      sourceKind: 'user',
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
    final rig = await openTestRig();
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
      source: 'ai',
    );
    var blocks = await schedule.blocksForItem(item);
    expect(blocks.single.source, 'ai');

    await service.scheduleItem(
      planItemId: item,
      start: DateTime(2026, 11, 11, 11),
      end: DateTime(2026, 11, 11, 11, 30),
    );
    blocks = await schedule.blocksForItem(item);
    expect({for (final block in blocks) block.source}, {'ai', 'user'});
  });
}
