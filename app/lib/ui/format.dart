import '../domain/models/time_values.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/weekdays.dart';

// 星期名在 domain/rules/weekdays.dart 里只写一份，这里转出给界面使用。
export '../domain/rules/weekdays.dart' show weekdayLabel;
// 等待时长的写法与限流说明共用一份，见 domain/rules/time_format.dart。
export '../domain/rules/time_format.dart' show waitText;

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

/// 日期分组的标题：今天与昨天写相对说法，其余写日期与星期。
///
/// 记录页按日期分组、安排页按天列预约都用这一份，两处不再各写一套。
String relativeDayHeading(DateTime date, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天 · ${dayLabel(date)}';
  if (diff == 1) return '昨天 · ${dayLabel(date)}';
  return dayLabel(date);
}

/// 一段日期的月日区间，两侧都只写月与日。
String monthDayRange(DateTime start, DateTime end) =>
    '${start.month}月${start.day}日 – ${end.month}月${end.day}日';

String dateText(DateTime? date) => date == null ? '未定' : formatDate(date);

/// 计费 token 的简写：一万以上用“万”，一亿以上用“亿”，其余保留千位分隔。
///
/// 积分折算与每日额度都是大数，界面写“100 万”比“1000000”好读，换算口径见
/// [ADR-0068](../../docs/adr/0068-聊天积分包的档位与价格.md)。
String tokenAmount(int tokens) {
  final value = tokens.abs();
  if (value >= 100000000) return '${_trimZero(tokens / 100000000)} 亿';
  if (value >= 10000) return '${_trimZero(tokens / 10000)} 万';
  return _group(tokens);
}

/// 按每日免费额度算出的天数：十以下保留一位小数，十以上取整。
String quotaDays(double days) {
  if (days >= 10) return days.round().toString();
  return _trimZero(days);
}

/// 整数加千位分隔；积分这类不换算成万的数量用它。
String groupDigits(int value) => _group(value);

/// 把计费 token 换算成积分，向上取整：服务端核销按同一口径取整（ADR-0068）。
///
/// 比例缺失或不是正数时返回 0，调用方据此退回按 token 显示。
int quotaPoints(int tokens, int? tokensPerPoint) {
  if (tokens <= 0 || tokensPerPoint == null || tokensPerPoint <= 0) return 0;
  return (tokens + tokensPerPoint - 1) ~/ tokensPerPoint;
}

/// 把每日免费额度换算成积分，向下取整：额度只有凑满一整份积分才算数，向上取整会
/// 和核销对不上——额度 25,000、一个积分 10,000 计费 token 时，当天用满 25,000 只
/// 扣两个积分，页面却把额度写成 3 积分，同时又说“已扣 1 分”。用量一侧仍按向上
/// 取整，见 [quotaPoints]。
int freeQuotaPoints(int tokens, int? tokensPerPoint) {
  if (tokens <= 0 || tokensPerPoint == null || tokensPerPoint <= 0) return 0;
  return tokens ~/ tokensPerPoint;
}

String _trimZero(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

String _group(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String statusLabel(String status) => switch (status) {
  'open' => '未作答',
  'unjudged' => '未判断',
  'wrong' => '待处理',
  'correct' => '做对过',
  _ => status,
};
