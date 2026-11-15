import '../domain/models/time_values.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/weekdays.dart';

// 星期名在 domain/rules/weekdays.dart 里只写一份，这里转出给界面使用。
export '../domain/rules/weekdays.dart' show weekdayLabel;

/// 界面上的短时间：今天显示时刻，其余显示日期。
String shortTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final sameDay =
      time.year == current.year &&
      time.month == current.month &&
      time.day == current.day;
  final clock = clockOf(time);
  if (sameDay) return clock;
  return '${time.month}月${time.day}日 $clock';
}

String clockOf(DateTime time) => ClockTime(time.hour, time.minute).format();

/// 文件名里的紧凑日期：`YYYYMMDD`，与界面日期分开，不带分隔符。
String compactDate(DateTime time) => formatDate(time).replaceAll('-', '');

String dayLabel(DateTime time) =>
    '${time.month}月${time.day}日 ${weekdayLabel(time.weekday)}';

String dateText(DateTime? date) => date == null ? '未定' : formatDate(date);

String statusLabel(String status) => switch (status) {
  'open' => '未作答',
  'unjudged' => '未判断',
  'wrong' => '待处理',
  'correct' => '做对过',
  _ => status,
};
