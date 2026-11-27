import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'zhixin_toast.dart';

/// 从事项打开这一步的学习内容。
///
/// 系统学习步骤先推进到进行中，再由 `StudyPlanService.resumePoint` 推出继续位置：
/// 已经作答时回到原题，有讨论时打开讨论，否则打开这一步的材料页码。普通事项沿用
/// 讨论与原题判断；没有可打开的内容时只给一句提示，不跳到空页面。
///
/// 这段判断原先写在 `navigation.dart` 的 `openPlanItem` 里，导航层因此既构造路由
/// 又推进步骤状态与决定去向。判断本身属于应用层，最终应由 `application` 提供一次；
/// 本批的独占范围不含 `application`，先放在这个页面侧文件里，导航文件只保留路由，
/// 页面仍从 `navigation.dart` 取同一个入口。
Future<void> openPlanItem(BuildContext context, PlanItem item) async {
  final scope = AppScope.of(context);
  try {
    if (item.isStudyStep) {
      await scope.study.systemPlan.setStepStatus(
        item.studyPlanId!,
        item.id,
        PlanItemStatus.doing,
      );
      final resume = await scope.study.systemPlan.resumePoint(
        item.studyPlanId!,
        item.id,
      );
      if (!context.mounted) return;
      final materialId = resume.materialId;
      if (resume.kind == StudyStepResumeKind.question) {
        await openLearning(context, resume.conversationId!);
      } else if (resume.kind == StudyStepResumeKind.discussion) {
        await openDiscussion(context, resume.conversationId!);
      } else if (materialId != null) {
        await openMaterial(
          context,
          materialId,
          pageFrom: resume.pageFrom,
          pageTo: resume.pageTo,
          stepTitle: resume.title,
          studyPlanId: item.studyPlanId,
          planItemId: item.id,
        );
      } else {
        showToast(context, '这一步还没有关联材料，可以先在计划里补充。');
      }
      return;
    }

    final conversationId = item.conversationId;
    if (conversationId != null) {
      final record = await scope.chat.discussion.byId(conversationId);
      if (!context.mounted) return;
      if (record?.hasAttempts ?? false) {
        await openLearning(context, conversationId);
      } else {
        await openDiscussion(context, conversationId);
      }
      return;
    }
    showToast(context, '这件事项还没有可以打开的内容，可以先查看事项说明。');
  } catch (error, stack) {
    if (!context.mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '打开学习内容',
      kind: 'plan_item_open',
      kept: '事项与学习记录没有改动',
      next: '可以再试一次',
    );
    showToast(context, message);
  }
}
