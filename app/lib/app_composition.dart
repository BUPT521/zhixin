import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'ai/ai_chat_service.dart';
import 'ai/llm_config.dart';
import 'ai/llm_config_store.dart';
import 'app_maintenance.dart';
import 'app_prefetch.dart';
import 'app_services.dart';
import 'app_space_coordinator.dart';
import 'application/account_service.dart';
import 'application/active_report_service.dart';
import 'application/cloud_backup_service.dart';
import 'application/context_service.dart';
import 'application/continue_service.dart';
import 'application/cross_session_service.dart';
import 'application/discussion_service.dart';
import 'application/embedding_settings.dart';
import 'application/evidence_service.dart';
import 'application/feedback_service.dart';
import 'application/learning_service.dart';
import 'application/material_search.dart';
import 'application/material_service.dart';
import 'application/memory_proposal_service.dart';
import 'application/memory_scope_service.dart';
import 'application/memory_service.dart';
import 'application/memory_usage_service.dart';
import 'application/plan_service.dart';
import 'application/prefetch_service.dart';
import 'application/search_index_service.dart';
import 'application/search_service.dart';
import 'application/service_runtime.dart';
import 'application/settings_service.dart';
import 'application/study_plan_service.dart';
import 'application/sync_service.dart';
import 'application/time_policy_controller.dart';
import 'application/undo_guards/undo_guards.dart';
import 'application/undo_service.dart';
import 'application/update_check_service.dart';
import 'data/backup/data_package_service.dart';
import 'data/backup/data_version_service.dart';
import 'data/backup/restore_point_store.dart';
import 'data/cloud/account_store.dart';
import 'data/cloud/cloud_preferences_store.dart';
import 'data/cloud/server_client.dart';
import 'data/cloud/telemetry_store.dart';
import 'data/db/app_database.dart';
import 'data/db/database_gate.dart';
import 'data/db/guarded_database.dart';
import 'data/db/local_data_reset.dart';
import 'data/db/raw_executor.dart';
import 'data/db/write_transactions.dart';
import 'data/diagnostics/crash_log.dart';
import 'data/repository/assessment_repository.dart';
import 'data/repository/attempt_repository.dart';
import 'data/repository/conversation_repository.dart';
import 'data/repository/evidence_repository.dart';
import 'data/repository/material_repository.dart';
import 'data/repository/memory_repository.dart';
import 'data/repository/plugin_metadata_store.dart';
import 'data/repository/settings_repository.dart';
import 'data/repository/study_plan_repository.dart';
import 'data/repository/study_repository.dart';
import 'data/repository/task_repository.dart';
import 'data/revisions/asset_store.dart';
import 'data/revisions/revision_cursor.dart';
import 'data/revisions/revision_engine.dart';
import 'domain/models/revision_models.dart';
import 'data/revisions/revision_package.dart';
import 'data/revisions/revision_service.dart';
import 'data/revisions/semantic_change.dart';
import 'data/vector/embedding_config_store.dart';
import 'domain/rules/schema_version.dart';
import 'domain/rules/time_policy.dart';
import 'platform/app_info.dart';
import 'platform/app_paths.dart';
import 'platform/release_signing_key.dart';
import 'platform/secure_secret_store.dart';
import 'plugins/persona/persona_catalog.dart';
import 'plugins/persona/persona_plugin.dart';
import 'plugins/runtime/plugin_runtime.dart';

/// 应用根的装配：打开一次库，把仓库、服务与运行环境按依赖顺序建好。
///
/// 这里只管装配。首屏就绪状态留在 [AppScope]，后台维护见 [AppMaintenance]，
/// 换空间与清空见 [AppSpaceCoordinator]，二级界面的预读见 [AppPrefetchPolicy]。
/// 页面不从各自开库，也不直接持有连接：装配结果经 [AppScope] 的作用域取用。
class AppComposition {
  AppComposition({
    required this.clock,
    required this.dataVersion,
    required this.networkAllowedSource,
    this.spaces,
    this.spaceId = AppSpaces.local,
    this.changeSpace,
    this.crashLogOverride,
    this.serverClientFactory,
    this.ai,
    this.updates,
  });

  /// 时间来源；为空时取系统时钟，测试传固定时钟让当天窗口不随运行时刻变化。
  final Clock clock;

