import 'dart:async';
import 'dart:typed_data';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:sqflite/sqflite.dart';

import 'ai/ai_chat_service.dart';
import 'app_services.dart';
import 'ai/llm_config_store.dart';
import 'application/context_service.dart';
import 'application/brought_sources.dart';
import 'application/capacity_service.dart';
import 'application/continue_service.dart';
import 'application/cross_session_service.dart';
import 'application/embedding_settings.dart';
import 'application/discussion_service.dart';
import 'application/evidence_service.dart';
import 'application/learning_service.dart';
import 'application/material_service.dart';
import 'application/memory_proposal_service.dart';
import 'application/memory_service.dart';
import 'application/semantic_index_service.dart';
import 'application/memory_scope_service.dart';
import 'application/plan_service.dart';
import 'application/search_service.dart';
import 'application/service_runtime.dart';
import 'application/settings_service.dart';
import 'application/study_plan_service.dart';
import 'data/backup/data_package_service.dart';
import 'data/backup/restore_inspection.dart';
import 'data/backup/restore_point_store.dart';
import 'data/attachment_store.dart';
import 'data/db/app_database.dart';
import 'data/db/database_gate.dart';
import 'data/db/guarded_database.dart';
import 'data/db/raw_executor.dart';
import 'data/db/local_data_reset.dart';
import 'data/db/write_transactions.dart';
import 'data/diagnostics/crash_log.dart';
import 'data/revisions/asset_store.dart';
import 'data/revisions/revision_engine.dart';
import 'data/revisions/revision_package.dart';
import 'data/revisions/revision_service.dart';
import 'data/repository/assessment_repository.dart';
import 'data/repository/attempt_repository.dart';
import 'data/repository/conversation_repository.dart';
import 'data/vector/embedding_config_store.dart';
import 'data/repository/evidence_repository.dart';
import 'data/repository/material_repository.dart';
import 'data/repository/memory_repository.dart';
import 'data/repository/schedule_repository.dart';
import 'data/repository/settings_repository.dart';
import 'data/repository/study_repository.dart';
import 'data/repository/study_plan_repository.dart';
import 'data/repository/task_repository.dart';
import 'domain/models/backup_error.dart';
import 'domain/rules/day_key.dart';
import 'domain/rules/time_policy.dart';
import 'platform/app_paths.dart';
import 'platform/app_info.dart';
import 'platform/first_frame.dart';
import 'platform/secure_secret_store.dart';
import 'ui/theme_mode_controller.dart';

part 'app_scope_data.dart';

/// 打开一次库，把仓库与服务挂在这里；页面不从各自开库。
class AppScope extends StatefulWidget {
  const AppScope({
    super.key,
    required this.child,
    this.crashLog,
    this.ai,
    required this.themeMode,
  });

  final Widget child;
  final CrashLog? crashLog;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 外观由应用根部持有，页面改它之后 MaterialApp 会立即重建。
  final ThemeModeController themeMode;

  static AppScopeState of(BuildContext context) {
    final data = context.dependOnInheritedWidgetOfExactType<_AppScopeData>();
    assert(data != null, 'AppScope 不在树上');
    return data!.state;
  }

  @override
  State<AppScope> createState() => AppScopeState();
}

class AppScopeState extends State<AppScope> {
  RawDatabase? _connection;
  late GuardedDatabase db;
  late AppPaths paths;

  /// 外观在应用根部，页面读它当前的值，也通过它保存。
  ThemeModeController get themeMode => widget.themeMode;

  // 仓库按表分组，页面直接用；服务收进 [AppServices] 的六组门面，见下面。
  late ConversationRepository conversations;
  late AttemptRepository attempts;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late MemoryRepository memories;
  late StudyRepository studyRecords;
  late AssessmentRepository assessments;
  late MaterialRepository materials;
  late StudyPlanRepository studyPlans;

  late LlmConfigStore _llmStore;
  AiChatService? _configuredAi;

  /// 讨论、学习与系统学习共用的回答来源；设置页的连接测试仍用真实客户端。
  BuddyAi get _ai => widget.ai ?? _configuredAi!;
  late DataPackageService _dataPackages;
  late RevisionEngine _engine;
  late RevisionService _revisions;
  late RevisionPackageService _revisionPackages;
  late RestorePointStore _restorePoints;
  late AttachmentCache _attachmentCache;
  late CrashLog crashLog;

  final Clock clock = systemClock;
  int cutoffHour = defaultDayCutoffHour;

  /// 用户从查找结果带入本次回答的来源；发送一次后清空。
  final BroughtSources broughtSources = BroughtSources();

