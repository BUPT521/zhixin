import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/capacity_budget.dart';

void main() {
  final now = DateTime(2026, 11, 8, 18);
  final horizon = DateTime(2026, 11, 15, 21, 30);

  CapacitySlot slot(DateTime day, int hour, int minutes) => CapacitySlot(
    start: DateTime(day.year, day.month, day.day, hour),
    end: DateTime(
      day.year,
      day.month,
      day.day,
      hour,
    ).add(Duration(minutes: minutes)),
  );

  test('晚到期的事项不会占用早到期事项还需要的时间', () {
    final tonight = DateTime(2026, 11, 8);
    final tomorrow = DateTime(2026, 11, 9);
    final fits = fitByDeadline(
      slots: [slot(tonight, 19, 30), slot(tomorrow, 19, 30)],
      demands: [
        CapacityDemand(id: 1, minutes: 30, dueAt: DateTime(2026, 11, 9, 20)),
        CapacityDemand(id: 2, minutes: 45, dueAt: DateTime(2026, 11, 8, 23)),
      ],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.firstWhere((fit) => fit.id == 2).allocated, 30);
    expect(fits.firstWhere((fit) => fit.id == 2).fits, isFalse);
    expect(fits.firstWhere((fit) => fit.id == 2).shortfall, 15);
    expect(fits.firstWhere((fit) => fit.id == 1).allocated, 30);
    expect(fits.firstWhere((fit) => fit.id == 1).fits, isTrue);
  });

  test('结果与传入顺序一致，分配按截止时间进行', () {
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 8), 19, 30)],
      demands: [
        CapacityDemand(id: 7, minutes: 30, dueAt: DateTime(2026, 11, 9, 19)),
        CapacityDemand(id: 9, minutes: 30, dueAt: DateTime(2026, 11, 8, 23)),
      ],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.map((fit) => fit.id), [7, 9]);
    expect(fits.firstWhere((fit) => fit.id == 9).fits, isTrue);
    expect(fits.firstWhere((fit) => fit.id == 7).fits, isFalse);
  });

  test('同一截止时间按传入顺序分配', () {
    final due = DateTime(2026, 11, 8, 23);
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 8), 19, 30)],
      demands: [
        CapacityDemand(id: 1, minutes: 20, dueAt: due),
        CapacityDemand(id: 2, minutes: 20, dueAt: due),
      ],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.firstWhere((fit) => fit.id == 1).fits, isTrue);
    expect(fits.firstWhere((fit) => fit.id == 2).allocated, 10);
    expect(fits.firstWhere((fit) => fit.id == 2).fits, isFalse);
    expect(
      fits.firstWhere((fit) => fit.id == 1).windows.single.end,
      DateTime(2026, 11, 8, 19, 20),
    );
    expect(
      fits.firstWhere((fit) => fit.id == 2).windows.single.start,
      DateTime(2026, 11, 8, 19, 20),
    );
  });

  test('分到的时间同时给出可预约的时段，做不完的项也给一段', () {
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 8), 19, 30)],
      demands: [
        CapacityDemand(id: 1, minutes: 60, dueAt: DateTime(2026, 11, 8, 23)),
        CapacityDemand(id: 2, minutes: 20, dueAt: DateTime(2026, 11, 9, 23)),
      ],
      now: now,
      horizonEnd: horizon,
    );

    final urgent = fits.firstWhere((fit) => fit.id == 1);
    expect(urgent.fits, isFalse);
    expect(urgent.windows, hasLength(1));
    expect(urgent.windows.single.start, DateTime(2026, 11, 8, 19));
    expect(urgent.windows.single.end, DateTime(2026, 11, 8, 19, 30));
    expect(fits.firstWhere((fit) => fit.id == 2).windows, isEmpty);
  });

  test('没有截止时间的事项使用整个窗口', () {
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 12), 19, 40)],
      demands: const [CapacityDemand(id: 3, minutes: 40)],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.single.allocated, 40);
    expect(fits.single.fits, isTrue);
  });

  test('已经过期的事项分不到时间', () {
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 8), 19, 60)],
      demands: [
        CapacityDemand(id: 4, minutes: 30, dueAt: DateTime(2026, 11, 7, 23)),
      ],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.single.allocated, 0);
    expect(fits.single.fits, isFalse);
  });

  test('截止时间超过窗口时按窗口封顶', () {
    final fits = fitByDeadline(
      slots: [slot(DateTime(2026, 11, 10), 19, 30)],
      demands: [
        CapacityDemand(id: 5, minutes: 30, dueAt: DateTime(2026, 12, 1)),
      ],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.single.allocated, 30);
  });

  test('没有空档时需求全部落空', () {
    final fits = fitByDeadline(
      slots: const [],
      demands: const [CapacityDemand(id: 6, minutes: 20)],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.single.allocated, 0);
    expect(fits.single.shortfall, 20);
  });

  test('开始时间已经过去的那一段只算剩余部分', () {
    final fits = fitByDeadline(
      slots: [
        CapacitySlot(
          start: DateTime(2026, 11, 8, 17),
          end: DateTime(2026, 11, 8, 19),
        ),
      ],
      demands: const [CapacityDemand(id: 8, minutes: 90)],
      now: now,
      horizonEnd: horizon,
    );

    expect(fits.single.allocated, 60);
    expect(fits.single.fits, isFalse);
  });
}