  /// 整库恢复、清空与导入之后加一；三栏据此在原处重读数据，页面状态不重置。
  final ValueNotifier<int> dataVersion;

  /// 数据目录；可以在关库之后整体改名或删除，设备目录始终保持打开。
  final AppSpaces? spaces;

  /// 当前本机空间的标识；一份装配只服务一个空间。
  final String spaceId;

  /// 换空间由应用根部处理；为空表示这一份装配不管理空间（测试）。
  final Future<void> Function(
    String id, {
    required bool adoptLocal,
    required bool deleteCurrent,
    String? label,
  })?
  changeSpace;

  /// 启动时已经建好的崩溃记录；为空时按当前数据目录新建。
  final CrashLog? crashLogOverride;

  /// 连服务端用的客户端；测试换成进程内的假服务端，为空时按地址直连。
  final ServerClient Function(String baseUrl)? serverClientFactory;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 更新检查服务；测试注入计数用的替身，为空时按当前服务地址新建。
  final UpdateCheckService? updates;

  /// 联网开关的当前值；首次启动引导里同意用户须知之前为假。
  final bool Function() networkAllowedSource;

  /// 联网功能是否可用；没有引导的装配（测试）始终可用。
  bool get networkAllowed => networkAllowedSource();

  /// 空间切换与清空；换库之后的连接与通知都在这里收口。
  late final AppSpaceCoordinator spaceCoordinator = AppSpaceCoordinator(this);

  /// 首帧之后的后台维护：附件整理、索引补建、同步调度与匿名上报。
  late final AppMaintenance maintenance = AppMaintenance(this);

  /// 二级界面首屏的预读；一级界面切进来之后才读，启动时不预读。
  late final AppPrefetchPolicy prefetchPolicy = AppPrefetchPolicy(this);

  /// 二级界面首屏的预读入口；页面打开时先看有没有已经读完的结果。
  PrefetchService get prefetch => prefetchPolicy.prefetch;

  /// 是否管理多空间；应用根接管空间时才需要换路径、关连接与清目录。
  bool get managesSpaces => changeSpace != null;

  /// 当前空间的数据目录；装配完成之前为空，页面在就绪之后才读。
  late AppPaths paths;

  /// 设备级目录：空间标识、引导状态与诊断都写在这里，换空间时不变。
  AppPaths get devicePaths => spaces?.device ?? paths;

  /// 启动时建好的崩溃记录；首屏装配成功之后才可用。
  late CrashLog crashLog;

  /// 首帧装配是否已经成功完成。
  bool get initialized => _initialized;
  bool _initialized = false;

  RawDatabase? _connection;

  late GuardedDatabase _db;

  /// 仓库与页面共用的库入口；库访问都经过它的访问协调。
  GuardedDatabase get db => _db;

  final DatabaseGate _gate = DatabaseGate();

  /// 读、写、事务与关闭共用的访问队列。
  DatabaseGate get gate => _gate;

  int _operationEpoch = 0;

  // 仓库按表分组，页面直接用；服务收进 [AppServices] 的八组门面，见下面。
  late ConversationRepository _conversations;
  late AttemptRepository _attempts;
  late TaskRepository _tasks;
  late MemoryRepository _memories;
  late StudyRepository _studyRecords;
  late AssessmentRepository _assessments;
  late MaterialRepository _materials;
  late StudyPlanRepository _studyPlans;

  late LlmConfigStore _llmStore;
  late final SecretStore _modelSettings = managesSpaces
      ? SpaceModelSettings(paths)
      : SecureSecretStore();
  AiChatService? _configuredAi;

  /// 账号与云同步：令牌在 Keystore，服务地址与同步游标在应用私有目录。
  AccountService? _accountService;
  ActiveReportService? _activeReportService;
  FeedbackService? _feedbackService;
  UpdateCheckService? _updateCheckService;
  late CloudPreferencesStore _cloudPreferences;
  CloudBackupService? _cloudBackups;
  SyncService? _cloudSync;

  AccountService get account => _accountService!;

  /// 云端备份与按提交的增量同步；首屏装配完成之前为空。
  SyncService? get sync => _cloudSync;

  /// 匿名活跃上报；首屏装配完成之前为空。
  ActiveReportService? get activeReport => _activeReportService;

