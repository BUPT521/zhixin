/// 目标、学习事项、一次学习、时间块与课表（01 第 4 章）。
library;

import 'material.dart';

import '../rules/time_format.dart';

enum LearningGoalStatus {
  active('active', '进行中'),
  paused('paused', '已暂停'),
  done('done', '已结束'),
  unknown('', '状态未知');

  const LearningGoalStatus(this.code, this.label);

  final String code;
  final String label;

  static LearningGoalStatus fromCode(String? value) => switch (value) {
    null || 'active' => active,
    'paused' => paused,
    'done' => done,
    _ => unknown,
  };
}

enum PlanItemStatus {
  todo('todo', '待办'),
  doing('doing', '进行中'),
  done('done', '已完成'),
  deferred('deferred', '已暂缓'),
  unknown('', '状态未知');

  const PlanItemStatus(this.code, this.label);

  final String code;
  final String label;

  bool get open => this == todo || this == doing;

  static PlanItemStatus fromCode(String? value) => switch (value) {
    null || 'todo' => todo,
    'doing' => doing,
    'done' => done,
    'deferred' => deferred,
    _ => unknown,
  };
}

/// 近期目标（01 `learning_goal`）。
class LearningGoal {
  const LearningGoal({
    required this.id,
    required this.title,
    this.scopeText,
    this.dueDate,
    this.status = LearningGoalStatus.active,
    this.createdAt,
    this.updatedAt,
  });

  factory LearningGoal.fromRow(Map<String, Object?> row) {
    return LearningGoal(
      id: row['id']! as int,
      title: row['title']! as String,
      scopeText: row['scope_text'] as String?,
      dueDate: row['due_date'] as String?,
      status: LearningGoalStatus.fromCode(row['status'] as String?),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
    );
  }

  final int id;
  final String title;
  final String? scopeText;
  final String? dueDate;

  final LearningGoalStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get active => status == LearningGoalStatus.active;
}

/// 有材料、动作与结束条件的一次学习活动（01 `plan_item`）。
///
/// 系统学习的步骤也是学习事项：`studyPlanId` 非空时，`seq` 是它在计划中的
/// 顺序，`pageFrom`、`pageTo` 是这一步覆盖的材料页码，`note` 是补充说明。
/// 排程、学习场次与完成状态因此只有一套。
class PlanItem {
  const PlanItem({
    required this.id,
    required this.title,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.materialIsDocx = false,
    this.dueAt,
    this.estMinutes,
    this.priority = 0,
    this.status = PlanItemStatus.todo,
    this.source = 'user',
    this.completedAt,
    this.createdAt,
    this.updatedAt,
  });

  factory PlanItem.fromRow(Map<String, Object?> row) {
    return PlanItem(
      id: row['id']! as int,
      goalId: row['goal_id'] as int?,
      conversationId: row['conversation_id'] as int?,
      studyPlanId: row['study_plan_id'] as int?,
      seq: row['seq'] as int?,
      title: row['title']! as String,
      note: row['note'] as String?,
      pageFrom: row['page_from'] as int?,
      pageTo: row['page_to'] as int?,
      materialIsDocx: isDocxFile(row['source_file_name'] as String?),
      dueAt: DateTime.tryParse(row['due_at'] as String? ?? ''),
      estMinutes: row['est_minutes'] as int?,
      priority: (row['priority'] as int?) ?? 0,
      status: PlanItemStatus.fromCode(row['status'] as String?),
      source: (row['source'] as String?) ?? 'user',
      completedAt: DateTime.tryParse(row['completed_at'] as String? ?? ''),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
    );
  }

  final int id;
  final int? goalId;

  /// 由哪条讨论接受而来；为空表示不是从讨论里保存的。
  final int? conversationId;

  /// 所属系统学习计划；为空表示是独立的学习事项。
  final int? studyPlanId;

  /// 在系统学习计划中的顺序；独立事项为空。
  final int? seq;
  final String title;

  /// 一段说明：要做什么、做到什么程度算完成。
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final bool materialIsDocx;
  final DateTime? dueAt;
  final int? estMinutes;

  /// 0 普通、1 优先、2 最高；容量不足时按它排序。
  final int priority;

  final PlanItemStatus status;

  /// `user` / `ai`。
  final String source;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get open => status.open;
  bool get done => status == PlanItemStatus.done;
  bool get isStudyStep => studyPlanId != null;

  String get pageLabel =>
      materialPosition(pageFrom, to: pageTo, isDocx: materialIsDocx);

