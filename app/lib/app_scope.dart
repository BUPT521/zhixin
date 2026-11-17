import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'ai/ai_chat_service.dart';
import 'app_services.dart';
import 'ai/llm_config.dart';
import 'ai/llm_config_store.dart';
import 'application/account_service.dart';
import 'application/active_report_service.dart';
import 'application/cloud_backup_service.dart';
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
import 'application/search_index_service.dart';
import 'application/memory_scope_service.dart';
import 'application/plan_service.dart';
import 'application/search_service.dart';
import 'application/service_runtime.dart';
import 'application/settings_service.dart';
import 'application/study_plan_service.dart';
import 'application/sync_service.dart';
import 'application/time_policy_controller.dart';
import 'application/undo_service.dart';
import 'data/backup/data_package_service.dart';
import 'data/backup/data_version_service.dart';
import 'data/backup/restore_point_store.dart';
import 'data/attachment_store.dart';
import 'data/cloud/account_store.dart';
import 'data/cloud/cloud_preferences_store.dart';
import 'data/cloud/telemetry_store.dart';
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
import 'data/repository/plugin_metadata_store.dart';
import 'data/repository/schedule_repository.dart';
import 'data/repository/settings_repository.dart';
import 'data/repository/study_repository.dart';
import 'data/repository/study_plan_repository.dart';
import 'data/repository/task_repository.dart';
import 'domain/rules/time_policy.dart';
import 'platform/app_paths.dart';
import 'platform/app_info.dart';
import 'platform/first_frame.dart';
import 'platform/secure_secret_store.dart';
import 'plugins/persona/persona_catalog.dart';
import 'plugins/persona/persona_plugin.dart';
import 'plugins/runtime/plugin_runtime.dart';
import 'ui/theme_mode_controller.dart';
import 'ui/workspace_widgets.dart';

/// 打开一次库，把仓库与服务挂在这里；页面不从各自开库。
class AppScope extends StatefulWidget {
  const AppScope({
    super.key,
    required this.child,
    this.crashLog,
    this.ai,
    this.clock,
    required this.themeMode,
  });

  final Widget child;
  final CrashLog? crashLog;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 外观由应用根部持有，页面改它之后 MaterialApp 会立即重建。
  final ThemeModeController themeMode;

  /// 时间来源；为空时取系统时钟，测试传固定时钟让当天窗口不随运行时刻变化。
  final Clock? clock;

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
  late GuardedDatabase _db;
  late AppPaths paths;

  /// 外观在应用根部，页面读它当前的值，也通过它保存。
  ThemeModeController get themeMode => widget.themeMode;

  // 仓库按表分组，页面直接用；服务收进 [AppServices] 的六组门面，见下面。
  late ConversationRepository _conversations;
  late AttemptRepository _attempts;
  late TaskRepository _tasks;
  late ScheduleRepository _schedule;
  late MemoryRepository _memories;
  late StudyRepository _studyRecords;
  late AssessmentRepository _assessments;
  late MaterialRepository _materials;
  late StudyPlanRepository _studyPlans;

  late LlmConfigStore _llmStore;
  AiChatService? _configuredAi;

  /// 账号与云同步：令牌在 Keystore，服务地址与同步游标在应用私有目录。
  AccountService? _accountService;
  ActiveReportService? _activeReportService;
  late final CloudPreferencesStore _cloudPreferences;
  CloudBackupService? _cloudBackups;
  SyncService? _cloudSync;

  AccountService get _account => _accountService!;
  CloudBackupService get _backups => _cloudBackups!;
  SyncService get _sync => _cloudSync!;

  /// 第一方插件运行时；启动时装载，整库恢复与清空之后重读 app_meta。
  PluginRuntime? _pluginRuntime;

  /// 讨论、学习与系统学习共用的回答来源；设置页的连接测试仍用真实客户端。
  BuddyAi get _ai => widget.ai ?? _configuredAi!;
  late DataPackageService _dataPackages;
  late RevisionEngine _engine;
  late RevisionService _revisions;
  late RevisionPackageService _revisionPackages;
  late RestorePointStore _restorePoints;
  late AttachmentCache _attachmentCache;
  late CrashLog crashLog;

  late final Clock clock = widget.clock ?? systemClock;

  /// 每日截止小时与时间口径的唯一持有者；保存与撤销之后都从设置仓库重读。
  late final TimePolicyController _timePolicy = TimePolicyController(
    settings: _settings,
    clock: clock,
    onChanged: _onTimePolicyChanged,
  );

  /// 用户从查找结果带入本次回答的来源；发送一次后清空。
  final BroughtSources broughtSources = BroughtSources();

  /// 整库恢复、清空与导入之后加一；三栏据此在原处重读数据，页面状态不重置。
  final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  final DatabaseGate _gate = DatabaseGate();
  int _operationEpoch = 0;
  Timer? _searchIndexRefreshTimer;

  /// 写入触发的索引刷新静默期：连续提交时等最后一次写入之后只扫一次库。
  static const Duration _searchIndexQuietPeriod = Duration(seconds: 3);