  /// 第一方插件运行时；启动时装载，整库恢复与清空之后重读 app_meta。
  PluginRuntime? _pluginRuntime;

  /// 讨论、学习与系统学习共用的回答来源；设置页的连接测试仍用真实客户端。
  BuddyAi get _ai => ai ?? _configuredAi!;

  late DataPackageService _dataPackages;
  late RevisionEngine _engine;
  late RevisionService _revisions;
  late RevisionPackageService _revisionPackages;
  late RestorePointStore _restorePoints;
  late AttachmentCache _attachmentCache;

  /// 版本引擎；整库恢复与撤销用它读写提交。
  RevisionEngine get engine => _engine;

  /// 附件缓存；整库恢复与清空之后补建。
  AttachmentCache get attachmentCache => _attachmentCache;

  /// 每日截止小时与时间口径的唯一持有者；保存与撤销之后都从设置仓库重读。
  late final TimePolicyController _timePolicy = TimePolicyController(
    settings: _settings,
    clock: clock,
    onChanged: _onTimePolicyChanged,
  );

  TimePolicy get timePolicy => _timePolicy.policy;

  /// 服务共用的运行环境；时间口径随保存的设置换新，数据代次随恢复与清空推进。
  late final ServiceRuntime _runtime = ServiceRuntime(
    policySource: () => timePolicy,
    filesDirSource: () => paths.filesDir,
    dataEpochSource: () => _operationEpoch,
    live: _db.live,
    recordFailure: crashLog.record,
  );

  /// 服务共用的运行环境；单元测试也可以直接造一份。
  ServiceRuntime get runtime => _runtime;

  /// 仓库句柄；只给测试装配入口与运行环境取用，页面经 [services] 取数据。
  ConversationRepository get conversations => _conversations;
  AttemptRepository get attempts => _attempts;
  TaskRepository get tasks => _tasks;
  MemoryRepository get memories => _memories;
  StudyRepository get studyRecords => _studyRecords;
  AssessmentRepository get assessments => _assessments;
  MaterialRepository get materials => _materials;
  StudyPlanRepository get studyPlans => _studyPlans;

  late final EvidenceRepository _evidenceRepository = EvidenceRepository(_db);

  late final EmbeddingConfigStore _embeddingStore = EmbeddingConfigStore(
    _modelSettings,
  );

  /// 检索索引配置的唯一入口：页面保存一次，应用根启动时恢复一次。
  late final EmbeddingSettingsService _embeddingSettings =
      EmbeddingSettingsService(
        store: _embeddingStore,
        index: _searchIndex,
        serverEndpoint: () => account.embeddingEndpoint(),
      );

  SearchIndexService? _searchIndexService;

  /// 已经建好的检索索引；没有配置嵌入来源时为空，维护不在这里新建索引。
  SearchIndexService? get currentSearchIndex => _searchIndexService;

  /// 检索索引的来源表：这几张表有了提交才需要补建索引。
  ///
  /// 其余业务表（目标、设置、版本历史等）的提交不改变索引内容；讨论与材料的
  /// 删除会经外键级联改到这里的表，仍然会触发。
  static const Set<String> searchIndexSourceTables = {
    'material_page',
    'message',
    'attempt',
  };

  /// 检索索引按需创建；没有配置嵌入来源时只建全文索引。
  ///
  /// 向量缓存只对已开始同步的账号写入：这里每次都读一次账号状态，登录且自动
  /// 同步开启时刷新才在嵌入请求上声明写缓存（ADR-0030 决定第 3 条）。增量刷新
  /// 由提交日志驱动：`HEAD`、来源行变化与可发送范围签名都在刷新时读取，回调在
  /// 稍后调用，闭包对已经创建的字段只读，不会与这里的初始化互相等待。
  SearchIndexService get _searchIndex =>
      _searchIndexService ??= SearchIndexService(
        repository: _evidenceRepository,
        indexPath: paths.vectorIndexPath,
        indexLogPath: paths.vectorLogPath,
        epoch: () async => '${await _engine.currentGeneration(_connection!)}',
        clock: clock,
        recordFailure: crashLog.record,
        cacheWrites: () async {
          final account = await this.account.snapshot();
          return account.signedIn && account.autoSync;
        },
        headCommit: () async => await _engine.headId(_connection!),
        semanticChanges: _semanticChangesAfter,
        shareSignature: _embeddingShareSignature,
        // 索引读到哪里记在库里的非阻塞读取位置，状态文件只留模型键、维度、
        // 数据代次与可发送范围签名；与同步位置使用同一张表（方案 3.12）。
        indexCursors: () => RevisionCursors(_connection!),
      );

