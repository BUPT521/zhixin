/// 系统学习计划（01 `study_plan`）。
///
/// 计划只保存材料范围、步骤顺序、继续位置与状态；每一步都是 `plan_item`，
/// 因此和普通学习事项共用排程与完成状态。
library;

import 'study.dart';
import 'material.dart';
import '../rules/content_identity.dart' as identity;

enum StudyPlanStatus {
  active('active', '进行中'),
  paused('paused', '已暂停'),
  done('done', '已完成'),
  unknown('', '状态未知');

  const StudyPlanStatus(this.code, this.label);

  final String code;
  final String label;

  static StudyPlanStatus fromCode(String? value) => switch (value) {
    null || 'active' => active,
    'paused' => paused,
    'done' => done,
    _ => unknown,
  };
}

/// 系统学习的一步草案；模型建议与本地方案共用这份领域数据。
class StudyStepDraft {
  const StudyStepDraft({
    required this.title,
    this.pageFrom,
    this.pageTo,
    this.note,
    this.isPrerequisite = false,
  });

  final String title;
  final int? pageFrom;
  final int? pageTo;
  final String? note;
  final bool isPrerequisite;

  String get contentId => identity.contentId('study-step', [
    title.trim(),
    pageFrom,
    pageTo,
    note?.trim() ?? '',
    isPrerequisite,
  ]);
}

/// 一份按材料范围建立的学习计划。
class StudyPlan {
  const StudyPlan({
    required this.id,
    required this.title,
    this.materialId,
    this.goalId,
    this.conversationId,
    this.pageFrom,
    this.pageTo,
    this.currentPage,
    this.status = StudyPlanStatus.active,
    this.materialTitle,
    this.materialIsDocx = false,
    this.stepsDone = 0,
    this.stepsTotal = 0,
    this.nextStepTitle,
    this.createdAt,
    this.updatedAt,
  });

  factory StudyPlan.fromRow(Map<String, Object?> row) {
    return StudyPlan(
      id: row['id']! as int,
      title: row['title']! as String,
      materialId: row['material_id'] as int?,
      goalId: row['goal_id'] as int?,
      conversationId: row['conversation_id'] as int?,
      pageFrom: row['page_from'] as int?,
      pageTo: row['page_to'] as int?,
      currentPage: row['current_page'] as int?,
      status: StudyPlanStatus.fromCode(row['status'] as String?),
      materialTitle: row['material_title'] as String?,
      materialIsDocx: isDocxFile(row['source_file_name'] as String?),
      stepsDone: (row['steps_done'] as int?) ?? 0,
      stepsTotal: (row['steps_total'] as int?) ?? 0,
      nextStepTitle: row['next_step_title'] as String?,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
    );
  }

  final int id;
  final String title;
  final int? materialId;
  final int? goalId;

  /// 从哪条讨论开始这份学习；为空表示直接从材料建立。
  final int? conversationId;
  final int? pageFrom;
  final int? pageTo;

  /// 继续位置：下一步或正在学的那一页。
  final int? currentPage;

  final StudyPlanStatus status;
  final String? materialTitle;
  final bool materialIsDocx;
  final int stepsDone;
  final int stepsTotal;

  /// 计划里下一个要做的一步；查询带出，没有未完成步骤时为空。
  final String? nextStepTitle;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get open => status == StudyPlanStatus.active;
  bool get done => status == StudyPlanStatus.done;

  String get statusLabel => status.label;

  String get progressLabel {
    if (stepsTotal == 0) return '还没有步骤';
    final page = currentPage == null
        ? ''
        : ' · 当前${materialPosition(currentPage, isDocx: materialIsDocx)}';
    return '$stepsDone/$stepsTotal 步$page';
  }
}

PlanItem? currentStudyStep(Iterable<PlanItem> steps) => steps
    .where((step) => step.status == PlanItemStatus.doing)
    .followedBy(steps.where((step) => step.status == PlanItemStatus.todo))
    .firstOrNull;
