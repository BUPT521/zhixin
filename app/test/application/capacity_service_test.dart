import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/capacity_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/capacity.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _Harness {
  final DateTime now = DateTime(2026, 11, 6, 18);
  late TestRig rig;
  late RawDatabase db;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late CapacityService capacity;

  Future<void> open() async {
    rig = await openTestRig(clock: () => now);
    db = rig.raw;
    tasks = TaskRepository(rig.db.rawDb);
    schedule = ScheduleRepository(rig.db.rawDb);
    final policy = TimePolicy(clock: () => now);
    capacity = CapacityService(
      settings: SettingsRepository(rig.db.rawDb),
      tasks: tasks,
      schedule: schedule,
      runtime: testRuntime(policy: () => policy),
      transactions: WriteTransactions(rig.db),
    );
  }

  Future<void> close() => rig.close();
}

void main() {
  test('V5：按优先级与截止排顺序，给出粗略预算', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '20:00');
    await h.schedule.addTimetable(
      weekday: h.now.weekday,
      startTime: '19:00',
      endTime: '20:00',
      title: '晚课',
    );

    final future = DateTime(2026, 11, 7, 23);
    await h.tasks.createItem(title: '第三章作业', estMinutes: 60, dueAt: future);
    final urgent = await h.tasks.createItem(title: '明天要交的小测', estMinutes: 30);
    await h.tasks.setPriority(urgent, 2);
    await h.tasks.createItem(title: '整章复习', estMinutes: 240);
    await h.tasks.createItem(title: '模拟卷', estMinutes: 240);

    final plan = await h.capacity.compute();
    expect(plan.availableMinutes, 6 * 60);
    expect(plan.demandMinutes, 570);
    expect(plan.overCapacity, isTrue);
    expect(plan.candidates.map((item) => item.item.title), [
      '明天要交的小测',
      '第三章作业',
      '整章复习',
      '模拟卷',
    ]);
    expect(plan.candidates.map((item) => item.withinBudget), [
      true,
      true,
      true,
      false,
    ]);
    expect(plan.availableBudget, '约 6 小时');
    expect(plan.demandBudget, '约 9.5 小时');
    expect(plan.notes, isNotEmpty);
    expect(plan.skipped, isEmpty);

    final first = plan.candidates.first;
    final booked = await h.capacity.book(
      item: first.item,
      start: DateTime(2026, 11, 6, 21),
      end: DateTime(2026, 11, 6, 21, 30),
    );
    expect(
      (await h.schedule.blockById(booked.blockId))!.startAt,
      DateTime(2026, 11, 6, 21),
    );

    // 再次预约同一事项时调整原来的弹性块，不再新建；两次写入各有自己的提交。
    final again = await h.capacity.book(
      item: first.item,
      start: DateTime(2026, 11, 6, 21, 30),
      end: DateTime(2026, 11, 6, 22),
    );
    expect(again.blockId, booked.blockId);
    expect(again.commitId, isNot(booked.commitId));
    final blocks = await h.schedule.blocksForItem(first.item.id);
    expect(blocks, hasLength(1));
    expect(blocks.single.startAt, DateTime(2026, 11, 6, 21, 30));
  });

  test('V5：固定块不进入可预约顺序，弹性块在预约时改期', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '21:00');

    final flexible = await h.tasks.createItem(title: '重做第 8 题', estMinutes: 60);
    final fixed = await h.tasks.createItem(title: '固定复习', estMinutes: 60);
    final newItem = await h.tasks.createItem(title: '整理笔记', estMinutes: 30);
    final afternoon = DateTime(2026, 11, 7, 12);
    final flexibleBlock = await h.schedule.addBlock(
      planItemId: flexible,
      start: afternoon,
      end: afternoon.add(const Duration(hours: 1)),
    );
    final fixedStart = DateTime(2026, 11, 7, 15);
    final fixedBlock = await h.schedule.addBlock(
      planItemId: fixed,
      start: fixedStart,
      end: fixedStart.add(const Duration(hours: 1)),
    );
    await h.schedule.setLocked(fixedBlock, true);

    final plan = await h.capacity.compute();
    expect(plan.demandMinutes, 90);
    expect(plan.overCapacity, isFalse);
    expect(plan.skipped.single.item.id, fixed);
    expect(plan.skipped.single.fixed, isTrue);
    expect(plan.candidates.map((item) => item.item.id), [flexible, newItem]);
    expect(
      plan.candidates
          .firstWhere((item) => item.item.id == flexible)
          .movableBlockId,
      flexibleBlock,
    );

    await h.capacity.book(
      item: plan.candidates.first.item,
      start: DateTime(2026, 11, 6, 19),
      end: DateTime(2026, 11, 6, 20),
    );
    final moved = await h.schedule.blockById(flexibleBlock);
    expect(moved!.startAt, DateTime(2026, 11, 6, 19));
    final kept = await h.schedule.blockById(fixedBlock);
    expect(kept!.startAt, fixedStart);

    await h.capacity.book(
      item: plan.candidates.last.item,
      start: DateTime(2026, 11, 7, 10),
      end: DateTime(2026, 11, 7, 10, 30),
    );
    final created = await h.schedule.blocksForItem(newItem);
    expect(created.single.startAt, DateTime(2026, 11, 7, 10));
  });

  test('容量预算重排已有弹性预约时只计算一次事项需求', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '20:00');
    final first = await h.tasks.createItem(title: 'A', estMinutes: 30);
    await h.tasks.createItem(title: 'B', estMinutes: 30);
    await h.schedule.addBlock(
      planItemId: first,
      start: DateTime(2026, 11, 6, 19),
      end: DateTime(2026, 11, 6, 19, 30),
    );

    final plan = await h.capacity.compute(days: 1);
    expect(plan.availableMinutes, 60);
    expect(plan.demandMinutes, 60);
    expect(plan.overCapacity, isFalse);
    expect(
      plan.candidates.every((candidate) => candidate.withinBudget),
      isTrue,
    );
    expect(plan.notes.join(), contains('弹性安排会重新计算'));
    expect(plan.notes.join(), isNot(contains('没有可用空档')));
  });

  test('V5：未选定时间不写时间块，时段与预约校验拒绝倒置', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final item = await h.tasks.createItem(title: '做作业', estMinutes: 30);

    final plan = await h.capacity.compute();
    expect(plan.candidates.single.item.id, item);
    expect(
      await h.schedule.blocksBetween(h.now, DateTime(2026, 11, 13)),
      isEmpty,
    );
    expect(
      () => h.capacity.setWindow(start: '21:00', end: '19:00'),
      throwsArgumentError,
    );
    expect(
      () => h.capacity.book(
        item: plan.candidates.single.item,
        start: DateTime(2026, 11, 7, 20),
        end: DateTime(2026, 11, 7, 19),
      ),
      throwsArgumentError,
    );
    expect(
      await h.schedule.blocksBetween(h.now, DateTime(2026, 11, 13)),
      isEmpty,
    );
  });

  test('未填估时只作预算占位，说明里标出实际用时可能不同', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.tasks.createItem(title: '没有估时的事项');

    final plan = await h.capacity.compute();
    expect(plan.candidates.single.hasEstimate, isFalse);
    expect(plan.candidates.single.minutes, 20);
    expect(plan.notes.join(), contains('没有估时'));
    expect(plan.notes.join(), contains('点选其中一段就是这次的预约时间'));
  });

  test('时间只够先做急项时写明先做多少，并给出那一段空档', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '19:30');
    final urgent = await h.tasks.createItem(
      title: '明天要交的小测',
      estMinutes: 60,
      dueAt: DateTime(2026, 11, 6, 23),
    );
    final later = await h.tasks.createItem(
      title: '下周的整理',
      estMinutes: 20,
      dueAt: DateTime(2026, 11, 12, 23),
    );

    final plan = await h.capacity.compute(days: 1);
    final first = plan.candidates.firstWhere((item) => item.item.id == urgent);
    expect(first.minutes, 60);
    expect(first.plannedMinutes, 30);
    expect(first.withinBudget, isFalse);
    expect(first.windows.single.start, DateTime(2026, 11, 6, 19));
    expect(first.windows.single.end, DateTime(2026, 11, 6, 19, 30));
    expect(
      plan.candidates.firstWhere((item) => item.item.id == later).windows,
      isEmpty,
    );
    expect(plan.notes.join(), contains('可以先做「明天要交的小测」30 分钟'));
    expect(plan.notes.join(), contains('还差 30 分钟'));
  });

  test('已有两段预约时预算只算剩余需求，不把整项退出', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '21:00');
    final item = await h.tasks.createItem(title: '分三段做', estMinutes: 90);
    await h.schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 6, 19),
      end: DateTime(2026, 11, 6, 19, 30),
    );
    await h.schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 6, 20),
      end: DateTime(2026, 11, 6, 20, 30),
    );

    final plan = await h.capacity.compute(days: 1);
    final candidate = plan.candidates.single;
    expect(candidate.scheduledMinutes, 60);
    expect(candidate.minutes, 30);
    expect(plan.demandMinutes, 30);
    expect(candidate.withinBudget, isTrue);
    expect(candidate.windows.single.start, DateTime(2026, 11, 6, 19, 30));
    expect(candidate.windows.single.end, DateTime(2026, 11, 6, 20));
  });

  test('已有预约覆盖全部估时时从候选中说明，而不是静默消失', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final item = await h.tasks.createItem(title: '已经排满', estMinutes: 30);
    await h.schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 6, 19),
      end: DateTime(2026, 11, 6, 19, 30),
    );
    await h.schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 20),
    );

    final plan = await h.capacity.compute(days: 2);
    expect(plan.candidates, isEmpty);
    expect(plan.skipped.single.item.id, item);
    expect(plan.skipped.single.reason, contains('全部估时'));
  });

  test('预览之后目标暂停，点选旧空档不再写入预约', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final goal = await h.tasks.createGoal(title: '会暂停的目标');
    final item = await h.tasks.createItem(
      title: '暂停目标下的题',
      goalId: goal,
      estMinutes: 30,
    );
    final plan = await h.capacity.compute(days: 1);
    final candidate = plan.candidates.single;
    final window = candidate.windows.single;

    await h.tasks.pauseGoal(goal);
    await expectLater(
      h.capacity.book(
        item: candidate.item,
        start: window.start,
        end: window.end,
        expectedBlockId: candidate.movableBlockId,
        expectedNone:
            candidate.scheduledMinutes == 0 && candidate.movableBlockId == null,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await h.schedule.blocksForItem(item), isEmpty);
  });

  test('预览之后出现新预约，旧方案不会覆盖或再叠一段', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final item = await h.tasks.createItem(title: '预览后变化', estMinutes: 30);
    final plan = await h.capacity.compute(days: 1);
    final candidate = plan.candidates.single;
    final window = candidate.windows.single;
    await h.schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 10),
      end: DateTime(2026, 11, 7, 10, 30),
    );

    await expectLater(
      h.capacity.book(
        item: candidate.item,
        start: window.start,
        end: window.end,
        expectedNone: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await h.schedule.blocksForItem(item), hasLength(1));
  });

  test('已有弹性预约时可以再加一段，不改动原预约', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final itemId = await h.tasks.createItem(title: '分两段做', estMinutes: 60);
    final item = (await h.tasks.byId(itemId))!;
    final first = await h.schedule.addBlock(
      planItemId: item.id,
      start: DateTime(2026, 11, 6, 19),
      end: DateTime(2026, 11, 6, 19, 30),
    );

    final added = await h.capacity.book(
      item: item,
      start: DateTime(2026, 11, 6, 20),
      end: DateTime(2026, 11, 6, 20, 30),
      append: true,
    );

    final blocks = await h.schedule.blocksForItem(item.id);
    expect(blocks, hasLength(2));
    expect(
      blocks.map((block) => block.id),
      containsAll([first, added.blockId]),
    );
    expect(
      (await h.schedule.blockById(first))!.startAt,
      DateTime(2026, 11, 6, 19),
    );
  });

  test('预约可以直接使用算出的空档', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '20:00');
    await h.tasks.createItem(title: '整理笔记', estMinutes: 30);

    final plan = await h.capacity.compute(days: 1);
    final candidate = plan.candidates.single;
    expect(candidate.windows.single.start, DateTime(2026, 11, 6, 19));
    expect(candidate.windows.single.end, DateTime(2026, 11, 6, 19, 30));

    await h.capacity.book(
      item: candidate.item,
      start: candidate.windows.single.start,
      end: candidate.windows.single.end,
    );
    final blocks = await h.schedule.blocksForItem(candidate.item.id);
    expect(blocks.single.startAt, DateTime(2026, 11, 6, 19));
    expect(blocks.single.endAt, DateTime(2026, 11, 6, 19, 30));
  });

  test('今晚到期的事项不会因为明晚有空而算进预算', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.capacity.setWindow(start: '19:00', end: '20:00');
    final tonight = await h.tasks.createItem(
      title: '今晚到期',
      estMinutes: 90,
      dueAt: DateTime(2026, 11, 6, 23),
    );
    final later = await h.tasks.createItem(
      title: '下周到期',
      estMinutes: 30,
      dueAt: DateTime(2026, 11, 12, 23),
    );

    final plan = await h.capacity.compute();
    expect(
      plan.candidates
          .firstWhere((item) => item.item.id == tonight)
          .withinBudget,
      isFalse,
    );
    expect(
      plan.candidates.firstWhere((item) => item.item.id == later).withinBudget,
      isTrue,
    );
    expect(plan.notes.join(), contains('截止时间之前'));
  });

  test('本周预算只算到自然周的周日', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    // 2026-11-06 是周五，本周还剩周五、周六与周日三天。
    final plan = await h.capacity.computeThisWeek();
    expect(plan.days, 3);
  });

  test('粗略时间按十分钟与半小时取整', () {
    expect(roughMinutes(0), '0 分钟');
    expect(roughMinutes(27), '约 30 分钟');
    expect(roughMinutes(45), '约 50 分钟');
    expect(roughMinutes(350), '约 6 小时');
    expect(roughMinutes(570), '约 9.5 小时');
  });
}