  /// 读出某个提交之后材料页、消息与作答的净变化。
  ///
  /// 起点提交已经被历史裁剪时返回 `usable: false`，索引退回全量扫描；删除行
  /// 把 `before` 还原成 SQLite 值交给索引，材料页因此能按材料编号与页码还原
  /// 来源键（ADR-0030 决定第 5 条）。
  Future<SemanticChangeWindow> _semanticChangesAfter(int after) async {
    final connection = _connection;
    if (connection == null) return SemanticChangeWindow.unavailable;
    if (await _engine.commitById(connection, after) == null) {
      return SemanticChangeWindow.unavailable;
    }
    final changes = await _engine.changesAfter(
      connection,
      after,
      tables: searchIndexSourceTables,
    );
    return SemanticChangeWindow(
      changes: [
        for (final change in changes)
          SemanticRowChange(
            table: change.table,
            rowKey: change.rowKey,
            removed: change.isDelete,
            removedRow: change.isDelete && change.before != null
                ? sqliteRow(change.before!)
                : null,
          ),
      ],
    );
  }

  /// 可发送范围的签名：分享范围与材料列表一起决定哪些来源可以发送原文。
  ///
  /// 没有配置嵌入来源时是 `off`；材料列表排序之后拼接，避免同一组材料因为
  /// 顺序不同被当成范围变化。范围变小时旧向量必须消失，向量集合整份重建。
  String _embeddingShareSignature() {
    final config = _embeddingSettings.current;
    if (config == null) return 'off';
    final materials = [...config.materialIds]..sort();
    return '${config.shareScope.value}|${materials.join(',')}';
  }

  late final CrossSessionService _crossSession = CrossSessionService(
    repository: _evidenceRepository,
  );

  late final EvidenceService _evidence = EvidenceService(
    repository: _evidenceRepository,
    index: _searchIndex,
    crossSession: _crossSession,
  );

  late final AppServices _services = AppServices(
    chat: ChatServices(
      discussion: _discussion,
      learning: _learning,
      context: _context,
    ),
    study: StudyServices(
      plan: _plan,
      systemPlan: _systemPlan,
      continueLast: _continueLast,
    ),
    library: LibraryServices(
      material: _material,
      materialSearch: _materialSearch,
      search: _search,
      searchIndexFactory: () => _searchIndex,
    ),
    memory: MemoryServices(edit: _memoryEdit, proposals: _proposals),
    settings: SettingsServices(
      edit: _settingsEdit,
      embedding: _embeddingSettings,
      aiFactory: () => _ai,
    ),
    data: DataServices(
      revisions: _revisions,
      versions: _dataVersions,
      undo: _undo,
    ),
    plugins: PluginServices(
      runtime: _pluginRuntime!,
      personas: _pluginRuntime!.personas,
    ),
    account: AccountServices(
      account: account,
      backups: _cloudBackups!,
      sync: _cloudSync!,
      activeReport: _activeReportService!,
      updates: _updateCheckService!,
      feedback: _feedbackService!,
    ),
  );

  /// 讨论、作答、安排、材料、记忆、设置、数据版本、插件与账号八组服务。
  AppServices get services => _services;

  late final _transactions = WriteTransactions(_db, revisions: _engine);
  late final _settings = SettingsRepository(_db);

  late final ContextService _context = ContextService(
    tasks: _tasks,
    attempts: _attempts,
    memories: _memories,
    conversations: _conversations,
    materials: _materials,
    runtime: _runtime,
    evidence: _evidence,
    usage: _memoryUsage,
    personaSource: () async {
      final runtime = _pluginRuntime;
      if (runtime == null) return null;
      return runtime.loadActivePersonaForPrompt();
    },
  );

  late final MaterialService _material = MaterialService(
    materials: _materials,
    transactions: _transactions,
    runtime: _runtime,
  );

  /// 材料查找：列表、详情与选择器共用，全部在本机完成。
  late final MaterialSearchService _materialSearch = MaterialSearchService(
    materials: _materials,
  );