  Map<String, Object?> toRow() => {
    'goal_id': goalId,
    'conversation_id': conversationId,
    'study_plan_id': studyPlanId,
    'seq': seq,
    'title': title,
    'note': note,
    'page_from': pageFrom,
    'page_to': pageTo,
    'due_at': dueAt == null ? null : formatDateTime(dueAt!),
    'est_minutes': estMinutes,
    'status': status.code,
    'source': source,
    'completed_at': completedAt == null ? null : formatDateTime(completedAt!),
  };
}

/// 一次学习（01 `study_session`）；同一次学习里的多次尝试共用它。
class StudySession {
  const StudySession({
    required this.id,
    this.goalId,
    this.planItemId,
    this.conversationId,
    this.summary,
    this.outcome,
    required this.startedAt,
    this.endedAt,
  });

  factory StudySession.fromRow(Map<String, Object?> row) {
    return StudySession(
      id: row['id']! as int,
      goalId: row['goal_id'] as int?,
      planItemId: row['plan_item_id'] as int?,
      conversationId: row['conversation_id'] as int?,
      summary: row['summary'] as String?,
      outcome: row['outcome'] as String?,
      startedAt: parseDateTime(row['started_at']! as String),
      endedAt: DateTime.tryParse(row['ended_at'] as String? ?? ''),
    );
  }

  final int id;
  final int? goalId;
  final int? planItemId;

  /// 这次学习属于哪一条学习记录；链路入口不同也按记录区分场次。
  final int? conversationId;
  final String? summary;

  /// `done` / `partial` / `not_done`；未结束时为空。
  final String? outcome;
  final DateTime startedAt;
  final DateTime? endedAt;

  bool get open => endedAt == null;

  /// 场次结果的界面说法；没有提交或都没有判断时为空。
  String? get outcomeLabel => switch (outcome) {
    'done' => '完成',
    'partial' => '部分完成',
    'not_done' => '没做成',
    _ => null,
  };
}

/// 学习事项占用的时间块（01 `schedule_block`）。
class ScheduleBlock {
  const ScheduleBlock({
    required this.id,
    required this.planItemId,
    required this.startAt,
    required this.endAt,
    this.source = 'user',
    this.status = 'planned',
    this.locked = false,
  });

  factory ScheduleBlock.fromRow(Map<String, Object?> row) {
    return ScheduleBlock(
      id: row['id']! as int,
      planItemId: row['plan_item_id']! as int,
      startAt: parseDateTime(row['start_at']! as String),
      endAt: parseDateTime(row['end_at']! as String),
      source: (row['source'] as String?) ?? 'user',
      status: (row['status'] as String?) ?? 'planned',
      locked: row['locked'] == 1,
    );
  }

  final int id;
  final int planItemId;
  final DateTime startAt;
  final DateTime endAt;

  /// `user` / `ai`；AI 只改自己的块。
  final String source;

  /// `planned` / `done` / `cancelled`。
  final String status;

  /// 固定安排：为真时容量规划不移动它。
  final bool locked;

  bool get planned => status == 'planned';

  Map<String, Object?> toRow() => {
    'plan_item_id': planItemId,
    'start_at': formatDateTime(startAt),
    'end_at': formatDateTime(endAt),
    'source': source,
    'status': status,
    'locked': locked ? 1 : 0,
  };
}

/// 时间块及其所属事项摘要；查询结果供应用服务和界面共同使用。
class ScheduledItem {
  const ScheduledItem({
    required this.block,
    required this.itemTitle,
    this.itemNote,
    this.itemStatus = PlanItemStatus.todo,
  });

  final ScheduleBlock block;
  final String itemTitle;

  /// 事项的一段说明。
  final String? itemNote;
  final PlanItemStatus itemStatus;
}

/// 课表（01 `timetable_entry`）。
class TimetableEntry {
  const TimetableEntry({
    required this.id,
    required this.weekday,
    required this.startTime,
    required this.endTime,
    required this.title,
    this.location,
  });

  factory TimetableEntry.fromRow(Map<String, Object?> row) {
    return TimetableEntry(
      id: row['id']! as int,
      weekday: row['weekday']! as int,
      startTime: row['start_time']! as String,
      endTime: row['end_time']! as String,
      title: row['title']! as String,
      location: row['location'] as String?,
    );
  }

  final int id;
  final int weekday;
  final String startTime;
  final String endTime;
  final String title;
  final String? location;

  Map<String, Object?> toRow() => {
    'weekday': weekday,
    'start_time': startTime,
    'end_time': endTime,
    'title': title,
    'location': location,
  };
}
