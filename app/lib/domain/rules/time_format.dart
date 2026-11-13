/// 记录归属日与 SQLite 时间文本的统一格式（01 D9）。
///
/// 页面、仓库和备份只从这里取日期字符串，避免各处自己补零。
library;

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
DateTime parseDateTime(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('无效的时间值：$value');
  return parsed;
}