  late final SearchService _search = SearchService(evidence: _evidence);

  late final ContinueService _continueLast = ContinueService(
    conversations: _conversations,
    plans: _studyPlans,
    activity: _context.loadActivity,
    runtime: _runtime,
  );

  /// 讨论与作答共用：记录归属优先，没有时沿用最近一次学习的目标。
  late final MemoryScopeService _memoryScope = MemoryScopeService(
    conversations: _conversations,
    attempts: _attempts,
  );

  late final StudyPlanService _systemPlan = StudyPlanService(
    plans: _studyPlans,
    materials: _materials,
    ai: _ai,
    context: _context,
    conversations: _conversations,
    study: _studyRecords,
    transactions: _transactions,
    runtime: _runtime,
  );

  late final DiscussionService _discussion = DiscussionService(
    conversations: _conversations,
    ai: _ai,
    context: _context,
    memoryScope: _memoryScope,
    memories: _memories,
    revisions: _revisions,
    tasks: _tasks,
    materials: _materials,
    runtime: _runtime,
    transactions: _transactions,
    cleanupAttachmentPaths: _dataVersions.cleanupAttachmentPaths,
    assets: _engine.assets,
    cache: _attachmentCache,
  );

  late final LearningService _learning = LearningService(
    attempts: _attempts,
    conversations: _conversations,
    study: _studyRecords,
    memories: _memories,
    revisions: _revisions,
    tasks: _tasks,
    assessments: _assessments,
    ai: _ai,
    context: _context,
    memoryScope: _memoryScope,
    runtime: _runtime,
    transactions: _transactions,
  );

  late final PlanService _plan = PlanService(
    tasks: _tasks,
    runtime: _runtime,
    studyPlans: _studyPlans,
    transactions: _transactions,
  );

  late final MemoryService _memoryEdit = MemoryService(
    _memories,
    tasks: _tasks,
    materials: _materials,
    transactions: _transactions,
    runtime: _runtime,
  );

  late final MemoryProposalService _proposals = MemoryProposalService(
    attempts: _attempts,
    conversations: _conversations,
    memories: _memories,
    transactions: _transactions,
    runtime: _runtime,
  );

  /// 记忆使用统计：召回时只记在本机，应用进入后台且距上次冲刷不少于一天时
  /// 冲刷成一条维护提交（ADR-0051 决定第 8 条）。
  late final MemoryUsageService _memoryUsage = MemoryUsageService(
    db: _db,
    transactions: _transactions,
    deviceIdSource: () async {
      try {
        return await account.deviceId();
      } catch (_) {
        return null;
      }
    },
    clock: clock,
    storedFlushAt: _cloudPreferences.memoryUsageFlushedAt,
    recordFlushAt: _cloudPreferences.setMemoryUsageFlushedAt,
    onFlushed: () => maintenance.refreshSearchIndexNowAndWait(),
  );

  /// 记忆使用统计；进入后台时由维护调度冲刷。
  MemoryUsageService get memoryUsage => _memoryUsage;

  late final SettingsService _settingsEdit = SettingsService(
    settings: _settings,
    transactions: _transactions,
    llmStore: _llmStore,
    ai: _configuredAi!,
    runtime: _runtime,
    timePolicy: _timePolicy,
    dataVersions: _dataVersions,
    authorizeConfig: (config) => account.prepareModelConfig(config),
  );

  /// 撤销的应用层入口；撤销成功之后由它刷新截止小时，数据层不引 application。
  late final UndoService _undo = UndoService(
    revisions: _revisions,
    timePolicy: _timePolicy,
  );

  /// 数据包、整库恢复、恢复点与清空；换库之后的连接与通知仍在这里。
  late final DataVersionService _dataVersions = DataVersionService(
    gate: _gate,
    revisions: _revisions,
    revisionPackages: _revisionPackages,
    dataPackages: _dataPackages,
    restorePointStore: _restorePoints,
    engine: _engine,
    cache: _attachmentCache,
    connection: () => _connection!,
    database: () => _db,
    reopen: _open,
    resetStudyData: _resetStudyData,
    markPendingWorkInvalidated: () => _operationEpoch++,
    notifyDataChanged: () {
      dataVersion.value++;
      // 整库恢复、导入与清空换掉了数据：订阅中的页面按全部表重读一次
      // （ADR-0014 第 3 条）。
      _db.notifyAllTables();
      maintenance.refreshSearchIndex();
    },
    recordFailure: (error, stack, {required kind}) =>
        crashLog.record(error, stack, kind: kind),
  );

