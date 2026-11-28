/// 记录归属日与 SQLite 时间文本的统一格式（01 D9）。
///
/// 页面、仓库和备份只从这里取日期字符串，避免各处自己补零。
library;

import '../models/time_values.dart';

/// `YYYY-MM-DD`，按设备本地时区。
String formatDate(DateTime day) {
  final local = day.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final date = local.day.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-$month-$date';
}

/// `YYYY-MM-DD HH:MM:SS`，按设备本地时区。
String formatDateTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${formatDate(local)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// 解析数据库中的必需时刻；坏值必须暴露，不能伪装成当前时间。
DateTime requiredDateTime(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('无效的时间值：$value');
  return parsed;
}

/// 还要等多久的短说明：一分钟以内写秒，一小时以内写分钟，再长写小时。
///
/// 限流给出的等待秒数动辄上万（验证码的收信预算用完时要等几个小时），界面直接
/// 写秒数读不出还剩多久；一律向上取整，避免提前放行之后再被拒绝一次。
String waitText(int seconds) {
  if (seconds >= 3600) return '${(seconds / 3600).ceil()} 小时';
  if (seconds > 60) return '${(seconds / 60).ceil()} 分钟';
  return '$seconds 秒';
}

/// 界面上的短时间：今天显示时刻，其余显示日期。
String shortTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final sameDay =
      time.year == current.year &&
      time.month == current.month &&
      time.day == current.day;
  final clock = ClockTime(time.hour, time.minute).format();
  if (sameDay) return clock;
  return '${time.month}月${time.day}日 $clock';
}

/// 文件名里的紧凑日期：`YYYYMMDD`，与界面日期分开，不带分隔符。
String compactDate(DateTime time) => formatDate(time).replaceAll('-', '');

/// 解析可空时刻：缺失或空串返回 null，非空坏值仍抛错。
DateTime? optionalDateTime(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return requiredDateTime(text);
}
