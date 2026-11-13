import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/models/study_plan.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';
import 'task_repository.dart';

/// 系统学习计划与它的步骤（01 `study_plan` / `plan_item`）。
///
/// 计划保存材料范围、当前页码与状态；步骤本身就是学习事项，按 `seq` 排列，
/// 完成一步后继续位置前移。临时求助不改变计划位置，返回时按当前步骤继续。
/// 步骤的排程与完成状态和普通事项共用，不再另存一张生命周期表。
class StudyPlanRepository {
  StudyPlanRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  /// 计划里下一个要做的一步：进行中的优先，其次按步骤顺序取第一个待学。
  static const String _nextStepTitle =
      "(SELECT pi.title FROM plan_item pi WHERE pi.study_plan_id = sp.id "
      "AND pi.status IN ('doing', 'todo') "
      "ORDER BY CASE pi.status WHEN 'doing' THEN 0 ELSE 1 END, pi.seq, pi.id "
      'LIMIT 1) AS next_step_title';

  /// 计划列表共用的列：进度、材料标题与下一步都从这里带出。
  static const String _planColumns = '''
      SELECT sp.*, (SELECT title FROM material WHERE id = sp.material_id)
        AS material_title,
        (SELECT source_file_name FROM material WHERE id = sp.material_id)
          AS source_file_name,
        (SELECT COUNT(*) FROM plan_item pi
          WHERE pi.study_plan_id = sp.id AND pi.status = ?) AS steps_done,
        (SELECT COUNT(*) FROM plan_item pi WHERE pi.study_plan_id = sp.id)
          AS steps_total,
        $_nextStepTitle''';

  Future<int> create({
    required String title,
    int? materialId,
    int? goalId,
    int? conversationId,
    int? pageFrom,
    int? pageTo,
    int? currentPage,
    RawExecutor? executor,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('学习计划的标题不能为空');
    final now = formatDateTime(_clock());
    return (executor ?? _db).insert('study_plan', {
      'material_id': materialId,
      'goal_id': goalId,
      'conversation_id': conversationId,
      'title': text,
      'page_from': pageFrom,
      'page_to': pageTo,
      'current_page': currentPage,
      'status': StudyPlanStatus.active.code,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 在同一事务内创建学习计划及其全部步骤。
  Future<int> createWithDrafts({
    required String title,
    required List<StudyStepDraft> drafts,
    int? materialId,
    int? goalId,
    int? conversationId,
    int? pageFrom,
    int? pageTo,
    int? currentPage,
  }) {
    return _db.transaction((txn) async {
      final planId = await create(
        title: title,
        materialId: materialId,
        goalId: goalId,
        conversationId: conversationId,
        pageFrom: pageFrom,
        pageTo: pageTo,
        currentPage: currentPage,
        executor: txn,
      );
      final now = formatDateTime(_clock());
      var seq = 1;
      for (final draft in drafts) {
        final stepTitle = draft.title.trim();
        if (stepTitle.isEmpty) continue;
        await txn.insert('plan_item', {
          'goal_id': goalId,
          'conversation_id': null,
          'study_plan_id': planId,
          'seq': seq++,
          'title': stepTitle,
          'note': draft.isPrerequisite
              ? '此前未接触的必要内容${draft.note == null ? '' : '：${draft.note}'}'
              : draft.note,
          'page_from': draft.pageFrom,
          'page_to': draft.pageTo,
          'priority': 0,
          'status': PlanItemStatus.todo.code,
          'source': 'user',
          'created_at': now,
          'updated_at': now,
        });
      }
      return planId;
    });
  }

  /// 按顺序把草案写成学习事项；计划的材料、目标与来源讨论一并带上。
  Future<void> addDrafts(int planId, List<StudyStepDraft> drafts) async {
    final plan = await byId(planId);
    if (plan == null) throw StateError('未找到这份学习计划');
    final now = formatDateTime(_clock());
    await _db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(seq), 0) AS last FROM plan_item '
        'WHERE study_plan_id = ?',
        [planId],
      );
      var seq = ((rows.first['last'] as int?) ?? 0) + 1;
      for (final draft in drafts) {
        final title = draft.title.trim();
        if (title.isEmpty) continue;
        await txn.insert('plan_item', {
          'goal_id': plan.goalId,
          'conversation_id': null,
          'study_plan_id': planId,
          'seq': seq++,
          'title': title,
          'note': draft.isPrerequisite
              ? '此前未接触的必要内容${draft.note == null ? '' : '：${draft.note}'}'
              : draft.note,
          'page_from': draft.pageFrom,
          'page_to': draft.pageTo,
          'priority': 0,
          'status': PlanItemStatus.todo.code,
          'source': 'user',
          'created_at': now,
          'updated_at': now,
        });
      }
    });
  }