  /// 数据版本、恢复点与清空；页面经 [services] 的 data 组取用。
  DataVersionService get dataVersions => _dataVersions;

  /// 首屏装配：打开数据目录与数据库、装配服务。启动失败时可以重建一个新的
  /// Future，失败页的“重试”不必重启应用；重建之前由调用方关掉旧连接。
  ///
  /// [previousFailure] 是上一次启动失败的原因：这次目录可用了，先把上次的
  /// 失败补记进诊断，再继续装配。
  Future<void> initialize({
    Object? previousFailure,
    StackTrace? previousStack,
  }) async {
    paths = spaces?.pathsFor(spaceId) ?? await AppPaths.resolve();
    await paths.ensureDirectories();
    crashLog = crashLogOverride ?? CrashLog(filesDir: devicePaths.filesDir);
    crashLog.recordLaunch();
    if (previousFailure != null) {
      crashLog.record(previousFailure, previousStack, kind: 'startup_previous');
    }
    _db = GuardedDatabase(gate: _gate, resolve: () => _connection!);
    _db.onCommitted = maintenance.onCommitted;
    _llmStore = LlmConfigStore(_modelSettings);
    _cloudPreferences = CloudPreferencesStore(
      filesDir: devicePaths.filesDir,
      spaceFilesDir: paths.filesDir,
    );
    _accountService = AccountService(
      store: AccountStore(SecureSecretStore()),
      preferences: _cloudPreferences,
      deviceName: '知新 ${appVersion.split('+').first}',
      clientFactory: serverClientFactory,
      // 退出登录、删除账号、清除云端与重设密码之后，让同步服务把库里的推送
      // 位置改成不阻塞；位置与 scope 保留，重新登录同一账号时从原位置继续。
      onSyncStateCleared: managesSpaces
          ? null
          : () => _cloudSync?.releaseSyncCursor() ?? Future<void>.value(),
      acceptsSession: managesSpaces
          ? (session) =>
                syncScopeFor(session.userId, session.serverOrigin) == spaceId
          : null,
      onSignedIn: managesSpaces
          ? (session, profile) => spaceCoordinator.changeSpace(
              syncScopeFor(session.userId, session.serverOrigin),
              adoptLocal: spaceId == AppSpaces.local,
              label: profile == null || profile.displayLabel.isEmpty
                  ? null
                  : '${profile.displayLabel} · ${Uri.parse(session.serverOrigin).authority}',
            )
          : null,
      onSignedOut: managesSpaces
          ? (deleteSpace) => spaceCoordinator.changeSpace(
              AppSpaces.local,
              deleteCurrent: deleteSpace,
            )
          : null,
      onSessionExpired: managesSpaces
          ? () {
              unawaited(
                spaceCoordinator.changeSpace(AppSpaces.local).catchError((
                  Object error,
                  StackTrace stack,
                ) {
                  crashLog.record(error, stack, kind: 'account_space_expired');
                }),
              );
            }
          : null,
    );
    // 先把服务实例来源读进内存：页面构建与预读会在假异步区里取会话，那里等不到
    // 文件 I/O，来源缓存让这些读取不再落盘。
    await _accountService!.serverOrigin();
    _activeReportService = ActiveReportService(
      store: TelemetryStore(filesDir: devicePaths.filesDir),
      signedIn: () async => (await account.snapshot()).session != null,
      serverBaseUrl: account.serverBaseUrl,
      crashLog: crashLog,
      appVersion: appVersion,
      clientFactory: serverClientFactory,
    );
    _feedbackService = FeedbackService(serverBaseUrl: account.serverBaseUrl);
    _updateCheckService =
        updates ??
        UpdateCheckService(
          serverBaseUrl: account.serverBaseUrl,
          appVersion: appVersion,
          publicKeyPem: releasePublicKeyPem,
          // 检查失败的常见原因是清单与安装包还没对齐，不是崩溃；只留本机诊断，
          // 不交给 Sentry，也不打扰用户。
          recordFailure: (error, stack, {required kind}) =>
              crashLog.record(error, stack, kind: kind, report: false),
        );
    _configuredAi = AiChatService(
      store: _llmStore,
      configSource: _configuredModelConfig,
    );
    _dataPackages = DataPackageService(
      filesDir: paths.filesDir,
      dbPath: paths.dbPath,
      appVersion: appVersion,
      schemaVersion: zhixinSchemaVersion,
      clock: clock,
    );
    await _dataPackages.recoverInterruptedRestore();
    await _open();
    // 插件运行时只读 app_meta：启停状态与人格配置随整库备份恢复，不形成提交。
    final pluginStore = SettingsPluginMetadataStore(_settings, clock);
    final personaCatalog = PersonaCatalog(store: pluginStore);
    _pluginRuntime = PluginRuntime(
      store: pluginStore,
      personas: personaCatalog,
      plugins: [PersonaPlugin(personaCatalog)],
    );
    await _pluginRuntime!.load();
    _engine = RevisionEngine(clock: clock);
    _db.revisions = _engine;
    _attachmentCache = AttachmentCache(filesDir: () => paths.filesDir);
    _revisions = RevisionService(
      engine: _engine,
      db: _db,
      raw: () => _connection!,
      clock: clock,
      cache: _attachmentCache,
      // 撤销的业务约束与可撤销表名单由应用层注册，数据层只做通用核对。
      undoGuards: defaultUndoGuards,
      onDataChanged: _invalidatePendingWork,
      onNamedVersionsChanged: () {
        final sync = _cloudSync;
        if (sync != null) unawaited(sync.schedule());
      },
      onCacheFailure: (error, stack) =>
          crashLog.record(error, stack, kind: 'rebuild_attachments_restore'),
    );
    _revisionPackages = RevisionPackageService(
      engine: _engine,
      assets: _engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: appVersion,
      clock: clock,
    );
    _restorePoints = RestorePointStore(filesDir: paths.filesDir, clock: clock);
    _cloudBackups = CloudBackupService(
      account: account,
      versions: _dataVersions,
      filesDir: paths.filesDir,
      clock: clock,
    );
    _cloudSync = SyncService(
      account: account,
      preferences: _cloudPreferences,
      revisions: _revisions,
      engine: _engine,
      database: _db,
      transactions: _transactions,
      assets: _engine.assets,
      cache: _attachmentCache,
      clock: clock,
      recordFailure: (error, stack, {required kind}) =>
          crashLog.record(error, stack, kind: kind),
    );
    final embeddingConfig = await _embeddingSettings.read();
    _embeddingSettings.apply(embeddingConfig);
    // 重启之后按当前数据补建索引：数据代次与索引里的不一致时整份重建。
    // 向量库的打开、初始化 zvec 引擎与建表都在后台 isolate 里进行，首帧只发起
    // 请求，不等待它完成。
    if (_embeddingSettings.configured) maintenance.refreshSearchIndexNow();
    // 附件清理与缓存补建跟首屏无关，而且耗时随数据量增长：放到首帧之后在
    // 后台做，首屏不再等它们，启动速度也不再取决于用久了攒下的图片数量。
    maintenance.scheduleAttachmentMaintenance();
    // 登录状态下启动之后自动同步一次；未登录时这一步什么都不做。首次启动
    // 引导里同意用户须知之前不发请求，同意之后由应用根部补一次同步调度。
    if (networkAllowed) unawaited(_cloudSync!.schedule());
    maintenance.scheduleActiveReport();
    _initialized = true;
  }

