import '../../data/db/sql.dart';
import '../../domain/models/revision_models.dart';
import '../../data/revisions/revision_undo.dart';

/// 学习事项的撤销要避开级联删除后续数据。
///
/// 撤销新建会删除这项事项，已有学习场次或系统学习计划归属时不删；
/// 撤销删除会重新插入，原来的目标、讨论或计划已经不存在时不插。
class PlanItemUndoGuard implements UndoGuard {
  const PlanItemUndoGuard();

  @override
  Set<String> get tables => const {'plan_item'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    if (change.op == ChangeOp.insert) {
      if (current == null) return null;
      final planId = current['study_plan_id'];
      if (planId != null && !planId.isNull) {
        return '这项任务已归入系统学习计划，不能撤销';
      }
      final sessions = await selectRows(
        check.executor,
        'study_session',
        columns: ['id'],
        where: 'plan_item_id = ?',
        whereArgs: [change.rowKey],
        limit: 1,
      );
      if (sessions.isNotEmpty) return '这项任务已有学习记录，不能撤销';
      return null;
    }
    if (change.op == ChangeOp.delete) {
      final row = change.before!;
      final references = <(String table, RevisionValue?)>[
        ('learning_goal', row['goal_id']),
        ('conversation', row['conversation_id']),
        ('study_plan', row['study_plan_id']),
      ];
      for (final (table, value) in references) {
        if (value == null || value.isNull) continue;
        final rows = await selectRows(
          check.executor,
          table,
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [value.value],
          limit: 1,
        );
        if (rows.isEmpty) {
          return '这项任务原来归属的目标、讨论或计划已经不存在，不能撤销删除';
        }
      }
    }
    return null;
  }
}
