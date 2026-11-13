/// 01 Q9：凌晨 `day_cutoff_hour` 点前算前一天。
///
/// 记录归属日统一走这里，页面不要各自用 `DateTime.now()` 拼日期，否则凌晨记的
/// 内容会落到第二天，周报和「今天记了什么」都会错位。
library;

import 'time_format.dart';

const int maxDayCutoffHour = 6;

/// 把时刻折算成归属日，返回 `YYYY-MM-DD`。
String dayKey(DateTime now, {int cutoffHour = 4}) {
  if (cutoffHour < 0 || cutoffHour > maxDayCutoffHour) {
    throw RangeError.range(cutoffHour, 0, maxDayCutoffHour, 'cutoffHour');
  }
  final adjusted = now.hour < cutoffHour
      ? now.subtract(const Duration(days: 1))
      : now;
  return formatDate(adjusted);
}