  /// 首屏装配失败时关掉可能已经打开的旧连接：重试时新连接接手主库文件。
  Future<void> discardConnection() async {
    final previous = _connection;
    _connection = null;
    if (previous == null) return;
    try {
      await previous.close();
    } catch (_) {
      // 旧连接关闭失败不影响重新打开；新连接接手主库文件。
    }
  }

  Future<RawDatabase> _open() async {
    final connection = await openZhixinDatabase(
      path: paths.dbPath,
      clock: clock,
    );
    _connection = connection;
    // 新连接接上表变更通知，并按全部表补发一次：恢复与清空换库之后，
    // 订阅中的页面在新库上重读，不会停在旧连接的数据上（ADR-0014）。
    _db.connectionReplaced();
    await _bind();
    return connection;
  }

  Future<void> _bind() async {
    final connection = _db;
    await _timePolicy.refresh();
    _conversations = ConversationRepository(connection, clock: clock);
    _attempts = AttemptRepository(connection, clock: clock);
    _tasks = TaskRepository(connection, clock: clock);
    _memories = MemoryRepository(connection, clock: clock);
    _studyRecords = StudyRepository(connection, clock: clock);
    _assessments = AssessmentRepository(connection, clock: clock);
    _materials = MaterialRepository(connection, clock: clock);
    _studyPlans = StudyPlanRepository(connection, clock: clock);
  }