  /// 语义索引的来源表：这几张表有了提交才需要补建索引。
  ///
  /// 其余业务表（目标、设置、版本历史等）的提交不改变索引内容；讨论与材料的
  /// 删除会经外键级联改到这里的表，仍然会触发。
  static const Set<String> _searchIndexSourceTables = {
    'material_page',
    'message',
    'attempt',
  };

  TimePolicy get timePolicy => _timePolicy.policy;

  /// 服务共用的运行环境；时间口径随保存的设置换新，数据代次随恢复与清空推进。
  late final ServiceRuntime _runtime = ServiceRuntime(
    policySource: () => timePolicy,
    filesDirSource: () => paths.filesDir,
    dataEpochSource: () => _operationEpoch,
    live: _db.live,
    recordFailure: crashLog.record,
  );

  late final EvidenceRepository _evidenceRepository = EvidenceRepository(_db);

  late final EmbeddingConfigStore _embeddingStore = EmbeddingConfigStore(
    SecureSecretStore(),
  );

  /// 检索索引配置的唯一入口：页面保存一次，应用根启动时恢复一次。
  late final EmbeddingSettingsService _embeddingSettings =
      EmbeddingSettingsService(store: _embeddingStore, index: _searchIndex);

  SearchIndexService? _searchIndexService;

