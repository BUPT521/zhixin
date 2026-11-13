import '../domain/rules/time_format.dart';

/// 界面上的短时间：今天显示时刻，其余显示日期。
String shortTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final sameDay =
      time.year == current.year &&
      time.month == current.month &&
      time.day == current.day;
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(time.hour)}:${two(time.minute)}';
  if (sameDay) return clock;
  return '${time.month}月${time.day}日 $clock';
}

String clockOf(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

String dayLabel(DateTime time) =>
    '${time.month}月${time.day}日 ${weekdayLabel(time.weekday)}';

String weekdayLabel(int weekday) => switch (weekday) {
  1 => '周一',
  2 => '周二',
  3 => '周三',
  4 => '周四',
  5 => '周五',
  6 => '周六',
  7 => '周日',
  _ => '',
};

String dateText(DateTime? date) => date == null ? '未定' : formatDate(date);

String statusLabel(String status) => switch (status) {
  'open' => '未作答',
  'unjudged' => '未判断',
  'wrong' => '待处理',
  'correct' => '做对过',
  _ => status,
};