  Future<StudyPlan?> byId(int id) async {
    final rows = await _db.rawQuery(
      '''
      $_planColumns
      FROM study_plan sp WHERE sp.id = ?
      ''',
      [PlanItemStatus.done.code, id],
    );
    return rows.isEmpty ? null : StudyPlan.fromRow(rows.first);
  }

  /// 计划列表：进行中的排在前面，再按更新时间倒序。
  Future<List<StudyPlan>> list({bool openOnly = false}) async {
    final rows = await _db.rawQuery(
      '''
      $_planColumns
      FROM study_plan sp
      ${openOnly ? 'WHERE sp.status IN (?, ?)' : ''}
      ORDER BY CASE sp.status WHEN ? THEN 0 WHEN ? THEN 1
        ELSE 2 END, sp.updated_at DESC, sp.id DESC
      ''',
      [
        PlanItemStatus.done.code,
        if (openOnly) ...[
          StudyPlanStatus.active.code,
          StudyPlanStatus.paused.code,
        ],
        StudyPlanStatus.active.code,
        StudyPlanStatus.paused.code,
      ],
    );
    return rows.map(StudyPlan.fromRow).toList(growable: false);
  }

  /// 最近推进过的进行中计划，只按更新时间倒序，取前 [limit] 份。
  ///
  /// 首页的“继续上次”把计划与讨论放在一起按时间排序，这里不能先按状态分组：
  /// 状态优先的顺序会让一份较早推进的计划挤掉另一份更近的，合并排序也就取不到
  /// 真正最近的几条。暂停的计划不进入首页，因此这里直接不读，不占名额。
  Future<List<StudyPlan>> listRecentlyAdvanced({int limit = 4}) async {
    if (limit <= 0) return const [];
    final rows = await _db.rawQuery(
      '''
      $_planColumns
      FROM study_plan sp
      WHERE sp.status = ?
      ORDER BY sp.updated_at DESC, sp.id DESC
      LIMIT ?
      ''',
      [PlanItemStatus.done.code, StudyPlanStatus.active.code, limit],
    );
    return rows.map(StudyPlan.fromRow).toList(growable: false);
  }

  /// 计划里的步骤，按顺序返回；每一步都是 `plan_item`。
  Future<List<PlanItem>> steps(int planId) async {
    final rows = await _db.rawQuery(
      'SELECT ${TaskRepository.itemColumns} FROM plan_item p '
      'WHERE p.study_plan_id = ? ORDER BY p.seq, p.id',
      [planId],
    );
    return rows.map(PlanItem.fromRow).toList(growable: false);
  }

  /// 多份计划的全部步骤，按计划与顺序返回；安排页的下一步与进度都从这里算。
  Future<List<PlanItem>> stepsForPlans(Iterable<int> planIds) async {
    final ids = {...planIds};
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db.rawQuery(
      'SELECT ${TaskRepository.itemColumns} FROM plan_item p '
      'WHERE p.study_plan_id IN ($placeholders) ORDER BY p.study_plan_id, p.seq, p.id',
      ids.toList(growable: false),
    );
    return rows.map(PlanItem.fromRow).toList(growable: false);
  }

  Future<void> bindDiscussionToStep({
    required int planId,
    required int stepId,
    required int conversationId,
    required WriteTransaction transaction,
  }) async {
    final changed = await writeExecutor(transaction, _db).update(
      'plan_item',
      {'conversation_id': conversationId},
      where: 'id = ? AND study_plan_id = ?',
      whereArgs: [stepId, planId],
    );
    if (changed != 1) throw StateError('学习步骤已变化，无法保存讨论入口');
  }

