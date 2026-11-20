import '../../data/db/sql.dart';
import '../../data/repository/schedule_conflicts.dart';
import '../../data/revisions/revision_models.dart';
import '../../data/revisions/revision_undo.dart';
import '../../domain/rules/time_format.dart';
import 'undo_guard_support.dart';

/// 预约冲突：撤销更新与撤销删除要核对恢复后的时间是否仍可执行。
///
/// 恢复后的时间还必须落在仍可继续安排的目标与事项上：归属的事项已经完成或
/// 暂缓、目标已经暂停或结束时不再恢复这条预约；同一条提交会把它们一起改回
/// 可继续安排的状态时例外。
class ScheduleUndoGuard implements UndoGuard {
  const ScheduleUndoGuard();

  @override
  Set<String> get tables => const {'schedule_block'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    // 撤销新增会删除预约，不需要再检查占用；撤销更新与撤销删除都要核对
    // 恢复后的时间是否仍可执行。
    if (change.op == ChangeOp.insert) return null;
    final row = change.op == ChangeOp.delete
        ? change.before!
        : mergedUndoRow(current!, change.before!);
    final status = row['status']?.value as String? ?? 'planned';
    final start = row['start_at']?.value as String?;
    final end = row['end_at']?.value as String?;
    final planItemId = row['plan_item_id']?.value as String?;
    if (start == null || end == null || planItemId == null) {
      return '预约内容不完整，不能撤销';
    }
    final item = await selectRows(
      check.executor,
      'plan_item',
      columns: ['id', 'status', 'goal_id'],
      where: 'id = ?',
      whereArgs: [planItemId],
      limit: 1,
    );
    if (item.isEmpty) return '预约对应的学习事项已经不存在';
    final itemStatus = item.first['status'] as String?;
    if ((itemStatus == 'done' || itemStatus == 'deferred') &&
        !_restoresStatus(check.commitChanges, 'plan_item', change.rowKey)) {
      return '预约对应的学习事项已经完成或暂缓，不再恢复这条预约';
    }
    final goalId = item.first['goal_id'] as String?;
    if (goalId != null) {
      final goals = await selectRows(
        check.executor,
        'learning_goal',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [goalId],
        limit: 1,
      );
      final goalStatus = goals.isEmpty
          ? null
          : goals.first['status'] as String?;
      if (goalStatus != null &&
          goalStatus != 'active' &&
          !_restoresStatus(check.commitChanges, 'learning_goal', goalId)) {
        return '预约对应的学习目标已经暂停或结束，不再恢复这条预约';
      }
    }
    if (status != 'planned') return null;

    final DateTime? startAt;
    final DateTime? endAt;
    try {
      startAt = optionalDateTime(start);
      endAt = optionalDateTime(end);
    } on FormatException {
      return '预约时间不完整，不能撤销';
    }
    if (startAt == null || endAt == null || !endAt.isAfter(startAt)) {
      return '预约时间不完整，不能撤销';
    }
    final conflict = await findScheduleConflict(
      check.executor,
      start: startAt,
      end: endAt,
      ignoredBlockIds: {change.rowKey},
    );
    if (conflict != null) {
      return '恢复后的时间与${conflict.description}冲突';
    }
    return null;
  }
}

/// 同一条提交是否会把事项或目标恢复为可以继续安排的状态。
bool _restoresStatus(
  List<RevisionChange> changes,
  String table,
  String rowKey,
) {
  for (final change in changes) {
    if (change.table != table ||
        change.rowKey != rowKey ||
        change.op != ChangeOp.update) {
      continue;
    }
    final status = change.before?['status']?.value;
    if (table == 'learning_goal' && status == 'active') return true;
    if (table == 'plan_item' && (status == 'todo' || status == 'doing')) {
      return true;
    }
  }
  return false;
}