  /// 整库恢复、清空与导入之后加一；三栏据此在原处重读数据，页面状态不重置。
  final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  final DatabaseGate gate = DatabaseGate();
  int _operationEpoch = 0;
  Timer? _semanticRefreshTimer;

  /// 写入触发的索引刷新静默期：连续提交时等最后一次写入之后只扫一次库。
  static const Duration _semanticQuietPeriod = Duration(seconds: 3);

  TimePolicy get timePolicy => TimePolicy(clock: clock, cutoffHour: cutoffHour);

  /// 服务共用的运行环境；时间口径随保存的设置换新，数据代次随恢复与清空推进。
  late final ServiceRuntime runtime = ServiceRuntime(
    policySource: () => timePolicy,
    filesDirSource: () => paths.filesDir,
    dataEpochSource: () => _operationEpoch,
    recordFailure: crashLog.record,
  );

  late final EvidenceRepository _evidenceRepository = EvidenceRepository(db);

  late final EmbeddingConfigStore _embeddingStore = EmbeddingConfigStore(
    SecureSecretStore(),
  );

  /// 当前嵌入配置；启动时读取，设置页保存之后由应用根重新应用。
  EmbeddingConfig? embeddingConfig;

  SemanticIndexService? __semantic;

  /// 语义索引按需创建；没有配置时不打开向量库。
  SemanticIndexService get _semantic => __semantic ??= SemanticIndexService(
    repository: _evidenceRepository,
    indexPath: paths.vectorIndexPath,
    epoch: () async => '${await _engine.headId(_connection!)}',
    clock: clock,
  );

  late final CrossSessionService _crossSession = CrossSessionService(
    repository: _evidenceRepository,
  );

  late final EvidenceService _evidence = EvidenceService(
    repository: _evidenceRepository,
    semantic: _semantic,
    crossSession: _crossSession,
  );

  late final AppServices _services = AppServices(
    chat: ChatServices(
      discussion: _discussion,
      learning: _learning,
      context: _context,
      memoryScope: _memoryScope,
    ),
    study: StudyServices(
      plan: _plan,
      systemPlan: _systemPlan,
      capacity: _capacity,
      continueLast: _continueLast,
    ),
    library: LibraryServices(
      material: _material,
      search: _search,
      evidence: _evidence,
      semanticIndexFactory: () => _semantic,
    ),
    memory: MemoryServices(edit: _memoryEdit, proposals: _proposals),
    settings: SettingsServices(
      edit: _settingsEdit,
      embedding: _embeddingStore,
      llm: _llmStore,
      aiFactory: () => _ai,
    ),
    data: DataServices(
      revisions: _revisions,
      engine: _engine,
      packages: _revisionPackages,
      currentData: _dataPackages,
      restorePoints: _restorePoints,
      attachments: _attachmentCache,
    ),
  );

  /// 讨论与作答、安排与学习、材料与检索、记忆、设置、数据版本六组服务。
  AppServices get services => _services;

  ChatServices get chat => _services.chat;

  StudyServices get study => _services.study;

  LibraryServices get library => _services.library;

  MemoryServices get memory => _services.memory;

  SettingsServices get settings => _services.settings;

  DataServices get data => _services.data;

  late final _transactions = WriteTransactions(db);
  late final _settings = SettingsRepository(db);

  late final ContextService _context = ContextService(
    tasks: tasks,
    attempts: attempts,
    schedule: schedule,
    memories: memories,
    conversations: conversations,
    materials: materials,
    runtime: runtime,
    evidence: _evidence,
  );

  late final MaterialService _material = MaterialService(
    materials: materials,
    transactions: _transactions,
    runtime: runtime,
  );

  late final SearchService _search = SearchService(evidence: _evidence);

  late final CapacityService _capacity = CapacityService(
    settings: _settings,
    tasks: tasks,
    schedule: schedule,
    runtime: runtime,
    transactions: _transactions,
  );

  late final ContinueService _continueLast = ContinueService(
    conversations: conversations,
    plans: studyPlans,
  );

  /// 讨论与作答共用：记录归属优先，没有时沿用最近一次学习的目标。
  late final MemoryScopeService _memoryScope = MemoryScopeService(
    conversations: conversations,
    attempts: attempts,
  );

  late final StudyPlanService _systemPlan = StudyPlanService(
    plans: studyPlans,
    materials: materials,
    ai: _ai,
    context: _context,
    conversations: conversations,
    study: studyRecords,
    transactions: _transactions,
  );