  /// 检索索引按需创建；没有配置嵌入来源时只建全文索引。
  SearchIndexService get _searchIndex =>
      _searchIndexService ??= SearchIndexService(
        repository: _evidenceRepository,
        indexPath: paths.vectorIndexPath,
        indexLogPath: paths.vectorLogPath,
        epoch: () async => '${await _engine.currentGeneration(_connection!)}',
        clock: clock,
        recordFailure: crashLog.record,
      );

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
      capacity: _capacity,
      continueLast: _continueLast,
    ),
    library: LibraryServices(
      material: _material,
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
      account: _account,
      backups: _backups,
      sync: _sync,
      activeReport: _activeReportService!,
    ),
  );

  /// 讨论、作答、安排、材料、记忆、设置、数据版本、插件与账号九组服务。
  AppServices get services => _services;

  ChatServices get chat => _services.chat;

  StudyServices get study => _services.study;

  LibraryServices get library => _services.library;

  MemoryServices get memory => _services.memory;

  SettingsServices get settings => _services.settings;

  DataServices get data => _services.data;

  AccountServices get accountServices => _services.account;

  late final _transactions = WriteTransactions(_db);
  late final _settings = SettingsRepository(_db);

  late final ContextService _context = ContextService(
    tasks: _tasks,
    attempts: _attempts,
    schedule: _schedule,
    memories: _memories,
    conversations: _conversations,
    materials: _materials,
    runtime: _runtime,
    evidence: _evidence,
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

  late final SearchService _search = SearchService(evidence: _evidence);

  late final CapacityService _capacity = CapacityService(
    settings: _settings,
    tasks: _tasks,
    schedule: _schedule,
    runtime: _runtime,
    transactions: _transactions,
  );

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
    schedule: _schedule,
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
    schedule: _schedule,
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
    schedule: _schedule,
    revisions: _revisions,
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

  late final SettingsService _settingsEdit = SettingsService(
    settings: _settings,
    transactions: _transactions,
    llmStore: _llmStore,
    ai: _configuredAi!,
    runtime: _runtime,
    timePolicy: _timePolicy,
    dataVersions: _dataVersions,
    authorizeConfig: (config) => _account.prepareModelConfig(config),
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
      _refreshSearchIndex();
    },
    recordFailure: (error, stack, {required kind}) =>
        crashLog.record(error, stack, kind: kind),
  );

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

  late final Future<void> ready = _init();

  /// 测试装配入口；生产代码与页面不读它。
  @visibleForTesting
  late final AppScopeTesting testing = AppScopeTesting._(this);

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
    _db = GuardedDatabase(gate: _gate, resolve: () => _connection!);
    _db.onCommitted = _onCommitted;
    _llmStore = LlmConfigStore(SecureSecretStore());
    _cloudPreferences = CloudPreferencesStore(filesDir: paths.filesDir);
    _accountService = AccountService(
      store: AccountStore(SecureSecretStore()),
      preferences: _cloudPreferences,
      deviceName: '知新 ${appVersion.split('+').first}',
    );
    _activeReportService = ActiveReportService(
      store: TelemetryStore(filesDir: paths.filesDir),
      signedIn: () async => (await _account.snapshot()).session != null,
      serverBaseUrl: _account.serverBaseUrl,
      crashLog: crashLog,
      appVersion: appVersion,
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
      onDataChanged: _invalidatePendingWork,
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
      account: _account,
      versions: _dataVersions,
      filesDir: paths.filesDir,
      clock: clock,
    );
    _cloudSync = SyncService(
      account: _account,
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
    if (_embeddingSettings.configured) _refreshSearchIndexNow();
    // 附件清理与缓存补建跟首屏无关，而且耗时随数据量增长：放到首帧之后在
    // 后台做，首屏不再等它们，启动速度也不再取决于用久了攒下的图片数量。
    _scheduleAttachmentMaintenance();
    // 登录状态下启动之后自动同步一次；未登录时这一步什么都不做。
    unawaited(_sync.schedule());
    _scheduleActiveReport();
  }

  /// 首帧之后在空闲里尝试一次匿名活跃上报（ADR-0019）：不等待、不阻塞启动，
  /// 失败只写诊断记录；登录用户由服务端按请求日期统计，这一步会直接跳过。
  void _scheduleActiveReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_activeReportService?.reportIfDue() ?? Future<void>.value());
    });
  }

  /// 读取模型配置；选择知新服务时换成当前账号的访问令牌。
  ///
  /// 令牌不进 Keystore，每次回答前从这里取；没有登录时返回 null，回答按未
  /// 配置退回本地兜底，设置页另有说明。
  Future<LlmConfig?> _configuredModelConfig() async {
    final stored = await _llmStore.read();
    return _account.authorizeModelConfig(stored);
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
      await AttachmentStore(filesDir: paths.filesDir).cleanupUnreferenced(_db);
    } catch (error, stack) {
      crashLog.record(error, stack, kind: 'cleanup_attachments');
    }
    if (!mounted) return;
    try {
      await _gate.shared(() async {
        if (!await _attachmentCache.needsRebuild) return;
        await _attachmentCache.rebuild(_db, _engine.assets);
        await _attachmentCache.clearPendingRebuild();
      });
    } catch (error, stack) {
      // 补建失败不打断使用：缺图的位置已经按“找不到图片”显示，下次再补。
      crashLog.record(error, stack, kind: 'rebuild_attachments');
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
    _schedule = ScheduleRepository(connection, clock: clock);
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
    _refreshSearchIndex();
  }

  /// 数据代次变化后按当前数据补建检索索引；没有配置时只建全文索引。
  ///
  /// 来源表有提交之后与数据代次变化之后都走这里，等 [_searchIndexQuietPeriod] 再
  /// 执行，期间再次触发只顺延，避免连续提交时每次都全量扫库；立即需要索引的
  /// 入口仍直接调用刷新。
  void _refreshSearchIndex() {
    final index = _searchIndexService;
    if (index == null || !index.configured) return;
    _searchIndexRefreshTimer?.cancel();
    _searchIndexRefreshTimer = Timer(_searchIndexQuietPeriod, () {
      _searchIndexRefreshTimer = null;
      _refreshSearchIndexNow();
    });
  }

  /// 一次提交落库之后调用：来源表变了就排在安静期之后补建索引。
  void _onCommitted(Set<String> tables) {
    // 登录之后写入随自动同步推到服务端；同步本身应用的远端提交也会走到这里，
    // 这时没有待推送的提交，下一次同步只做一次位置核对。
    _cloudSync?.schedule();
    if (!tables.any(_searchIndexSourceTables.contains)) return;
    _refreshSearchIndex();
  }

  /// 后台补建索引；失败只写诊断记录，不打断界面，回答继续使用字面命中。
  ///
  /// 设置页的手动“更新索引”直接调用服务并捕获异常，看到的是就地说明。
  void _refreshSearchIndexNow() {
    unawaited(
      _searchIndex.refresh().catchError((Object error, StackTrace stack) {
        crashLog.record(error, stack, kind: 'semantic_index');
        return const IndexRefreshResult(failure: IndexFailure.error);
      }),
    );
  }

  @override
  void dispose() {
    _searchIndexRefreshTimer?.cancel();
    _cloudSync?.dispose();
    _accountService?.dispose();
    _configuredAi?.dispose();
    final index = _searchIndexService;
    if (index != null) unawaited(index.close());
    _searchIndexService = null;
    if (_connection != null) _db.close();
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
          // 启动时的等待与各页首读共用一个圈，尺寸只在这里定一次。
          return const forui.FScaffold(child: PageLoading());
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

/// 测试装配入口：库连接、独占写入区与仓库只在这里露出。
///
/// 页面与服务经 [AppServices] 与 [AppScopeState] 的基础句柄取数据；测试需要
/// 建库、写种子数据或注入故障时从这一个入口取，不再把仓库与连接公开成字段。
@visibleForTesting
final class AppScopeTesting {
  const AppScopeTesting._(this._state);

  final AppScopeState _state;

  GuardedDatabase get db => _state._db;

  DatabaseGate get gate => _state._gate;

  ServiceRuntime get runtime => _state._runtime;

  ConversationRepository get conversations => _state._conversations;
  AttemptRepository get attempts => _state._attempts;
  TaskRepository get tasks => _state._tasks;
  ScheduleRepository get schedule => _state._schedule;
  MemoryRepository get memories => _state._memories;
  StudyRepository get studyRecords => _state._studyRecords;
  AssessmentRepository get assessments => _state._assessments;
  MaterialRepository get materials => _state._materials;
  StudyPlanRepository get studyPlans => _state._studyPlans;
}
