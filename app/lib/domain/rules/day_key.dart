/// 01 Q9：凌晨 `day_cutoff_hour` 点前算前一天。
///
/// 记录归属日统一走这里，页面不要各自用 `DateTime.now()` 拼日期，否则凌晨记的
/// 内容会落到第二天，周报和「今天记了什么」都会错位。
library;

import 'time_format.dart';

const int maxDayCutoffHour = 6;

/// 校验截止小时；四处入口共用这一份判定与异常类型。
int requireDayCutoffHour(int hour) {
  if (hour < 0 || hour > maxDayCutoffHour) {
    throw RangeError.range(hour, 0, maxDayCutoffHour, 'day_cutoff_hour');
  }
  return hour;
}

/// 把时刻折算成归属日，返回 `YYYY-MM-DD`。
String dayKey(DateTime now, {int cutoffHour = 4}) {
  requireDayCutoffHour(cutoffHour);
  final adjusted = now.hour < cutoffHour
      ? now.subtract(const Duration(days: 1))
      : now;
  return formatDate(adjusted);
}
