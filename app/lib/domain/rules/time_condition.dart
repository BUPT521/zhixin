import '../rules/time_format.dart';

/// 查询里的显式时间条件；没有写日期时为空。
///
/// 目前支持年月日、月日、今天、昨天、前天与前天；只有相对日期时按自然日
/// 取整天，避免把回答当天的作答混进“昨天”的范围。
class TimeCondition {
  const TimeCondition({
    required this.from,
    required this.to,
    required this.label,
  });

  final DateTime from;
  final DateTime to;
  final String label;

  bool contains(DateTime moment) =>
      !moment.isBefore(from) && moment.isBefore(to);

  static TimeCondition? parse(String query, DateTime now) {
    final text = query.trim();
    final day = _naturalDay(now);
    final full = RegExp(
      r'(\d{4})\s*[-年/.]\s*(\d{1,2})\s*[-月/.]\s*(\d{1,2})\s*日?',
    ).firstMatch(text);
    if (full != null) {
      final start = DateTime(
        int.parse(full.group(1)!),
        int.parse(full.group(2)!),
        int.parse(full.group(3)!),
      );
      return TimeCondition(
        from: start,
        to: start.add(const Duration(days: 1)),
        label: '${start.year}-${_two(start.month)}-${_two(start.day)}',
      );
    }
    final monthDay = RegExp(r'(\d{1,2})\s*月\s*(\d{1,2})\s*日?').firstMatch(text);
    if (monthDay != null) {
      final start = DateTime(
        day.year,
        int.parse(monthDay.group(1)!),
        int.parse(monthDay.group(2)!),
      );
      return TimeCondition(
        from: start,
        to: start.add(const Duration(days: 1)),
        label: '${start.month} 月 ${start.day} 日',
      );
    }
    for (final entry in const [('今天', 0), ('昨天', 1), ('前天', 2)]) {
      if (!text.contains(entry.$1)) continue;
      final start = day.subtract(Duration(days: entry.$2));
      return TimeCondition(
        from: start,
        to: start.add(const Duration(days: 1)),
        label: entry.$1,
      );
    }
    return null;
  }

  /// “上次、后来、历次”等说法没有日期，但说明用户要沿同一条记录回看。
  static bool hasTemporalCue(String query) =>
      RegExp(r'上次|上一次|后来|之后|以前|之前|那次|历次|这几次|最近一次|什么时候').hasMatch(query);

  /// 查询是否在问后来的独立表现；只问当时用了什么帮助时，不提示缺少后来的作答。
  static bool wantsLaterPerformance(String query) =>
      RegExp(r'后来|之后|以后|独立|自己|掌握|学会|还会').hasMatch(query);
}

DateTime _naturalDay(DateTime now) => DateTime(now.year, now.month, now.day);

String _two(int value) => value.toString().padLeft(2, '0');

/// 时间条件的展示文字；没有条件时返回空串。
String describeTimeCondition(TimeCondition? condition) =>
    condition == null ? '' : condition.label;

String formatMoment(DateTime moment) => formatDateTime(moment);
