import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'zhixin_toast.dart';

/// 从事项打开这一步的学习内容。
///
/// 去向由 `StudyPlanService.entryFor` 判断：系统学习步骤先推进到进行中，再由
/// 继续位置决定打开原题、讨论还是材料页码；普通事项按绑定的讨论是否已经作答
/// 决定。这里只按返回值导航，附带失败说明；判断本身不再写在页面侧文件里
/// （批 8 的收尾）。
Future<void> openPlanItem(BuildContext context, PlanItem item) async {
  final scope = AppScope.of(context);
  try {
    final entry = await scope.study.systemPlan.entryFor(item);
    if (!context.mounted) return;
    switch (entry) {
      case PlanItemEntryQuestion(:final conversationId):
        await openLearning(context, conversationId);
      case PlanItemEntryDiscussion(:final conversationId):
        await openDiscussion(context, conversationId);
      case PlanItemEntryMaterial(
        :final materialId,
        :final pageFrom,
        :final pageTo,
        :final stepTitle,
        :final studyPlanId,
        :final planItemId,
      ):
        await openMaterial(
          context,
          materialId,
          pageFrom: pageFrom,
          pageTo: pageTo,
          stepTitle: stepTitle,
          studyPlanId: studyPlanId,
          planItemId: planItemId,
        );
      case PlanItemEntryNone(:final message):
        showToast(context, message);
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
