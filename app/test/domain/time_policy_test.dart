import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

void main() {
  TimePolicy policyAt(DateTime at, {int cutoff = 4}) =>
      TimePolicy(clock: () => at, cutoffHour: cutoff);

  test('凌晨的学习记录归到前一天，日程仍按自然日期', () {
    final at = DateTime(2026, 11, 7, 0, 56);
    final policy = policyAt(at);

    expect(policy.attributionDay(at), '2026-11-06');
    expect(policy.naturalDate(at), DateTime(2026, 11, 7));

    final range = policy.naturalDayRange(at);
    expect(range.start, DateTime(2026, 11, 7));
    expect(range.endExclusive, DateTime(2026, 11, 8));
  });

  test('截止时间之前的一分钟仍算前一天，整点之后算新的一天', () {
    final before = DateTime(2026, 11, 7, 3, 59);
    final after = DateTime(2026, 11, 7, 4, 0);
    expect(policyAt(before).attributionDay(before), '2026-11-06');
    expect(policyAt(after).attributionDay(after), '2026-11-07');
    expect(policyAt(after).naturalDayRange(after).start, DateTime(2026, 11, 7));
  });

  test('截止时间设为 0 时按自然日归属', () {
    final at = DateTime(2026, 11, 7, 0, 56);
    final policy = policyAt(at, cutoff: 0);
    expect(policy.attributionDay(at), '2026-11-07');
    expect(policy.naturalDayRange(at).start, DateTime(2026, 11, 7));
  });

  test('截止小时遵守数据库的 0–6 范围', () {
    final at = DateTime(2026, 11, 7, 20);
    expect(() => policyAt(at, cutoff: 7), throwsRangeError);
    expect(policyAt(at, cutoff: 6).cutoffHour, 6);
  });

  test('自然周从周一零点起算，凌晨不回到上一周', () {
    final monday = DateTime(2026, 11, 9, 0, 56);
    final policy = policyAt(monday);
    expect(policy.attributionDay(monday), '2026-11-08');
    expect(policy.naturalWeekStart(monday), DateTime(2026, 11, 9));
    final week = policy.naturalWeekRange(monday);
    expect(week.start, DateTime(2026, 11, 9));
    expect(week.endExclusive, DateTime(2026, 11, 16));
  });
}
