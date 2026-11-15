/// 时刻与时段的值对象：容量窗口、课表与预约共用同一套表示。
library;

/// 一天里的时刻，格式 `HH:MM`；不绑定日期与时区。
class ClockTime implements Comparable<ClockTime> {
  const ClockTime(this.hour, this.minute)
    : assert(hour >= 0 && hour < 24),
      assert(minute >= 0 && minute < 60);

  /// 解析 `HH:MM`；格式或范围不对时抛 [FormatException]。
  factory ClockTime.parse(String value) {
    final text = value.trim();
    final parts = text.split(':');
    if (parts.length == 2) {
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour != null &&
          minute != null &&
          hour >= 0 &&
          hour < 24 &&
          minute >= 0 &&
          minute < 60) {
        return ClockTime(hour, minute);
      }
    }
    throw FormatException('时间格式应为 HH:MM：$value');
  }

  static ClockTime? tryParse(String value) {
    try {
      return ClockTime.parse(value);
    } on FormatException {
      return null;
    }
  }

  final int hour;
  final int minute;

  int get minutesOfDay => hour * 60 + minute;

  String format() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  int compareTo(ClockTime other) => minutesOfDay.compareTo(other.minutesOfDay);

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => format();
}

/// 一段连续时间；时段本身不带业务含义，容量、预约与统计共用。
class TimeRange {
  const TimeRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  int get minutes => end.difference(start).inMinutes;

  bool get isEmpty => !end.isAfter(start);

  bool overlaps(TimeRange other) =>
      start.isBefore(other.end) && end.isAfter(other.start);

  TimeRange shift(Duration duration) =>
      TimeRange(start: start.add(duration), end: end.add(duration));
}