  /// 改一步的状态；进行中的步骤同时清掉同计划里其他进行中的步骤。
  Future<void> setStepStatus(
    int stepId,
    PlanItemStatus status, {
    int? expectedPlanId,
  }) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'plan_item',
        columns: ['study_plan_id'],
        where: 'id = ?',
        whereArgs: [stepId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final planId = rows.first['study_plan_id'] as int?;
      if (planId == null) return;
      if (expectedPlanId != null && expectedPlanId != planId) {
        throw StateError('这一步不属于当前学习计划');
      }
      await _setItemStatus(txn, stepId, status, planId);
      await _recompute(txn, planId);
    });
  }

  /// 所有事项状态入口共用计划步骤的唯一进行中规则。
  Future<void> setItemStatus(int itemId, PlanItemStatus status) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'plan_item',
        columns: ['study_plan_id'],
        where: 'id = ?',
        whereArgs: [itemId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final planId = rows.single['study_plan_id'] as int?;
      await _setItemStatus(txn, itemId, status, planId);
      if (planId != null) await _recompute(txn, planId);
    });
  }

  Future<void> _setItemStatus(
    RawExecutor txn,
    int itemId,
    PlanItemStatus status,
    int? planId,
  ) async {
    final now = formatDateTime(_clock());
    await txn.update(
      'plan_item',
      {
        'status': status.code,
        'completed_at': status == PlanItemStatus.done ? now : null,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [itemId],
    );
    if (status == PlanItemStatus.doing && planId != null) {
      await txn.update(
        'plan_item',
        {'status': PlanItemStatus.todo.code, 'updated_at': now},
        where: 'study_plan_id = ? AND id != ? AND status = ?',
        whereArgs: [planId, itemId, PlanItemStatus.doing.code],
      );
    }
    if (status == PlanItemStatus.done) {
      // 只有确实发生过学习的预约才记为结束：场次与这段时间有重叠才算完成。
      // 到过开始时间却没有场次的旧预约按取消处理，不再把没学的那几次写成完成。
      await txn.rawUpdate(
        'UPDATE schedule_block SET status = CASE WHEN EXISTS ('
        'SELECT 1 FROM study_session s WHERE s.plan_item_id = schedule_block.plan_item_id '
        'AND s.started_at < schedule_block.end_at '
        'AND COALESCE(s.ended_at, ?) > schedule_block.start_at'
        ') THEN ? ELSE ? END, updated_at = ? '
        'WHERE plan_item_id = ? AND status = ?',
        [now, 'done', 'cancelled', now, itemId, 'planned'],
      );
    }
    if (status == PlanItemStatus.deferred) {
      await txn.update(
        'schedule_block',
        {'status': 'cancelled', 'updated_at': now},
        where: "plan_item_id = ? AND status = 'planned'",
        whereArgs: [itemId],
      );
    }
  }

  Future<void> setStatus(int planId, StudyPlanStatus status) async {
    await _db.update(
      'study_plan',
      {'status': status.code, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [planId],
    );
  }

  Future<void> _recompute(RawExecutor executor, int planId) async {
    final plan = await _plainPlan(planId, executor: executor);
    if (plan == null) return;
    final rows = await executor.query(
      'plan_item',
      where: 'study_plan_id = ?',
      whereArgs: [planId],
      orderBy: 'seq, id',
    );
    final allSteps = rows.map(PlanItem.fromRow).toList(growable: false);
    final current = currentStudyStep(allSteps);
    final donePages = allSteps
        .where((step) => step.done && step.pageTo != null)
        .map((step) => step.pageTo!)
        .toList(growable: false);
    final currentPage =
        current?.pageFrom ??
        (donePages.isEmpty ? plan.currentPage : donePages.last);
    final finished = allSteps.isNotEmpty && allSteps.every((step) => step.done);
    final status = finished
        ? StudyPlanStatus.done
        : plan.done
        ? StudyPlanStatus.active
        : plan.status;
    if (currentPage == plan.currentPage && status == plan.status) return;
    await executor.update(
      'study_plan',
      {
        'current_page': currentPage,
        if (status != plan.status) 'status': status.code,
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [planId],
    );
  }

  Future<StudyPlan?> _plainPlan(int id, {RawExecutor? executor}) async {
    final rows = await (executor ?? _db).query(
      'study_plan',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : StudyPlan.fromRow(rows.first);
  }
}
