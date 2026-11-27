import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'ai/ai_chat_service.dart';
import 'app_composition.dart';
import 'app_services.dart';
import 'app_space_coordinator.dart';
import 'application/brought_sources.dart';
import 'application/prefetch_service.dart';
import 'application/service_runtime.dart';
import 'application/update_check_service.dart';
import 'data/cloud/server_client.dart' show ServerClient;
import 'data/db/database_gate.dart';
import 'data/db/guarded_database.dart';
import 'data/diagnostics/crash_log.dart';
import 'data/repository/assessment_repository.dart';
import 'data/repository/attempt_repository.dart';
import 'data/repository/conversation_repository.dart';
import 'data/repository/material_repository.dart';
import 'data/repository/memory_repository.dart';
import 'data/repository/study_plan_repository.dart';
import 'data/repository/study_repository.dart';
import 'data/repository/task_repository.dart';
import 'domain/rules/time_policy.dart';
import 'platform/app_paths.dart';
import 'platform/first_frame.dart';
import 'startup_failure_page.dart';
import 'ui/theme_accent_controller.dart';
import 'ui/theme_mode_controller.dart';
import 'ui/workspace_widgets.dart';

/// 打开一次库，把仓库与服务挂在这里；页面不从各自开库。
///
/// 这一层只保留 InheritedWidget 与首屏就绪状态：装配见 [AppComposition]，
/// 后台维护见 [AppMaintenance]，换空间与清空见 [AppSpaceCoordinator]。
class AppScope extends StatefulWidget {
  const AppScope({
    super.key,
    required this.child,
    this.crashLog,
    this.ai,
    this.clock,
    this.serverClientFactory,
    this.spaces,
    this.spaceId = AppSpaces.local,
    this.changeSpace,
    required this.themeMode,
    required this.themeAccent,
    this.networkAllowed,
    this.onAgreeTerms,
    this.updates,
    this.waitForData = true,
  });

  final Widget child;
  final CrashLog? crashLog;
  final AppSpaces? spaces;
  final String spaceId;
  final Future<void> Function(
    String id, {
    required bool adoptLocal,
    required bool deleteCurrent,
    String? label,
  })?
  changeSpace;

  /// 连服务端用的客户端；测试换成进程内的假服务端，为空时按地址直连。
  final ServerClient Function(String baseUrl)? serverClientFactory;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 外观由应用根部持有，页面改它之后 MaterialApp 会立即重建。
  final ThemeModeController themeMode;

  /// 主题色与深浅色放在一起，同样由应用根部持有，改完立即生效。
  final ThemeAccentController themeAccent;

  /// 联网功能是否可用：首次启动引导里同意用户须知之前为假，匿名上报与启动时
  /// 的更新检查都不执行；为空表示这条链路上没有引导，始终可用。
  final ValueListenable<bool>? networkAllowed;

  /// 在设置页或账号页同意用户须知；由应用根部写引导状态并打开联网。
  final Future<void> Function()? onAgreeTerms;

  /// 更新检查服务；测试注入计数用的替身，为空时按当前服务地址新建。
  final UpdateCheckService? updates;

  /// 引导期间为假：页面不用先等数据库打开，先显示引导。首屏数据仍然在后台
  /// 装配，引导结束之后再把页面守到就绪状态上。
  final bool waitForData;

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

class AppScopeState extends State<AppScope> with WidgetsBindingObserver {
  /// 整库恢复、清空与导入之后加一；三栏据此在原处重读数据，页面状态不重置。
  final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);

  /// 用户从查找结果带入本次回答的来源；发送一次后清空。
  final BroughtSources broughtSources = BroughtSources();

  /// 应用根的装配：装配顺序留在 [AppComposition]，这里只读它的结果。
  late final AppComposition _composition = AppComposition(
    clock: widget.clock ?? systemClock,
    dataVersion: dataVersion,
    networkAllowedSource: () => networkAllowed,
    spaces: widget.spaces,
    spaceId: widget.spaceId,
    changeSpace: widget.changeSpace,
    crashLogOverride: widget.crashLog,
    serverClientFactory: widget.serverClientFactory,
    ai: widget.ai,
    updates: widget.updates,
  );

  /// 空间切换与清空。
  late final AppSpaceCoordinator _spaces = _composition.spaceCoordinator;

  /// 数据目录；换空间之后指向新空间。
  AppPaths get paths => _composition.paths;

  /// 设备级目录：空间标识、引导状态与诊断都写在这里，换空间时不变。
  AppPaths get devicePaths => widget.spaces?.device ?? paths;