  late final DiscussionService _discussion = DiscussionService(
    conversations: conversations,
    ai: _ai,
    context: _context,
    memoryScope: _memoryScope,
    memories: memories,
    revisions: _revisions,
    tasks: tasks,
    materials: materials,
    runtime: runtime,
    transactions: _transactions,
    cleanupAttachmentPaths: cleanupAttachmentPaths,
    assets: _engine.assets,
    cache: _attachmentCache,
  );

  late final LearningService _learning = LearningService(
    attempts: attempts,
    conversations: conversations,
    study: studyRecords,
    memories: memories,
    revisions: _revisions,
    schedule: schedule,
    tasks: tasks,
    assessments: assessments,
    ai: _ai,
    context: _context,
    memoryScope: _memoryScope,
    runtime: runtime,
    transactions: _transactions,
  );

  late final PlanService _plan = PlanService(
    tasks: tasks,
    schedule: schedule,
    revisions: _revisions,
    runtime: runtime,
    studyPlans: studyPlans,
    transactions: _transactions,
  );

  late final MemoryService _memoryEdit = MemoryService(
    memories,
    transactions: _transactions,
  );

  late final MemoryProposalService _proposals = MemoryProposalService(
    attempts: attempts,
    conversations: conversations,
    memories: memories,
    transactions: _transactions,
  );

  late final SettingsService _settingsEdit = SettingsService(
    settings: _settings,
    transactions: _transactions,
    llmStore: _llmStore,
    ai: _configuredAi!,
    runtime: runtime,
    onPolicyChanged: _refreshDayCutoffHour,
    restore: restore,
    resetAll: resetAllData,
  );

  late final Future<void> ready = _init();

  @override
  void initState() {
    super.initState();
    // 首屏数据就绪（或开库失败）之后放行第一帧；没压过第一帧时这次调用
    // 什么都不做，测试照常跑。
    unawaited(
      ready
          .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
          .whenComplete(FirstFrameGate.release),
    );
  }

  Future<void> _init() async {
    paths = await AppPaths.resolve();
    await paths.ensureDirectories();
    crashLog = widget.crashLog ?? CrashLog(filesDir: paths.filesDir);
    crashLog.recordLaunch();
    db = GuardedDatabase(gate: gate, resolve: () => _connection!);
    _llmStore = LlmConfigStore(SecureSecretStore());
    _configuredAi = AiChatService(store: _llmStore);
    _dataPackages = DataPackageService(
      filesDir: paths.filesDir,
      dbPath: paths.dbPath,
      factory: databaseFactory,
      appVersion: appVersion,
      schemaVersion: zhixinSchemaVersion,
      clock: clock,
    );
    await _dataPackages.recoverInterruptedRestore();
    await _open();
    _engine = RevisionEngine(clock: clock);
    db.revisions = _engine;
    _attachmentCache = AttachmentCache(filesDir: () => paths.filesDir);
    _revisions = RevisionService(
      db: db,
      raw: () => _connection!,
      engine: _engine,
      clock: clock,
      cache: _attachmentCache,
      onUndoApplied: _refreshDayCutoffHour,
      onDataChanged: _invalidatePendingWork,
      onCacheFailure: (error, stack) =>
          crashLog.record(error, stack, kind: 'rebuild_attachments_restore'),
    );
    _revisionPackages = RevisionPackageService(
      engine: _engine,
      assets: _engine.assets,
      factory: databaseFactory,
      schemaVersion: zhixinSchemaVersion,
      appVersion: appVersion,
      clock: clock,
    );
    _restorePoints = RestorePointStore(filesDir: paths.filesDir, clock: clock);
    embeddingConfig = await _embeddingStore.read();
    // 重启之后按当前数据补建索引：数据代次与索引里的不一致时整份重建。
    applyEmbeddingConfig(embeddingConfig);
    // 附件清理与缓存补建跟首屏无关，而且耗时随数据量增长：放到首帧之后在
    // 后台做，首屏不再等它们，启动速度也不再取决于用久了攒下的图片数量。
    _scheduleAttachmentMaintenance();
  }