  /// 截止小时改变后推进数据代次：学习记录归到哪一天与导出文件名都随之变化，
  /// 界面分组要重读，不能继续用旧口径。
  void _onTimePolicyChanged() {
    dataVersion.value++;
  }

  /// 版本恢复、单项撤销与整库恢复都会换掉当前数据：推进代次，让恢复前
  /// 发出的模型回答与判断不再写回，再通知三栏重读。
  Future<void> _invalidatePendingWork() async {
    _operationEpoch++;
    dataVersion.value++;
    // 版本恢复与单项撤销换掉了当前数据，订阅中的页面按全部表重读一次。
    _db.notifyAllTables();
    maintenance.refreshSearchIndex();
  }

  /// 清空本机学习数据：关掉连接、删库与附件，再按当前结构重开一个空库。
  Future<void> _resetStudyData() async {
    await _connection?.close();
    _connection = null;
    // 清空全部记录连语义索引一起删：先释放 collection 句柄，删除流程才能
    // 删掉索引目录；嵌入来源保持配置，下一次刷新按空库重建索引。
    await _searchIndexService?.release();
    await deleteLocalStudyData(
      filesDir: paths.filesDir,
      dbPath: paths.dbPath,
      vectorIndexPath: paths.vectorIndexPath,
    );
    await paths.ensureDirectories();
    await _open();
  }

  /// 读取模型配置；每次现拼知新服务的地址并换上当前账号的访问令牌。
  ///
  /// 令牌不进 Keystore，每次回答前从这里取；没有登录时返回 null，回答按未
  /// 配置退回本地兜底，设置页另有说明。
  Future<LlmConfig?> _configuredModelConfig() async {
    final read = await _llmStore.read();
    final stored = read.valueOrNull;
    if (read.failureOrNull case final failure?) {
      throw LlmConfigReadFailure(failure.detail ?? failure.message);
    }
    return account.authorizeModelConfig(stored ?? const LlmConfig());
  }

  /// 回答恢复入口只核对是否有登录会话，实际请求再读取配置与访问令牌。
  Future<bool> modelReady() async => (await account.snapshot()).signedIn;

  /// 保存服务地址；地址变了之后账号与同步都按新实例重新读。
  Future<void> configureServerBaseUrl(String address) => account
      .configureServerBaseUrl(address, schemaVersion: zhixinSchemaVersion);

  /// 换空间与退出时关掉这一份装配：同步、索引、账号与库连接一起收。
  ///
  /// 多次调用返回同一个 Future：换空间时应用根部与状态释放各调一次。
  Future<void>? _closing;

  /// 是否正在关闭；关闭期间后台维护不再开始新的步骤。
  bool get closing => _closing != null;

  Future<void> close() => _closing ??= _closeNow();

  Future<void> _closeNow() async {
    _operationEpoch++;
    maintenance.cancelIndexTimer();
    _accountService?.dispose();
    _configuredAi?.dispose();
    await _cloudSync?.close();
    final index = _searchIndexService;
    if (index != null) await index.close();
    _searchIndexService = null;
    if (_connection != null) {
      await _gate.exclusive(_db.close);
      _connection = null;
    }
  }

  /// 状态释放时的收尾：管理空间的装配走 [close]，其余就地关连接与定时器。
  void dispose() {
    if (managesSpaces) {
      unawaited(close());
      return;
    }
    maintenance.dispose();
    _cloudSync?.dispose();
    _accountService?.dispose();
    _configuredAi?.dispose();
    final index = _searchIndexService;
    if (index != null) unawaited(index.close());
    _searchIndexService = null;
    if (_connection != null) unawaited(_db.close());
  }
}
