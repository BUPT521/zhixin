/// 导航入口：页面之间只经由这里互相打开。
///
/// 页面文件名与打开它的函数一一对应，签名只带目标页面需要的参数；页面不再
/// 直接 import 另一个页面，也不再各自构造 `MaterialPageRoute`。路由类型留在
/// 这个文件里，以后统一换过渡动画只改一处。
///
/// 同一条记录可以有多个入口时用各自的入口表达：学习页分首次进入与独立重做，
/// 讨论分已有记录与新讨论，材料详情带不带页码范围由参数决定。
library;

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'about_page.dart';
import 'camera_capture_page.dart';
import 'data_version_page.dart';
import 'discussion_page.dart';
import 'embedding_settings_page.dart';
import 'failure_feedback.dart';
import 'learning_page.dart';
import 'materials_page.dart';
import 'memory_page.dart';
import 'memory_proposal_page.dart';
import 'persona_page.dart';
import 'plan_page.dart';
import 'plugins_page.dart';
import 'question_crop_page.dart';
import 'records_search_page.dart';
import 'settings_page.dart';
import 'study_plan_page.dart';
import 'zhixin_toast.dart';

/// 打开学习页：原题、历次尝试与这一次的提示。
Future<void> openLearning(BuildContext context, String questionId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LearningPage(questionId: questionId),
    ),
  );
}

/// 打开学习页并直接进入独立重做（先不看上次答案）。
Future<void> openLearningRedo(BuildContext context, String questionId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LearningPage(questionId: questionId, startRedo: true),
    ),
  );
}

/// 打开一条已有讨论。
Future<void> openDiscussion(BuildContext context, String conversationId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DiscussionPage(conversationId: conversationId),
    ),
  );
}

/// 从首页带着文字与图片开一条新讨论；首条消息写进记录后回调调用方清草稿。
Future<void> openNewDiscussion(
  BuildContext context, {
  String initialText = '',
  List<XFile> initialImages = const [],
  VoidCallback? onSubmitted,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DiscussionPage(
        startNew: true,
        initialText: initialText,
        initialImages: initialImages,
        onSubmitted: onSubmitted,
      ),
    ),
  );
}

/// 打开一份材料的详情；从学习步骤进入时可以只显示这一步的页码。
Future<void> openMaterial(
  BuildContext context,
  String materialId, {
  int? pageFrom,
  int? pageTo,
  String? stepTitle,
  String? studyPlanId,
  String? planItemId,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MaterialDetailPage(
        materialId: materialId,
        pageFrom: pageFrom,
        pageTo: pageTo,
        stepTitle: stepTitle,
        studyPlanId: studyPlanId,
        planItemId: planItemId,
      ),
    ),
  );
}

/// 打开一条学习事项的详情；安排页本身仍是底栏页，详情走这个入口。
Future<void> openPlanDetail(BuildContext context, String itemId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => PlanPage.detail(itemId: itemId)),
  );
}

/// 打开一份系统学习计划。
Future<void> openStudyPlan(BuildContext context, String planId) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => StudyPlanPage(planId: planId)),
  );
}

/// 打开设置页。
Future<void> openSettings(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
}

/// 打开记忆页。
Future<void> openMemory(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const MemoryPage()));
}

/// 打开插件设置页：启停随应用编译的第一方插件。
Future<void> openPlugins(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const PluginsPage()));
}

/// 打开人格页：切换当前启用的内置人格。
Future<void> openPersona(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const PersonaPage()));
}

/// 打开“从作答整理记忆”页。
Future<void> openMemoryProposal(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const MemoryProposalPage()));
}

/// 打开数据版本页。
Future<void> openDataVersion(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const DataVersionPage()));
}

/// 打开关于与许可页。
Future<void> openAbout(BuildContext context) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));
}

/// 打开语义索引设置页。
Future<void> openEmbeddingSettings(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const EmbeddingSettingsPage()),
  );
}

/// 打开记录搜索；结果里打开学习页或讨论仍交回记录页的入口。
Future<void> openRecordsSearch(
  BuildContext context, {
  required Future<void> Function(String questionId) onOpenLearning,
  required Future<void> Function(String conversationId) onOpenDiscussion,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RecordsSearchPage(
        onOpenLearning: onOpenLearning,
        onOpenDiscussion: onOpenDiscussion,
      ),
    ),
  );
}

/// 打开应用内相机；取消或没有拍到时返回 null。
Future<XFile?> openCameraCapture(BuildContext context) {
  return Navigator.of(context).push<XFile>(
    MaterialPageRoute<XFile>(
      fullscreenDialog: true,
      builder: (_) => const CameraCapturePage(),
    ),
  );
}

/// 打开框选页；用户取消时返回 null，确认时返回裁剪结果。
Future<QuestionCropResult?> openQuestionCrop(
  BuildContext context, {
  required String sourcePath,
  required String outputDir,
  bool allowRetake = false,
}) {
  return Navigator.of(context).push<QuestionCropResult>(
    MaterialPageRoute<QuestionCropResult>(
      fullscreenDialog: true,
      builder: (_) => QuestionCropPage(
        sourcePath: sourcePath,
        outputDir: outputDir,
        allowRetake: allowRetake,
      ),
    ),
  );
}

/// 从日程、预约或事项详情直接打开这一步的学习内容。
///
/// 系统学习步骤的继续位置统一由 `StudyPlanService.resumePoint` 推出：已经
/// 开始作答时回到原题，有讨论时打开讨论，否则打开这一步的材料页码。计划页
/// 与预约入口都走这里，入口不再各自决定打开哪种内容。普通事项没有学习步骤
/// 时沿用讨论与原题判断；没有可打开的内容时只给提示，不跳到空页面。
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
    showToast(context, '这件事项还没有可以打开的内容，可以先查看说明或预约时间。');
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
