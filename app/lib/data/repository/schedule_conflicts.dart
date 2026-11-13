import 'package:sqflite/sqflite.dart';

import '../../domain/rules/time_format.dart';
import '../../domain/rules/weekdays.dart';

/// 一处时间占用冲突：重叠区间与来源说明，由调用方决定如何报告。
class ScheduleConflict {
  const ScheduleConflict({
    required this.start,
    required this.end,
    required this.description,
  });

  final DateTime start;
  final DateTime end;
  final String description;
}

/// 查一段时间是否与待开始预约或课表重叠。
///
/// 新建、改期、恢复为待开始与撤销共用这一份规则，避免只改其中一条路径后
/// 别的入口又绕开限制。[ignoredBlockIds] 用于排除正在移动或恢复的预约本身，
/// 整组调整时也用它排除所有参与调整的预约。
Future<ScheduleConflict?> findScheduleConflict(
  DatabaseExecutor executor, {
  required DateTime start,
  required DateTime end,
  Set<int> ignoredBlockIds = const {},
}) async {
  _requireInterval(start, end);
  final block = await _findBlockConflict(
    executor,
    start: start,
    end: end,
    ignoredBlockIds: ignoredBlockIds,
  );
  if (block != null) return block;
  return findTimetableConflict(executor, start: start, end: end);
}

/// 只查课表占用；整组调整已经比较过预约之间的重叠时用它。
Future<ScheduleConflict?> findTimetableConflict(
  DatabaseExecutor executor, {
  required DateTime start,
  required DateTime end,
}) async {
  _requireInterval(start, end);
  var day = DateTime(start.year, start.month, start.day);
  while (day.isBefore(end)) {
    final nextDay = day.add(const Duration(days: 1));
    final segmentStart = start.isAfter(day) ? start : day;
    final segmentEnd = end.isBefore(nextDay) ? end : nextDay;
    if (segmentEnd.isAfter(segmentStart)) {
      final entries = await executor.query(
        'timetable_entry',
        where: 'weekday = ?',
        whereArgs: [day.weekday],
      );
      for (final entry in entries) {
        final from = _clockMinutes(entry['start_time'] as String?);
        final to = _clockMinutes(entry['end_time'] as String?);
        if (from == null || to == null) continue;
        final classStart = DateTime(
          day.year,
          day.month,
          day.day,
          from ~/ 60,
          from % 60,
        );
        final classEnd = DateTime(
          day.year,
          day.month,
          day.day,
          to ~/ 60,
          to % 60,
        );
        if (classStart.isBefore(segmentEnd) && classEnd.isAfter(segmentStart)) {
          final title = entry['title'] as String? ?? '未命名课程';
          final location = entry['location'] as String?;
          return ScheduleConflict(
            start: classStart.isAfter(segmentStart) ? classStart : segmentStart,
            end: classEnd.isBefore(segmentEnd) ? classEnd : segmentEnd,
            description:
                '固定课表“$title”（${weekdayLabel(day.weekday)} '
                '${entry['start_time']}–${entry['end_time']}'
                '${location == null || location.trim().isEmpty ? '' : '，$location'}）',
          );
        }
      }
    }
    day = nextDay;
  }
  return null;
}

/// 一段按周重复的固定课表与既有待开始预约的重叠。
///
/// 新建预约时由 [findTimetableConflict] 查课表，新增课时反过来用它查预约：
/// 课表按星期重复，预约落在具体日期上，因此从预约一侧逐日核对，某一天既是
/// 这堂课所在的星期、时段又与预约重叠时返回这一天的具体区间。[now] 之前
/// 已经结束的预约不占用时间；课表时间无法解析或起止顺序不成立时返回空，
/// 交给表约束拒绝。
Future<ScheduleConflict?> findRecurringTimetableConflict(
  DatabaseExecutor executor, {
  required int weekday,
  required String startTime,
  required String endTime,
  required DateTime now,
}) async {
  final from = _clockMinutes(startTime);
  final to = _clockMinutes(endTime);
  if (from == null || to == null || to <= from) return null;
  final rows = await executor.rawQuery(
    '''
    SELECT b.start_at, b.end_at, p.title
    FROM schedule_block b
    JOIN plan_item p ON p.id = b.plan_item_id
    WHERE b.status = 'planned' AND b.end_at > ?
    ORDER BY b.start_at
    ''',
    [formatDateTime(now)],
  );
  for (final row in rows) {
    final blockStart = DateTime.parse(row['start_at']! as String);
    final blockEnd = DateTime.parse(row['end_at']! as String);
    var day = DateTime(blockStart.year, blockStart.month, blockStart.day);
    while (day.isBefore(blockEnd)) {
      if (day.weekday == weekday) {
        final classStart = DateTime(
          day.year,
          day.month,
          day.day,
          from ~/ 60,
          from % 60,
        );
        final classEnd = DateTime(
          day.year,
          day.month,
          day.day,
          to ~/ 60,
          to % 60,
        );
        if (classStart.isBefore(blockEnd) && classEnd.isAfter(blockStart)) {
          return ScheduleConflict(
            start: classStart.isAfter(blockStart) ? classStart : blockStart,
            end: classEnd.isBefore(blockEnd) ? classEnd : blockEnd,
            description:
                '预约“${row['title']}”'
                '（${formatDateTime(blockStart)}–${formatDateTime(blockEnd)}）',
          );
        }
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
  return null;
}

Future<ScheduleConflict?> _findBlockConflict(
  DatabaseExecutor executor, {
  required DateTime start,
  required DateTime end,
  required Set<int> ignoredBlockIds,
}) async {
  final ignored = ignoredBlockIds.toList(growable: false);
  final placeholders = List.filled(ignored.length, '?').join(', ');
  final rows = await executor.rawQuery(
    '''
    SELECT b.start_at, b.end_at, p.title
    FROM schedule_block b
    JOIN plan_item p ON p.id = b.plan_item_id
    WHERE b.status = 'planned' AND b.start_at < ? AND b.end_at > ?
      ${ignored.isEmpty ? '' : 'AND b.id NOT IN ($placeholders)'}
    ORDER BY b.start_at
    LIMIT 1
    ''',
    [formatDateTime(end), formatDateTime(start), ...ignored],
  );
  if (rows.isEmpty) return null;
  final row = rows.first;
  final conflictStart = DateTime.parse(row['start_at']! as String);
  final conflictEnd = DateTime.parse(row['end_at']! as String);
  return ScheduleConflict(
    start: conflictStart.isAfter(start) ? conflictStart : start,
    end: conflictEnd.isBefore(end) ? conflictEnd : end,
    description:
        '预约“${row['title']}”'
        '（${formatDateTime(conflictStart)}–${formatDateTime(conflictEnd)}）',
  );
}

void _requireInterval(DateTime start, DateTime end) {
  if (!end.isAfter(start)) throw ArgumentError('结束时间要晚于开始时间');
}

int? _clockMinutes(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}
