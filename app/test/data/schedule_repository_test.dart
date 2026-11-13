import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/task_repository.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('区间查询包含跨越查询起点的时间块', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(db.rawDb);
    final itemId = await tasks.createItem(title: '跨夜复习');
    await schedule.addBlock(
      planItemId: itemId,
      start: DateTime(2026, 11, 7, 23, 30),
      end: DateTime(2026, 11, 8, 1),
    );

    final blocks = await schedule.blocksBetween(
      DateTime(2026, 11, 8),
      DateTime(2026, 11, 9),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.block.startAt, DateTime(2026, 11, 7, 23, 30));
  });

  test('新建和改期统一拒绝重叠时间块及课表占用', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(db.rawDb);
    final firstItem = await tasks.createItem(title: '第一项');
    final secondItem = await tasks.createItem(title: '第二项');
    final start = DateTime(2026, 11, 9, 10);
    final end = start.add(const Duration(hours: 1));
    final firstBlock = await schedule.addBlock(
      planItemId: firstItem,
      start: start,
      end: end,
    );
    await schedule.addBlock(
      planItemId: secondItem,
      start: end,
      end: end.add(const Duration(hours: 1)),
    );

    await expectLater(
      schedule.addBlock(
        planItemId: secondItem,
        start: start.add(const Duration(minutes: 30)),
        end: end.add(const Duration(minutes: 30)),
      ),
      throwsA(isA<ScheduleConflictException>()),
    );
    await expectLater(
      schedule.moveBlock(
        firstBlock,
        start: start.add(const Duration(minutes: 30)),
        end: end.add(const Duration(minutes: 30)),
      ),
      throwsA(isA<ScheduleConflictException>()),
    );

    await schedule.addTimetable(
      weekday: 1,
      startTime: '08:00',
      endTime: '09:00',
      title: '周一课程',
    );
    await expectLater(
      schedule.addBlock(
        planItemId: secondItem,
        start: DateTime(2026, 11, 9, 8, 30),
        end: DateTime(2026, 11, 9, 9, 30),
      ),
      throwsA(
        isA<ScheduleConflictException>().having(
          (error) => error.description,
          'description',
          allOf(contains('固定课表'), contains('周一课程'), contains('周一 08:00–09:00')),
        ),
      ),
    );
  });

  test('恢复为待开始时同样拒绝与已有预约重叠', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(db.rawDb);
    final firstItem = await tasks.createItem(title: '原预约');
    final secondItem = await tasks.createItem(title: '新事项');
    final start = DateTime(2026, 11, 9, 10);
    final end = start.add(const Duration(hours: 1));
    final firstBlock = await schedule.addBlock(
      planItemId: firstItem,
      start: start,
      end: end,
    );

    await schedule.setBlockStatus(firstBlock, 'cancelled');
    await schedule.addBlock(planItemId: secondItem, start: start, end: end);

    await expectLater(
      schedule.setBlockStatus(firstBlock, 'planned'),
      throwsA(isA<ScheduleConflictException>()),
    );
    expect((await schedule.blockById(firstBlock))!.status, 'cancelled');
  });

  test('新增课表先核对既有预约，重叠时拒绝且不写入', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 6, 18),
    );
    final item = await tasks.createItem(title: '概率论作业');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 9, 10),
      end: DateTime(2026, 11, 9, 11),
    );

    await expectLater(
      schedule.addTimetable(
        weekday: 1,
        startTime: '10:30',
        endTime: '11:30',
        title: '高等数学',
      ),
      throwsA(
        isA<ScheduleConflictException>().having(
          (error) => error.description,
          'description',
          allOf(contains('预约“概率论作业”'), contains('2026-11-09 10:00:00')),
        ),
      ),
    );
    expect(await schedule.timetable(), isEmpty);

    // 不重叠的时段照常写入。
    await schedule.addTimetable(
      weekday: 1,
      startTime: '08:00',
      endTime: '09:00',
      title: '高等数学',
    );
    expect(await schedule.timetable(), hasLength(1));
  });

  test('跨日预约与次日凌晨的课表同样算重叠', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 6, 18),
    );
    final item = await tasks.createItem(title: '跨夜复习');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 9, 23),
      end: DateTime(2026, 11, 10, 1),
    );

    await expectLater(
      schedule.addTimetable(
        weekday: 2,
        startTime: '00:30',
        endTime: '01:30',
        title: '周二早课',
      ),
      throwsA(isA<ScheduleConflictException>()),
    );
    expect(await schedule.timetable(), isEmpty);
  });

  test('已经结束的预约不阻止新增课表', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 6, 18),
    );
    final item = await tasks.createItem(title: '上周的复习');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 2, 10),
      end: DateTime(2026, 11, 2, 11),
    );

    await schedule.addTimetable(
      weekday: 1,
      startTime: '10:30',
      endTime: '11:30',
      title: '高等数学',
    );
    expect(await schedule.timetable(), hasLength(1));
  });

  test('批量取消遇到已经取消的预约时整组不写', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final schedule = ScheduleRepository(db.rawDb);
    final item = await tasks.createItem(title: '复习');
    final first = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 10),
      end: DateTime(2026, 11, 7, 10, 30),
    );
    final second = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 11),
      end: DateTime(2026, 11, 7, 11, 30),
    );
    await schedule.setBlockStatus(first, 'cancelled');

    await expectLater(
      schedule.cancelBlocks([first, second]),
      throwsA(isA<StateError>()),
    );
    expect((await schedule.blockById(second))!.status, 'planned');
  });
}
