/// 目标、学习事项、一次学习、时间块与课表（01 第 4 章）。
library;

import '../rules/coded_enum.dart';
import 'material.dart';

enum LearningGoalStatus implements CodedEnum {
  active('active', '进行中'),
  paused('paused', '已暂停'),
  done('done', '已结束'),
  unknown('', '状态未知');

  const LearningGoalStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static LearningGoalStatus fromValue(String? value) =>
      codedValueOr(LearningGoalStatus.values, value, unknown: unknown);
}

enum PlanItemStatus implements CodedEnum {
  todo('todo', '待办'),
  doing('doing', '进行中'),
  done('done', '已完成'),
  deferred('deferred', '已暂缓'),
  unknown('', '状态未知');

  const PlanItemStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  bool get open => this == todo || this == doing;

  static PlanItemStatus fromValue(String? value) =>
      codedValueOr(PlanItemStatus.values, value, unknown: unknown);
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

  final String id;
  final String title;
  final String? scopeText;
  final String? dueDate;

  final LearningGoalStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get active => status == LearningGoalStatus.active;
}

/// 学习事项的来源（01 `plan_item.source`）：用户自己建还是搭子建议。
enum PlanItemSource implements CodedEnum {
  user('user', '你'),
  ai('ai', '搭子'),
  unknown('', '来源未知');

  const PlanItemSource(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static PlanItemSource fromValue(String? value) =>
      codedValueOr(PlanItemSource.values, value, unknown: unknown);
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
    this.source = PlanItemSource.user,
    this.completedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? goalId;

  /// 由哪条讨论接受而来；为空表示不是从讨论里保存的。
  final String? conversationId;

  /// 所属系统学习计划；为空表示是独立的学习事项。
  final String? studyPlanId;

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

  /// 这条事项由谁建立；读库时认不出的值回落到 [PlanItemSource.unknown]。
  final PlanItemSource source;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get open => status.open;
  bool get done => status == PlanItemStatus.done;
  bool get isStudyStep => studyPlanId != null;

  String get pageLabel =>
      materialPosition(pageFrom, to: pageTo, isDocx: materialIsDocx);
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

  final String id;
  final String? goalId;
  final String? planItemId;

  /// 这次学习属于哪一条学习记录；链路入口不同也按记录区分场次。
  final String? conversationId;
  final String? summary;

  /// 场次结果；未结束时为空。
  final SessionOutcome? outcome;
  final DateTime startedAt;
  final DateTime? endedAt;

  bool get open => endedAt == null;

  /// 场次结果的界面说法；没有提交或都没有判断时为空。
  String? get outcomeLabel => outcome?.label;
}

/// 时间块状态（01 `schedule_block.status`）。
enum ScheduleBlockStatus implements CodedEnum {
  planned('planned', '待开始'),
  done('done', '已结束'),
  cancelled('cancelled', '已取消'),
  unknown('', '状态未知');

  const ScheduleBlockStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static ScheduleBlockStatus fromValue(String? value) =>
      codedValueOr(ScheduleBlockStatus.values, value, unknown: unknown);
}

/// 学习事项占用的时间块（01 `schedule_block`）。
class ScheduleBlock {
  const ScheduleBlock({
    required this.id,
    required this.planItemId,
    required this.startAt,
    required this.endAt,
    this.source = PlanItemSource.user,
    this.status = ScheduleBlockStatus.planned,
    this.locked = false,
  });

  final String id;
  final String planItemId;
  final DateTime startAt;
  final DateTime endAt;

  /// 这条预约由谁建立，AI 只改自己的块。
  final PlanItemSource source;

  /// 时间块状态；读库时认不出的值回落到 [ScheduleBlockStatus.unknown]。
  final ScheduleBlockStatus status;

  /// 固定安排：为真时容量规划不移动它。
  final bool locked;

  bool get planned => status == ScheduleBlockStatus.planned;
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

  final String id;
  final int weekday;
  final String startTime;
  final String endTime;
  final String title;
  final String? location;
}

/// 一次学习的最终结果；数据库里存的是 [value]。
enum SessionOutcome {
  done('done', '完成'),
  partial('partial', '部分完成'),
  notDone('not_done', '没做成');

  const SessionOutcome(this.value, this.label);

  final String value;
  final String label;

  /// 未知或空值按没有结果处理，不把坏数据当成完成。
  static SessionOutcome? fromValue(String? value) {
    for (final outcome in values) {
      if (outcome.value == value) return outcome;
    }
    return null;
  }
}
