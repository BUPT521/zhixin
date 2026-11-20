import '../../data/repository/schedule_conflicts.dart';
import '../../data/revisions/revision_models.dart';
import '../../data/revisions/revision_undo.dart';
import 'undo_guard_support.dart';

/// 课表：撤销删除会把这一节课重新加回每周课表，先核对现有待开始预约。
///
/// 新增课表本来就会反向查预约（2026-11-11 判例），撤销删除也要走同一份规则；
/// 撤销新增只是删除课表，不需要检查。
class TimetableUndoGuard implements UndoGuard {
  const TimetableUndoGuard();

  @override
  Set<String> get tables => const {'timetable_entry'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    if (change.op == ChangeOp.insert) return null;
    final row = change.op == ChangeOp.delete
        ? change.before!
        : mergedUndoRow(current!, change.before!);
    final weekday = row['weekday']?.value as int?;
    final start = row['start_time']?.value as String?;
    final end = row['end_time']?.value as String?;
    if (weekday == null || start == null || end == null) {
      return '课表内容不完整，不能撤销';
    }
    final conflict = await findRecurringTimetableConflict(
      check.executor,
      weekday: weekday,
      startTime: start,
      endTime: end,
      now: check.clock(),
    );
    if (conflict != null) {
      return '恢复课表后的时间与${conflict.description}冲突';
    }
    return null;
  }
}
