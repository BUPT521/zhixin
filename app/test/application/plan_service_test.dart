import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/domain/models/study.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

PlanService _service(TestRig rig, {required TimePolicy policy, Clock? clock}) {
  return PlanService(
    tasks: TaskRepository(rig.db),
    runtime: testRuntime(policy: () => policy),
    studyPlans: StudyPlanRepository(rig.db, clock: clock ?? systemClock),
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
  );
}

void main() {
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

    final week = await service.loadOverview();
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

  test('同参数的动作各起一个身份：新建目标两次是两条，重复状态按现值跳过', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 10, 10));
    final service = _service(rig, policy: policy);

    final first = await service.addGoal(title: '两次都写', scopeText: '整章');
    final head = await rig.engine.headId(rig.raw);
    // 参数完全相同的第二次是另一个动作：界面各起一个 uid，各自形成一条提交，
    // 不再有“同参数两分钟内算重试”的口径（ADR-0053 决定第 3 条）。
    final second = await service.addGoal(title: '两次都写', scopeText: '整章');
    expect(second.commitId, isNot(first.commitId));
    expect(await rig.engine.headId(rig.raw), greaterThan(head));
    expect(
      (await tasks.goals()).where((goal) => goal.title == '两次都写'),
      hasLength(2),
    );

    // 状态迁移不按 uid 去重：第二次改成同一状态没有净变化，按跳过返回。
    final item = await tasks.createItem(title: '改状态的一项');
    final done = await service.setStatus(item, PlanItemStatus.done);
    expect(done.changed, isTrue);
    final doneHead = await rig.engine.headId(rig.raw);
    final doneRetry = await service.setStatus(item, PlanItemStatus.done);
    expect(doneRetry.changed, isFalse);
    expect(await rig.engine.headId(rig.raw), doneHead);
  });
}
