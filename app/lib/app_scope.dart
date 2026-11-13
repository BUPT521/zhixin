import 'dart:async';
import 'dart:typed_data';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:sqflite/sqflite.dart';

import 'ai/ai_chat_service.dart';
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
import 'platform/secure_secret_store.dart';
import 'ui/theme_mode_controller.dart';

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

  late ConversationRepository conversations;
  late AttemptRepository attempts;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late MemoryRepository memories;
  late StudyRepository study;
  late AssessmentRepository assessments;
  late MaterialRepository materials;
  late StudyPlanRepository studyPlans;

  late LlmConfigStore llmStore;
  AiChatService? _configuredAi;

  /// 讨论、学习与系统学习共用的回答来源；设置页的连接测试仍用真实客户端。
  BuddyAi get ai => widget.ai ?? _configuredAi!;
  late DataPackageService packages;
  late RevisionEngine revisionsEngine;
  late RevisionService revisions;
  late RevisionPackageService revisionPackages;
  late RestorePointStore restorePoints;
  late AttachmentCache attachmentCache;
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

  late final ContextService contextService = ContextService(
    tasks: tasks,
    attempts: attempts,
    schedule: schedule,
    memories: memories,
    conversations: conversations,
    materials: materials,
    policy: () => timePolicy,
    evidence: evidenceService,
  );

  late final MaterialService materialService = MaterialService(
    materials: materials,
    transactions: _transactions,
    dataEpoch: () => _operationEpoch,
  );

  late final SearchService searchService = SearchService(
    evidence: evidenceService,
  );

  late final EvidenceRepository evidenceRepository = EvidenceRepository(
    db.rawDb,
  );

  late final EmbeddingConfigStore embeddingStore = EmbeddingConfigStore(
    SecureSecretStore(),
  );

  /// 当前嵌入配置；启动时读取，设置页保存之后由应用根重新应用。
  EmbeddingConfig? embeddingConfig;

  SemanticIndexService? _semanticIndex;

  /// 语义索引按需创建；没有配置时不打开向量库。
  SemanticIndexService get semanticIndex =>
      _semanticIndex ??= SemanticIndexService(
        repository: evidenceRepository,
        indexPath: paths.vectorIndexPath,
        epoch: () async => '${await revisionsEngine.headId(db.raw)}',
        clock: clock,
      );

  late final CrossSessionService crossSessionService = CrossSessionService(
    repository: evidenceRepository,
  );

  late final EvidenceService evidenceService = EvidenceService(
    repository: evidenceRepository,
    semantic: semanticIndex,
    crossSession: crossSessionService,
  );

  late final _transactions = WriteTransactions(db);
  late final _settings = SettingsRepository(db);

  late final CapacityService capacityService = CapacityService(
    settings: _settings,
    tasks: tasks,
    schedule: schedule,
    policy: () => timePolicy,
    transactions: _transactions,
  );

  late final ContinueService continueService = ContinueService(
    conversations: conversations,
    plans: studyPlans,
  );

  /// 讨论与作答共用：记录归属优先，没有时沿用最近一次学习的目标。
  late final MemoryScopeService memoryScopeService = MemoryScopeService(
    conversations: conversations,
    attempts: attempts,
  );

  late final StudyPlanService studyPlanService = StudyPlanService(
    plans: studyPlans,
    materials: materials,
    ai: ai,
    context: contextService,
    conversations: conversations,
    study: study,
    transactions: _transactions,
  );

  late final DiscussionService discussionService = DiscussionService(
    conversations: conversations,
    ai: ai,
    context: contextService,
    memoryScope: memoryScopeService,
    memories: memories,
    revisions: revisions,
    tasks: tasks,
    materials: materials,
    policy: () => timePolicy,
    transactions: _transactions,
    filesDir: () => paths.filesDir,
    cleanupAttachmentPaths: cleanupAttachmentPaths,
    assets: revisionsEngine.assets,
    cache: attachmentCache,
    dataEpoch: () => _operationEpoch,
    recordFailure: crashLog.record,
  );

  late final LearningService learningService = LearningService(
    attempts: attempts,
    conversations: conversations,
    study: study,
    memories: memories,
    revisions: revisions,
    schedule: schedule,
    tasks: tasks,
    assessments: assessments,
    ai: ai,
    context: contextService,
    memoryScope: memoryScopeService,
    policy: () => timePolicy,
    transactions: _transactions,
    filesDir: () => paths.filesDir,
    dataEpoch: () => _operationEpoch,
    recordFailure: crashLog.record,
  );

  late final PlanService planService = PlanService(
    tasks: tasks,
    schedule: schedule,
    revisions: revisions,
    policy: () => timePolicy,
    studyPlans: studyPlans,
    transactions: _transactions,
  );

  late final MemoryService memoryService = MemoryService(
    memories,
    transactions: _transactions,
  );

  late final MemoryProposalService memoryProposals = MemoryProposalService(
    attempts: attempts,
    conversations: conversations,
    memories: memories,
    transactions: _transactions,
  );

  late final SettingsService settingsService = SettingsService(
    settings: _settings,
    transactions: _transactions,
    llmStore: llmStore,
    ai: _configuredAi!,
    policy: () => timePolicy,
    onPolicyChanged: _refreshDayCutoffHour,
    restore: restore,
    resetAll: resetAllData,
  );

  late final Future<void> ready = _init();

  Future<void> _init() async {
    paths = await AppPaths.resolve();
    await paths.ensureDirectories();
    crashLog = widget.crashLog ?? CrashLog(filesDir: paths.filesDir);
    crashLog.recordLaunch();
    db = GuardedDatabase(gate: gate, resolve: () => _connection!);
    llmStore = LlmConfigStore(SecureSecretStore());
    _configuredAi = AiChatService(store: llmStore);
    packages = DataPackageService(
      filesDir: paths.filesDir,
      dbPath: paths.dbPath,
      factory: databaseFactory,
      appVersion: appVersion,
      schemaVersion: zhixinSchemaVersion,
      clock: clock,
    );
    await packages.recoverInterruptedRestore();
    await _open();
    revisionsEngine = RevisionEngine(clock: clock);
    db.revisions = revisionsEngine;
    attachmentCache = AttachmentCache(filesDir: () => paths.filesDir);
    revisions = RevisionService(
      db: db,
      raw: () => _connection!,
      engine: revisionsEngine,
      clock: clock,
      cache: attachmentCache,
      onUndoApplied: _refreshDayCutoffHour,
      onDataChanged: _invalidatePendingWork,
      onCacheFailure: (error, stack) =>
          crashLog.record(error, stack, kind: 'rebuild_attachments_restore'),
    );
    revisionPackages = RevisionPackageService(
      engine: revisionsEngine,
      assets: revisionsEngine.assets,
      factory: databaseFactory,
      schemaVersion: zhixinSchemaVersion,
      appVersion: appVersion,
      clock: clock,
    );
    restorePoints = RestorePointStore(filesDir: paths.filesDir, clock: clock);
    await AttachmentStore(filesDir: paths.filesDir).cleanupUnreferenced(db.raw);
    try {
      await attachmentCache.rebuild(db.raw, revisionsEngine.assets);
    } catch (error) {
      crashLog.record(error, null, kind: 'rebuild_attachments');
    }
    embeddingConfig = await embeddingStore.read();
    // 重启之后按当前数据补建索引：数据代次与索引里的不一致时整份重建。
    applyEmbeddingConfig(embeddingConfig);
  }

  /// 应用一套嵌入配置：换掉嵌入来源，清掉旧模型对应的索引，再在后台补建。
  ///
  /// 没有配置或关闭语义索引时不读向量库，回答前后的原文与关键词检索照常。
  void applyEmbeddingConfig(EmbeddingConfig? config, {bool refresh = true}) {
    embeddingConfig = config;
    final runtime = embeddingRuntime(config);
    semanticIndex.configure(client: runtime.client, canSend: runtime.canSend);
    if (refresh && semanticIndex.configured) {
      unawaited(semanticIndex.refresh());
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
    study = StudyRepository(connection, clock: clock);
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
    if (!semanticIndex.configured) return;
    _semanticRefreshTimer?.cancel();
    _semanticRefreshTimer = Timer(_semanticQuietPeriod, () {
      _semanticRefreshTimer = null;
      unawaited(semanticIndex.refresh());
    });
  }

  /// 整库恢复：先预检数据包，再把当前状态存成一份恢复点，最后替换库与附件。
  ///
  /// 恢复点与恢复入口使用同一种版本库备份，恢复成功后仍然保留，用户可以从
  /// 数据版本页回到恢复前；恢复点写不出来时中止，当前库不动。库替换成功后
  /// 图片缓存重建失败只返回提醒，不再让界面把整次恢复报成失败。
  Future<String?> restore(Uint8List bytes) async {
    _operationEpoch++;
    String? cacheWarning;
    await gate.exclusive(() async {
      await revisionPackages.validateRepositoryBytes(bytes);
      final summary = await currentRestoreSummary();
      try {
        await restorePoints.capture(
          head: summary.head,
          commitCount: summary.commitCount,
          namedCount: summary.namedCount,
          reason: '整库恢复前自动保存',
          write: (path) =>
              revisionPackages.backupRepository(_connection!, path),
        );
      } catch (error, stack) {
        crashLog.record(error, stack, kind: 'restore_point_capture');
        throw const BackupException('恢复前保存当前状态失败，本次恢复没有执行；当前数据没有改动。');
      }
      // 恢复过程中失败时保留刚写好的恢复点：它要么与回滚后的数据一致，
      // 要么就是回滚没有完成时唯一可用的旧状态，交给用户确认后再删除。
      await packages.restorePackage(bytes, currentDb: db, openDb: _open);
      try {
        await attachmentCache.rebuild(db.raw, revisionsEngine.assets);
      } catch (error, stack) {
        crashLog.record(error, stack, kind: 'rebuild_attachments_restore');
        cacheWarning = '数据已恢复，但图片缓存没有重建完成，下次打开应用会再试。';
      }
    });
    dataVersion.value++;
    _refreshSemanticIndex();
    return cacheWarning;
  }

  /// 恢复数据包前的预检：先确认包能通过校验，再返回包内规模。
  ///
  /// 不是版本库备份时交给旧数据包的校验；校验失败会抛出，界面据此拒绝恢复。
  Future<RestoreInspection> inspectRestorePackage(Uint8List bytes) async {
    final repository = await revisionPackages.inspectRepository(bytes);
    if (repository != null) {
      return RestoreInspection(
        kind: RestorePackageKind.repository,
        schemaVersion: zhixinSchemaVersion,
        appVersion: repository.appVersion,
        exportedAt: repository.exportedAt,
        head: repository.head,
        commitCount: repository.commitCount,
        namedCount: repository.namedCount,
      );
    }
    final data = await packages.inspectPackage(bytes);
    return RestoreInspection(
      kind: RestorePackageKind.currentData,
      schemaVersion: data.schemaVersion,
      appVersion: data.appVersion,
      exportedAt: data.exportedAt,
      rowCount: data.rowCount,
    );
  }

  /// 当前库的规模；恢复前的说明与恢复点里的记录共用这一份。
  Future<RestoreSummary> currentRestoreSummary() async {
    final usage = await revisions.storageUsage();
    final head = await revisionsEngine.headId(db.raw);
    return RestoreSummary(
      head: head,
      commitCount: usage.commitCount,
      namedCount: usage.namedCount,
    );
  }

  Future<void> resetAllData() async {
    _operationEpoch++;
    await gate.exclusive(() async {
      await _connection?.close();
      _connection = null;
      await deleteLocalStudyData(
        filesDir: paths.filesDir,
        dbPath: paths.dbPath,
      );
      await paths.ensureDirectories();
      await _open();
    });
    dataVersion.value++;
    _refreshSemanticIndex();
  }

  /// 导出当前数据：业务投影与附件，不含历史。
  Future<void> exportCurrentData(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.exportCurrent(_connection!, outputPath),
    );
  }

  /// 导入当前数据包之前先取 `HEAD`，提交时重新核对。
  Future<int> currentHead() => revisionsEngine.headId(db.raw);

  Future<void> importCurrentData(
    Uint8List bytes, {
    required int expectedHead,
  }) async {
    _operationEpoch++;
    await gate.exclusive(
      () => revisionPackages.importCurrent(
        _connection!,
        bytes,
        expectedHead: expectedHead,
      ),
    );
    await attachmentCache.rebuild(db.raw, revisionsEngine.assets);
    dataVersion.value++;
    _refreshSemanticIndex();
  }

  /// 版本库备份：整库快照，包含历史、命名版本与附件。
  Future<void> backupRepository(String outputPath) {
    return gate.exclusive(
      () => revisionPackages.backupRepository(_connection!, outputPath),
    );
  }

  Future<void> cleanupAttachmentPaths(Iterable<String> candidates) {
    final pathsToCheck = List<String>.unmodifiable(candidates);
    return gate.shared(
      () =>
          AttachmentStore(filesDir: paths.filesDir)
              .cleanupCandidates(db.raw, pathsToCheck),
    );
  }

  @override
  void dispose() {
    _semanticRefreshTimer?.cancel();
    _configuredAi?.dispose();
    _semanticIndex?.close();
    _semanticIndex = null;
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
