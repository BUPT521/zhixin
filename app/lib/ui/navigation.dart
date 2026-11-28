/// 导航入口：页面之间只经由这里互相打开。
///
/// 页面文件名与打开它的函数一一对应，签名只带目标页面需要的参数；页面不再
/// 直接 import 另一个页面，也不再各自构造 `MaterialPageRoute`。路由只在
/// [_push] 里构造一次，以后统一换过渡动画只改这一处。
///
/// 这里只做路由：需要先读数据、推进状态或判断去向的入口放到页面侧自己的文件，
/// 由本文件转出同一个名字（见 `plan_entry.dart` 的 [openPlanItem]）。导航层因此
/// 不依赖应用服务，也不在打开页面之前改业务状态。
///
/// 同一条记录可以有多个入口时用各自的入口表达：学习页分首次进入与独立重做，
/// 讨论分已有记录与新讨论，材料详情带不带页码范围由参数决定。
library;

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'about_page.dart';
import 'account_page.dart';
import 'camera_capture_page.dart';
import 'cloud_backup_page.dart';
import 'data_version_page.dart';
import 'discussion_page.dart';
import 'embedding_settings_page.dart';
import 'feedback_page.dart';
import 'learning_page.dart';
import 'legal_document.dart';
import 'materials_page.dart';
import 'memory_page.dart';
import 'memory_proposal_page.dart';
import 'memory_search_page.dart';
import 'model_api_keys_page.dart';
import 'persona_page.dart';
import 'plan_page.dart';
import 'plan_search_page.dart';
import 'plugins_page.dart';
import 'question_crop_page.dart';
import 'records_search_page.dart';
import 'settings_page.dart';
import 'study_plan_page.dart';
import 'study_plan_list_page.dart';

export 'plan_entry.dart' show openPlanItem;

/// 打开一页：路由类型与全屏设置只在这里出现。
Future<T?> _push<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool fullscreenDialog = false,
}) => Navigator.of(context).push<T>(
  MaterialPageRoute<T>(builder: builder, fullscreenDialog: fullscreenDialog),
);

/// 打开学习页：原题、历次尝试与这一次的提示。
Future<void> openLearning(BuildContext context, String questionId) =>
    _push<void>(context, (_) => LearningPage(questionId: questionId));

/// 打开学习页并直接进入独立重做（先不看上次答案）。
Future<void> openLearningRedo(BuildContext context, String questionId) =>
    _push<void>(
      context,
      (_) => LearningPage(questionId: questionId, startRedo: true),
    );

/// 打开一条已有讨论。
Future<void> openDiscussion(BuildContext context, String conversationId) =>
    _push<void>(context, (_) => DiscussionPage(conversationId: conversationId));

/// 从首页带着文字与图片开一条新讨论；首条消息写进记录后回调调用方清草稿。
Future<void> openNewDiscussion(
  BuildContext context, {
  String initialText = '',
  List<XFile> initialImages = const [],
  VoidCallback? onSubmitted,
}) => _push<void>(
  context,
  (_) => DiscussionPage(
    startNew: true,
    initialText: initialText,
    initialImages: initialImages,
    onSubmitted: onSubmitted,
  ),
);

/// 打开一份材料的详情；从学习步骤进入时可以只显示这一步的页码。
Future<void> openMaterial(
  BuildContext context,
  String materialId, {
  int? pageFrom,
  int? pageTo,
  String? stepTitle,
  String? studyPlanId,
  String? planItemId,
}) => _push<void>(
  context,
  (_) => MaterialDetailPage(
    materialId: materialId,
    pageFrom: pageFrom,
    pageTo: pageTo,
    stepTitle: stepTitle,
    studyPlanId: studyPlanId,
    planItemId: planItemId,
  ),
);

/// 打开一条学习事项的详情；安排页本身仍是底栏页，详情走这个入口。
Future<void> openPlanDetail(BuildContext context, String itemId) =>
    _push<void>(context, (_) => PlanPage.detail(itemId: itemId));

/// 打开一份系统学习计划。
Future<void> openStudyPlanList(
  BuildContext context, {
  required VoidCallback onOpenMaterials,
}) => _push<void>(
  context,
  (_) => StudyPlanListPage(onOpenMaterials: onOpenMaterials),
);

Future<void> openStudyPlan(BuildContext context, String planId) =>
    _push<void>(context, (_) => StudyPlanPage(planId: planId));

