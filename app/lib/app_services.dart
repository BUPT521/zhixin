import 'ai/ai_chat_service.dart';
import 'application/capacity_service.dart';
import 'application/continue_service.dart';
import 'application/context_service.dart';
import 'application/discussion_service.dart';
import 'application/learning_service.dart';
import 'application/material_service.dart';
import 'application/memory_proposal_service.dart';
import 'application/memory_service.dart';
import 'application/plan_service.dart';
import 'application/search_service.dart';
import 'application/semantic_index_service.dart';
import 'application/settings_service.dart';
import 'application/study_plan_service.dart';
import 'data/backup/data_version_service.dart';
import 'data/backup/restore_point_store.dart';
import 'data/revisions/revision_service.dart';
import 'data/vector/embedding_config_store.dart';

/// 应用根持有的全部服务，按使用场景分成六组。
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
  });

  final ChatServices chat;
  final StudyServices study;
  final LibraryServices library;
  final MemoryServices memory;
  final SettingsServices settings;
  final DataServices data;
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

/// 安排与系统学习：事项、预约、时间预算与首页的继续入口。
class StudyServices {
  const StudyServices({
    required this.plan,
    required this.systemPlan,
    required this.capacity,
    required this.continueLast,
  });

  final PlanService plan;
  final StudyPlanService systemPlan;
  final CapacityService capacity;
  final ContinueService continueLast;
}

/// 材料与检索：材料页、原文与语义检索、跨次综合。
class LibraryServices {
  const LibraryServices({
    required this.material,
    required this.search,
    required this.semanticIndexFactory,
  });

  final MaterialService material;
  final SearchService search;

  /// 语义索引按需创建；没有配置时不打开向量库。
  final SemanticIndexService Function() semanticIndexFactory;

  SemanticIndexService get semanticIndex => semanticIndexFactory();
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
  final EmbeddingConfigStore embedding;

  final BuddyAi Function() aiFactory;

  BuddyAi get ai => aiFactory();
}

/// 数据版本、数据包与附件缓存。
class DataServices {
  const DataServices({
    required this.revisions,
    required this.restorePoints,
    required this.versions,
  });

  final RevisionService revisions;
  final RestorePointStore restorePoints;

  /// 数据包、整库恢复、恢复点与清空；页面只从这里做写路径操作。
  final DataVersionService versions;
}
