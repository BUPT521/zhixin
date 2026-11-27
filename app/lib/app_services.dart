import 'ai/ai_chat_service.dart';
import 'application/account_service.dart';
import 'application/active_report_service.dart';
import 'application/cloud_backup_service.dart';
import 'application/continue_service.dart';
import 'application/context_service.dart';
import 'application/discussion_service.dart';
import 'application/embedding_settings.dart';
import 'application/feedback_service.dart';
import 'application/learning_service.dart';
import 'application/material_search.dart';
import 'application/material_service.dart';
import 'application/memory_proposal_service.dart';
import 'application/memory_service.dart';
import 'application/plan_service.dart';
import 'application/search_service.dart';
import 'application/search_index_service.dart';
import 'application/settings_service.dart';
import 'application/study_plan_service.dart';
import 'application/sync_service.dart';
import 'application/undo_service.dart';
import 'application/update_check_service.dart';
import 'data/backup/data_version_service.dart';
import 'data/revisions/revision_service.dart';
import 'plugins/persona/persona_catalog.dart';
import 'plugins/runtime/plugin_runtime.dart';

/// 应用根持有的全部服务，按使用场景分成八组。
///
/// 页面只从这里取服务，装配顺序仍留在 [AppScopeState]；分组只决定从哪里
/// 找，不改变服务之间的依赖。
class AppServices {
  const AppServices({
    required this.chat,
    required this.study,
    required this.library,
    required this.memory,
    required this.settings,
    required this.data,
    required this.plugins,
    required this.account,
  });

  final ChatServices chat;
  final StudyServices study;
  final LibraryServices library;
  final MemoryServices memory;
  final SettingsServices settings;
  final DataServices data;
  final PluginServices plugins;
  final AccountServices account;
}

/// 讨论与作答：两条回答路径共用同一份上下文、记忆范围与提交历史。
class ChatServices {
  const ChatServices({
    required this.discussion,
    required this.learning,
    required this.context,
  });

  final DiscussionService discussion;
  final LearningService learning;
  final ContextService context;
}

/// 安排与系统学习：事项、目标与首页的继续入口。
class StudyServices {
  const StudyServices({
    required this.plan,
    required this.systemPlan,
    required this.continueLast,
  });

  final PlanService plan;
  final StudyPlanService systemPlan;
  final ContinueService continueLast;
}

/// 材料与检索：材料页、原文与语义检索、跨次综合。
class LibraryServices {
  const LibraryServices({
    required this.material,
    required this.materialSearch,
    required this.search,
    required this.searchIndexFactory,
  });

  final MaterialService material;

  /// 材料列表、材料详情与材料选择器共用的本地查找；不调用模型。
  final MaterialSearchService materialSearch;

  final SearchService search;

  /// 检索索引按需创建；索引同时服务关键词与语义，没有配置时只建全文索引。
  final SearchIndexService Function() searchIndexFactory;

  SearchIndexService get searchIndex => searchIndexFactory();
}

/// 记忆页与记忆建议。
class MemoryServices {
  const MemoryServices({required this.edit, required this.proposals});

  final MemoryService edit;
  final MemoryProposalService proposals;
}

/// 设置：配置保存、模型凭据、嵌入来源与回答来源。
class SettingsServices {
  const SettingsServices({
    required this.edit,
    required this.embedding,
    required this.aiFactory,
  });

  final SettingsService edit;
  final EmbeddingSettingsService embedding;

  final BuddyAi Function() aiFactory;

  BuddyAi get ai => aiFactory();
}

/// 数据版本、数据包、恢复点与附件缓存。
class DataServices {
  const DataServices({
    required this.revisions,
    required this.versions,
    required this.undo,
  });

  final RevisionService revisions;

  /// 数据包、整库恢复、恢复点与清空；页面只从这里做写路径操作。
  final DataVersionService versions;

  /// 撤销一条提交；撤销成功之后由应用层刷新截止小时。
  final UndoService undo;
}

/// 插件运行时与人格清单：启停、权限与当前人格都从这里取。
class PluginServices {
  const PluginServices({required this.runtime, required this.personas});

  /// 注册第一方插件、读写启停状态、在调用点核对权限。
  final PluginRuntime runtime;

  /// 人格列表与当前启用项；提示词只读启用项，页面用它列预置与切换。
  final PersonaCatalog personas;
}

/// 账号与云同步：登录状态、云端整库备份与按提交的增量同步。
class AccountServices {
  const AccountServices({
    required this.account,
    required this.backups,
    required this.sync,
    required this.activeReport,
    required this.updates,
    required this.feedback,
  });

  final AccountService account;
  final CloudBackupService backups;
  final SyncService sync;

  /// 不登录时的匿名活跃上报，见 ADR-0019。
  final ActiveReportService activeReport;

  /// 应用内更新检查：读公开清单，核对 https、哈希与签名，见 ADR-0025。
  final UpdateCheckService updates;

  /// 应用内反馈：不要求登录，提交到当前服务地址。
  final FeedbackService feedback;
}