/// 打开安排查找：按标题、目标、状态与截止日期查事项和计划步骤。
///
/// 页面里的结果点开仍走本文件的 [openPlanDetail] 与 [openPlanItem]，查找入口
/// 不另造导航逻辑。
Future<void> openPlanSearch(BuildContext context) =>
    _push<void>(context, (_) => const PlanSearchPage());

/// 打开设置页。
Future<void> openSettings(BuildContext context) =>
    _push<void>(context, (_) => const SettingsPage());

Future<void> openModelApiKeys(BuildContext context) =>
    _push<void>(context, (_) => const ModelApiKeysPage());

/// 打开记忆页。
Future<void> openMemory(BuildContext context) =>
    _push<void>(context, (_) => const MemoryPage());

/// 打开记忆查找页：按正文、类别、适用范围与状态查找。
Future<void> openMemorySearch(BuildContext context) =>
    _push<void>(context, (_) => const MemorySearchPage());

/// 打开插件设置页：启停随应用编译的第一方插件。
Future<void> openPlugins(BuildContext context) =>
    _push<void>(context, (_) => const PluginsPage());

/// 打开人格页：切换当前启用的内置人格。
Future<void> openPersona(BuildContext context) =>
    _push<void>(context, (_) => const PersonaPage());

/// 打开“从作答整理记忆”页。
Future<void> openMemoryProposal(BuildContext context) =>
    _push<void>(context, (_) => const MemoryProposalPage());

/// 打开数据版本页。
Future<void> openDataVersion(BuildContext context) =>
    _push<void>(context, (_) => const DataVersionPage());

/// 打开关于与许可页。
Future<void> openAbout(BuildContext context) =>
    _push<void>(context, (_) => const AboutPage());

/// 打开用户须知：首次启动的同意对话框、设置页“诊断与隐私”与本机模式下的账号页。
///
/// 同意对话框自己带勾选框，打开文档时传 [allowAgree] 为假，避免在文档页里直接
/// 同意；设置页与账号页的同意入口把它留作真。
Future<void> openUserTerms(BuildContext context, {bool allowAgree = true}) =>
    _push<void>(
      context,
      (_) => LegalDocumentPage.terms(allowAgree: allowAgree),
    );

/// 打开隐私政策。
Future<void> openPrivacyPolicy(BuildContext context) =>
    _push<void>(context, (_) => const LegalDocumentPage.privacy());

/// 打开账号与云同步页：服务地址、登录注册、同步状态与云端数据操作。
///
/// [reset] 为真时直接落在找回密码的表单上，首次启动引导的“忘记密码”走这一条；
/// [identifier] 是带过去预填的邮箱。
Future<void> openAccount(
  BuildContext context, {
  bool reset = false,
  String identifier = '',
}) => _push<void>(
  context,
  (_) => AccountPage(initialReset: reset, initialIdentifier: identifier),
);

/// 打开云端备份页：上传、列出、下载恢复与删除服务端保存的整库备份。
Future<void> openCloudBackup(BuildContext context) =>
    _push<void>(context, (_) => const CloudBackupPage());

/// 打开语义索引设置页。
Future<void> openEmbeddingSettings(BuildContext context) =>
    _push<void>(context, (_) => const EmbeddingSettingsPage());

/// 打开反馈页：正文必填，可附联系邮箱与本机诊断摘要，不要求登录。
Future<void> openFeedback(BuildContext context) =>
    _push<void>(context, (_) => const FeedbackPage());

/// 打开记录搜索；结果里打开学习页或讨论仍交回记录页的入口。
Future<void> openRecordsSearch(
  BuildContext context, {
  required Future<void> Function(String questionId) onOpenLearning,
  required Future<void> Function(String conversationId) onOpenDiscussion,
}) => _push<void>(
  context,
  (_) => RecordsSearchPage(
    onOpenLearning: onOpenLearning,
    onOpenDiscussion: onOpenDiscussion,
  ),
);

/// 打开应用内相机；取消或没有拍到时返回 null。
Future<XFile?> openCameraCapture(BuildContext context) => _push<XFile>(
  context,
  (_) => const CameraCapturePage(),
  fullscreenDialog: true,
);

/// 打开框选页；用户取消时返回 null，确认时返回裁剪结果。
Future<QuestionCropResult?> openQuestionCrop(
  BuildContext context, {
  required String sourcePath,
  required String outputDir,
  bool allowRetake = false,
}) => _push<QuestionCropResult>(
  context,
  (_) => QuestionCropPage(
    sourcePath: sourcePath,
    outputDir: outputDir,
    allowRetake: allowRetake,
  ),
  fullscreenDialog: true,
);
