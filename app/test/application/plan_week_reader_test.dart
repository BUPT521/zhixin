import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/application/plan_week_reader.dart';
import 'package:zhixin/domain/models/study.dart';

/// 一周只有一段预约；标题用来辨认这一份数据属于哪一周。
PlanWeek _week(String title) {
  final start = DateTime(2026, 11, 10, 10);
  return PlanWeek(
    timetable: const [],
    blocks: [
      ScheduledItem(
        block: ScheduleBlock(
          id: 1,
          planItemId: 1,
          startAt: start,
          endAt: start.add(const Duration(hours: 1)),
        ),
        itemTitle: title,
      ),
    ],
    items: const [],
    operations: const [],
  );
}

void main() {
  test('两次换周反序返回时只保留最新一次请求', () async {
    final pending = <DateTime, List<Completer<PlanWeek>>>{};
    final reader = PlanWeekReader(
      read: (weekStart) {
        final completer = Completer<PlanWeek>();
        pending.putIfAbsent(weekStart, () => []).add(completer);
        return completer.future;
      },
    );
    final firstWeek = DateTime(2026, 11, 9);
    final secondWeek = DateTime(2026, 11, 16);

    final first = reader.select(firstWeek)!;
    final firstRead = reader.read(first.weekStart);
    final second = reader.select(secondWeek)!;
    final secondRead = reader.read(second.weekStart);

    // 新周先回来，旧周后回来：旧请求在回填前就被判为过期。
    pending[secondWeek]!.single.complete(_week('新的一周'));
    pending[firstWeek]!.single.complete(_week('旧的一周'));

    expect((await secondRead).blocks.single.itemTitle, '新的一周');
    expect((await firstRead).blocks.single.itemTitle, '旧的一周');
    expect(reader.isCurrent(second), isTrue);
    expect(reader.isCurrent(first), isFalse);
    expect(reader.weekStart, secondWeek);
  });

  test('刷新沿用当前目标周，并让更早的读取作废', () {
    final reader = PlanWeekReader(read: (_) => Completer<PlanWeek>().future);
    final week = DateTime(2026, 11, 16);

    final selected = reader.select(week)!;
    final refreshed = reader.refresh()!;

    expect(refreshed.weekStart, week);
    expect(refreshed.request, greaterThan(selected.request));
    expect(reader.isCurrent(refreshed), isTrue);
    expect(reader.isCurrent(selected), isFalse);
    expect(reader.weekStart, week);
  });

  test('再次选中当前周不重复读取，没有目标周时刷新不发起请求', () {
    final reader = PlanWeekReader(read: (_) => Completer<PlanWeek>().future);
    expect(reader.refresh(), isNull);

    final week = DateTime(2026, 11, 16);
    expect(reader.select(week), isNotNull);
    expect(reader.select(week), isNull);
  });
}
