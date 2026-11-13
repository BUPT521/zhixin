import 'day_key.dart';

/// 取当前时刻的函数；测试里换成固定时钟（01 第 3.2 节）。
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now();

/// 01 的 `profile.day_cutoff_hour` 默认值；没有读到配置时用它。
const int defaultDayCutoffHour = 4;

/// 时间口径：真实发生时刻、日程的自然日期、学习记录的归属日。
///
/// 日程与课表始终按自然日期计算，凌晨 2 点的日程仍属于当天；学习记录按
/// [cutoffHour] 归到前一天或当天，只影响记录的展示与分组。两种口径分开计算，
/// 页面与仓库不再各自拼日期。
class TimePolicy {
  TimePolicy({required this.clock, this.cutoffHour = 4}) {
    if (cutoffHour < 0 || cutoffHour > maxDayCutoffHour) {
      throw RangeError.range(cutoffHour, 0, maxDayCutoffHour, 'cutoffHour');
    }
  }

  final Clock clock;
  final int cutoffHour;

  /// 真实发生时刻。
  DateTime get now => clock();

  /// 日程与课表用的自然日期（当天零点）。
  DateTime naturalDate(DateTime at) => DateTime(at.year, at.month, at.day);

  /// 自然日覆盖的真实区间：[当天零点, 次日零点)。
  ({DateTime start, DateTime endExclusive}) naturalDayRange(DateTime at) {
    final day = naturalDate(at);
    return (
      start: day,
      endExclusive: DateTime(day.year, day.month, day.day + 1),
    );
  }

  /// 自然周的起点（周一零点）。
  DateTime naturalWeekStart(DateTime at) {
    final day = naturalDate(at);
    return DateTime(day.year, day.month, day.day - (day.weekday - 1));
  }

  /// 自然周覆盖的真实区间：[周一零点, 下周一零点)。
  ({DateTime start, DateTime endExclusive}) naturalWeekRange(DateTime at) {
    final monday = naturalWeekStart(at);
    return (
      start: monday,
      endExclusive: DateTime(monday.year, monday.month, monday.day + 7),
    );
  }

  /// 学习记录的归属日，返回 `YYYY-MM-DD`；只用于记录展示与分组。
  String attributionDay(DateTime at) => dayKey(at, cutoffHour: cutoffHour);
}