  String get spaceId => widget.spaceId;
  AppSpaces? get spaces => widget.spaces;
  bool get managesSpaces => widget.changeSpace != null;

  /// 联网功能是否可用；没有引导的装配（测试）始终可用。
  bool get networkAllowed => widget.networkAllowed?.value ?? true;

  /// 首屏装配是否已经成功完成；引导页据此判断账号服务能不能用。
  bool get dataReady => _initDone && _initError == null;

  /// 崩溃记录；首屏装配成功之后才可用，界面用它记录可预期的失败说明。
  CrashLog get crashLog => _composition.crashLog;

  /// 时间来源；为空时取系统时钟。
  Clock get clock => _composition.clock;

  /// 每日截止小时与时间口径的当前值。
  TimePolicy get timePolicy => _composition.timePolicy;

  /// 二级界面首屏的预读入口；页面打开时先看有没有已经读完的结果。
  PrefetchService get prefetch => _composition.prefetch;

  /// 讨论、作答、安排、材料、记忆、设置、数据版本、插件与账号八组服务。
  AppServices get services => _composition.services;

  ChatServices get chat => _composition.services.chat;

  StudyServices get study => _composition.services.study;

  LibraryServices get library => _composition.services.library;

  MemoryServices get memory => _composition.services.memory;

  SettingsServices get settings => _composition.services.settings;

  DataServices get data => _composition.services.data;

  AccountServices get accountServices => _composition.services.account;

  /// 外观在应用根部，页面读它当前的值，也通过它保存。
  ThemeModeController get themeMode => widget.themeMode;

  /// 当前主题色，设置页读它显示选中的色块，也通过它保存。
  ThemeAccentController get themeAccent => widget.themeAccent;

  /// 同意用户须知与隐私政策：写引导状态，并立即打开联网功能。
  Future<void> agreeToTerms() async {
    final agree = widget.onAgreeTerms;
    if (agree != null) await agree();
  }

  /// 保存服务地址；地址变了之后账号与同步都按新实例重新读。
  Future<void> configureServerBaseUrl(String address) =>
      _composition.configureServerBaseUrl(address);

  /// 清空数据：先停自动同步并清云端，再按是否管理空间删掉整个空间或只删本机库。
  Future<void> clearAllData({required String password}) =>
      _spaces.clearAllData(password: password);

  /// 删掉一个本机空间：当前空间连同数据目录一起换掉，其余空间直接删目录。
  Future<void> deleteLocalSpace(String id) => _spaces.deleteLocalSpace(id);

  /// 换空间之前关掉这一份装配；多次调用返回同一个 Future。
  Future<void> closeSpace() => _spaces.closeSpace();

  /// 回答恢复入口只核对是否有登录会话，实际请求再读取配置与访问令牌。
  Future<bool> modelReady() => _composition.modelReady();

  /// 启动失败时留下的原因：失败页展示它，本机诊断文件与反馈都用同一份说明。
  /// 打开成功之后写进诊断文件并清空，下次启动不再重复记。
  Object? _startupFailure;
  StackTrace? _startupStack;
  bool _retryingStartup = false;

  /// 首屏就绪：打开数据目录与数据库、装配服务。启动失败时可以重建一个新的
  /// Future，失败页的“重试”不必重启应用；重建之前先把已经打开的连接关掉。
  late Future<void> ready;

  /// 首屏装配是否已经结束（成功或失败）。结束时页面不再等 Future，直接按结果
  /// 渲染；引导期间 [AppScope.waitForData] 为假，可以不等它先把引导显示出来。
  bool _initDone = false;
  Object? _initError;
  StackTrace? _initStack;

  Future<void> _initTracked() async {
    _initDone = false;
    _initError = null;
    _initStack = null;
    final previousFailure = _startupFailure;
    final previousStack = _startupStack;
    try {
      await _composition.initialize(
        previousFailure: previousFailure,
        previousStack: previousStack,
      );
      _startupFailure = null;
      _startupStack = null;
    } catch (error, stack) {
      _startupFailure = error;
      _startupStack = stack;
      _initError = error;
      _initStack = stack;
      _initDone = true;
      rethrow;
    }
    _initDone = true;
  }

  /// 失败页的重试：关掉可能已经打开的旧连接，重新执行一次启动装配。
  Future<void> _retryStartup() async {
    if (_retryingStartup) return;
    setState(() => _retryingStartup = true);
    await _composition.discardConnection();
    final next = _initTracked();
    setState(() {
      ready = next;
    });
    try {
      await next;
    } catch (_) {
      // 失败页会按新的错误重画，这里不吞掉界面上原来的说明。
    } finally {
      if (mounted) setState(() => _retryingStartup = false);
    }
  }

