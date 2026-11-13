import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'discussion_page.dart';
import 'failure_feedback.dart';
import 'learning_page.dart';
import 'materials_page.dart';
import 'zhixin_toast.dart';

/// 从日程、预约或事项详情直接打开这一步的学习内容。
///
/// 系统学习步骤的继续位置统一由 [StudyPlanService.resumePoint] 推出：已经
/// 开始作答时回到原题，有讨论时打开讨论，否则打开这一步的材料页码。计划页
/// 与预约入口都走这里，入口不再各自决定打开哪种内容。普通事项没有学习步骤
/// 时沿用讨论与原题判断；没有可打开的内容时只给提示，不跳到空页面。
Future<void> openPlanItem(BuildContext context, PlanItem item) async {
  final scope = AppScope.of(context);
  final navigator = Navigator.of(context);
  try {
    if (item.isStudyStep) {
      await scope.studyPlanService.setStepStatus(
        item.studyPlanId!,
        item.id,
        PlanItemStatus.doing,
      );
      final resume = await scope.studyPlanService.resumePoint(
        item.studyPlanId!,
        item.id,
      );
      if (resume.kind == StudyStepResumeKind.question) {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => LearningPage(questionId: resume.conversationId!),
          ),
        );
        return;
      }
      if (resume.kind == StudyStepResumeKind.discussion) {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                DiscussionPage(conversationId: resume.conversationId!),
          ),
        );
        return;
      }
      final materialId = resume.materialId;
      if (materialId == null) {
        if (context.mounted) {
          showToast(context, '这一步还没有关联材料，可以先在计划里补充。');
        }
        return;
      }
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => MaterialDetailPage(
            materialId: materialId,
            pageFrom: resume.pageFrom,
            pageTo: resume.pageTo,
            stepTitle: resume.title,
            studyPlanId: item.studyPlanId,
            planItemId: item.id,
          ),
        ),
      );
      return;
    }

    final conversationId = item.conversationId;
    if (conversationId != null) {
      final record = await scope.conversations.byId(conversationId);
      if (record?.hasAttempts ?? false) {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => LearningPage(questionId: conversationId),
          ),
        );
      } else {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => DiscussionPage(conversationId: conversationId),
          ),
        );
      }
      return;
    }
    if (context.mounted) {
      showToast(context, '这件事项还没有可以打开的内容，可以先查看说明或预约时间。');
    }
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