  /// 首帧交出之后在后台整理附件：先删掉数据库不再引用的图片，必要时补建缓存。
  ///
  /// 两步互不阻塞，各自失败只写诊断记录：它们与用户此刻的操作无关，下一次
  /// 启动还会重做，不值得用一个提示打断使用。缓存补建只在还原、导入之后或
  /// 缓存目录被系统清空时做，平时启动只做删除这一趟，避免每次全表扫描消息。
  void _scheduleAttachmentMaintenance() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maintainAttachments());
    });
  }

  Future<void> _maintainAttachments() async {
    try {
      await AttachmentStore(filesDir: paths.filesDir).cleanupUnreferenced(db);
    } catch (error, stack) {
      crashLog.record(error, stack, kind: 'cleanup_attachments');
    }
    if (!mounted) return;
    try {
      await gate.shared(() async {
        if (!await _attachmentCache.needsRebuild) return;
        await _attachmentCache.rebuild(db, _engine.assets);
        await _attachmentCache.clearPendingRebuild();
      });
    } catch (error, stack) {
      // 补建失败不打断使用：缺图的位置已经按“找不到图片”显示，下次再补。
      crashLog.record(error, stack, kind: 'rebuild_attachments');
    }
  }

  /// 应用一套嵌入配置：换掉嵌入来源，清掉旧模型对应的索引，再在后台补建。
  ///
  /// 没有配置或关闭语义索引时不读向量库，回答前后的原文与关键词检索照常。
  void applyEmbeddingConfig(EmbeddingConfig? config, {bool refresh = true}) {
    embeddingConfig = config;
    final runtime = embeddingRuntime(config);
    _semantic.configure(client: runtime.client, canSend: runtime.canSend);
    if (refresh && _semantic.configured) {
      unawaited(_semantic.refresh());
    }
  }

  Future<RawDatabase> _open() async {
    final connection = await openZhixinDatabase(
      path: paths.dbPath,
      clock: clock,
    );
    _connection = connection;
    await _bind();
    return connection;
  }

  Future<void> _bind() async {
    final connection = db;
    await _refreshDayCutoffHour();
    conversations = ConversationRepository(connection, clock: clock);
    attempts = AttemptRepository(connection, clock: clock);
    tasks = TaskRepository(connection, clock: clock);
    schedule = ScheduleRepository(connection, clock: clock);
    memories = MemoryRepository(connection, clock: clock);
    studyRecords = StudyRepository(connection, clock: clock);
    assessments = AssessmentRepository(connection, clock: clock);
    materials = MaterialRepository(connection, clock: clock);
    studyPlans = StudyPlanRepository(connection, clock: clock);
  }

  /// 重新读取库里的每日截止小时；保存设置与撤销设置之后都走这里。
  ///
  /// 截止小时改变学习记录归到哪一天与导出文件名，界面分组要随数据版本
  /// 一起刷新，不能继续用启动时缓存的值。
  Future<void> _refreshDayCutoffHour() async {
    final hour = await _settings.cutoffHour() ?? defaultDayCutoffHour;
    if (hour < 0 || hour > maxDayCutoffHour) {
      throw StateError('day_cutoff_hour 数据超出 0–$maxDayCutoffHour：$hour');
    }
    if (hour == cutoffHour) return;
    cutoffHour = hour;
    dataVersion.value++;
  }

  /// 版本恢复、单项撤销与整库恢复都会换掉当前数据：推进代次，让恢复前
  /// 发出的模型回答与判断不再写回，再通知三栏重读。
  Future<void> _invalidatePendingWork() async {
    _operationEpoch++;
    dataVersion.value++;
    _refreshSemanticIndex();
  }

  /// 数据代次变化后按当前数据补建语义索引；没有配置或已关闭时不动向量库。
  ///
  /// 写入触发的刷新等 [_semanticQuietPeriod] 再执行，期间再次写入只顺延，
  /// 避免每次提交都全量扫库；立即需要索引的入口仍直接调用刷新。
  void _refreshSemanticIndex() {
    if (!_semantic.configured) return;
    _semanticRefreshTimer?.cancel();
    _semanticRefreshTimer = Timer(_semanticQuietPeriod, () {
      _semanticRefreshTimer = null;
      unawaited(_semantic.refresh());
    });
  }

  @override
  void dispose() {
    _semanticRefreshTimer?.cancel();
    _configuredAi?.dispose();
    __semantic?.close();
    __semantic = null;
    if (_connection != null) db.close();
    dataVersion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          try {
            crashLog.record(
              snapshot.error!,
              snapshot.stackTrace,
              kind: 'database_open',
            );
          } catch (_) {
            // 诊断记录本身不可用时仍要显示可行动说明。
          }
          return const forui.FScaffold(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('本地数据库没有打开'),
                  SizedBox(height: 8),
                  Text('学习数据仍在本机。可以重启应用再试；如果多次仍打不开，保留本机诊断记录用于排查。'),
                ],
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const forui.FScaffold(
            child: Center(child: forui.FCircularProgress()),
          );
        }
        return _AppScopeData(state: this, child: widget.child);
      },
    );
  }
}

class _AppScopeData extends InheritedWidget {
  const _AppScopeData({required this.state, required super.child});

  final AppScopeState state;

  @override
  bool updateShouldNotify(_AppScopeData oldWidget) => false;
}