  /// 测试装配入口；生产代码与页面不读它。
  @visibleForTesting
  late final AppScopeTesting testing = AppScopeTesting._(this);

  @override
  void initState() {
    super.initState();
    // 进入后台时冲刷记忆使用统计；能走到这里说明应用根已经装配到监听阶段。
    WidgetsBinding.instance.addObserver(this);
    ready = _initTracked();
    // 首屏数据就绪（或开库失败）之后放行第一帧；没压过第一帧时这次调用
    // 什么都不做，测试照常跑。
    unawaited(
      ready
          .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
          .whenComplete(FirstFrameGate.release),
    );
  }

  /// 应用进入后台（`paused` 或 `hidden`）时冲刷记忆使用统计；回到前台不触发。
  ///
  /// 首屏服务还没装配完时不碰它们：后台事件可能早于启动完成。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    if (!_composition.initialized || _spaces.closing) return;
    _composition.maintenance.flushMemoryUsageOnPause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _composition.dispose();
    dataVersion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = widget.networkAllowed;
    if (allowed == null) return _content(allowNetwork: true);
    return ValueListenableBuilder<bool>(
      valueListenable: allowed,
      builder: (context, value, _) => _content(allowNetwork: value),
    );
  }

  Widget _content({required bool allowNetwork}) {
    // 首次启动引导不读数据库：先把引导显示出来，首屏数据在后台继续装配，
    // 引导结束之后再把首页守到就绪状态上。
    if (!widget.waitForData) {
      return _AppScopeData(
        state: this,
        networkAllowed: allowNetwork,
        child: widget.child,
      );
    }
    if (_initDone) {
      if (_initError case final error?) return _failure(error, _initStack);
      return _AppScopeData(
        state: this,
        networkAllowed: allowNetwork,
        child: widget.child,
      );
    }
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _failure(snapshot.error!, snapshot.stackTrace);
        }
        if (snapshot.connectionState == ConnectionState.done) {
          return _AppScopeData(
            state: this,
            networkAllowed: allowNetwork,
            child: widget.child,
          );
        }
        // 启动时还没有页面可以摆骨架，用整屏等待的圈；尺寸只在 PageLoading 里定。
        return const forui.FScaffold(child: PageLoading());
      },
    );
  }

  /// 启动失败时的页面；失败原因写进本机诊断记录，同一次失败可能因重画多次进入，
  /// 记录本身可以重复。
  Widget _failure(Object error, StackTrace? stack) {
    try {
      _composition.crashLog.record(error, stack, kind: 'database_open');
    } catch (_) {
      // 诊断记录本身不可用时仍要显示可行动说明。
    }
    return StartupFailurePage(
      error: error,
      stack: stack,
      retrying: _retryingStartup,
      onRetry: _retryStartup,
      diagnostics: startupDiagnostics(error, stack),
    );
  }
}

class _AppScopeData extends InheritedWidget {
  const _AppScopeData({
    required this.state,
    required this.networkAllowed,
    required super.child,
  });

  final AppScopeState state;

  /// 联网开关的当前值；变化时依赖应用作用域的页面重画，例如本机模式下账号页
  /// 换成同意入口、同意之后换回登录卡。
  final bool networkAllowed;

  @override
  bool updateShouldNotify(_AppScopeData oldWidget) =>
      oldWidget.state != state || oldWidget.networkAllowed != networkAllowed;
}

/// 测试装配入口：库连接、独占写入区与仓库只在这里露出。
///
/// 页面与服务经 [AppServices] 与 [AppScopeState] 的基础句柄取数据；测试需要
/// 建库、写种子数据或注入故障时从这一个入口取，不再把仓库与连接公开成字段。
@visibleForTesting
final class AppScopeTesting {
  const AppScopeTesting._(this._state);

  final AppScopeState _state;

  GuardedDatabase get db => _state._composition.db;

  DatabaseGate get gate => _state._composition.gate;

  ServiceRuntime get runtime => _state._composition.runtime;

  ConversationRepository get conversations => _state._composition.conversations;
  AttemptRepository get attempts => _state._composition.attempts;
  TaskRepository get tasks => _state._composition.tasks;
  MemoryRepository get memories => _state._composition.memories;
  StudyRepository get studyRecords => _state._composition.studyRecords;
  AssessmentRepository get assessments => _state._composition.assessments;
  MaterialRepository get materials => _state._composition.materials;
  StudyPlanRepository get studyPlans => _state._composition.studyPlans;
}
