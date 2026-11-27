import 'dart:async';

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
/// 记录页按日期分组时用这一份。
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

/// 设备标识脱敏：去掉首尾空白，只保留前 [keep] 位，短的标识原样返回。
///
/// 设备标识只用于区分来源，界面不显示整串（ADR-0048）；需要省略整段说明时
/// 判断返回值是否为空串。数据版本页与账号页原先各写一份，这里只留一处。
String maskedDeviceId(String? deviceId, {int keep = 8}) {
  assert(keep > 0, '至少保留一位');
  final value = deviceId?.trim() ?? '';
  if (value.isEmpty || value.length <= keep) return value;
  return value.substring(0, keep);
}

/// 字节数的界面写法：不足 1 KiB 写 B，1 KiB 起写整数 KB，1 MiB 起写一位小数
/// 的 MB，1 GiB 起写一位小数的 GB。
///
/// 每一档都四舍五入，1025 B 在任何页面都写成 `1 KB`；云备份页、数据版本页与
/// 数据包的容量说明原先用 `.ceil()`、`.round()` 与不同的小数位，同一个大小会
/// 读出两个结果，这里统一成一种写法。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

/// 防抖的默认等待：输入停下这么久之后才发起查找，免得每敲一个字都读一遍库。
const Duration kDebounceDelay = Duration(milliseconds: 250);

/// 输入停下之后再动作的定时器；连续调用只保留最后一次。
///
/// 材料页、材料列表与材料选择器原先各写一份 `Timer` 与取消逻辑，这里合成一个
/// 对象：`call` 换成新的等待，[cancel] 撤掉尚未执行的一次，[dispose] 供
/// `State.dispose` 调用。
class Debouncer {
  Debouncer({this.duration = kDebounceDelay});

  /// 从最后一次调用起等待的时长。
  final Duration duration;

  Timer? _timer;

  /// 是否还有一次等待没有执行。
  bool get isPending => _timer?.isActive ?? false;

  /// 重新计时；之前排着的那一次不再执行。
  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(duration, action);
  }

  /// 撤掉尚未执行的一次；已经执行的不受影响。
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
