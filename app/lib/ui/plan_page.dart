import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/plan_service.dart';
import '../domain/models/study.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'plan_actions.dart';
import 'plan_goals_tab.dart';
import 'plan_items_tab.dart';
import 'plan_operations_tab.dart';
import 'plan_schedule_tab.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_segmented.dart';
import 'zhixin_toast.dart';

/// 一次周订阅带回的数据与对应的周一。
///
/// 周一是订阅时要求的周，跟着数据一起回来：换周过程中迟到的结果能认出自己在读
/// 哪一周，页面据此丢掉不属于当前目标周的内容。
typedef WeekSnapshot = ({DateTime weekStart, PlanWeek week});

/// 安排：每周日程、系统学习、学习事项与 AI 改动的撤销。
///
/// 底栏页与事项详情共用这一份周订阅与四个页签，但入口分开：底栏页由
/// [HomeShell] 常驻，切栏与跨栏跳转通过通知传进来；事项详情由 [PlanPage.detail]
/// 独立推入，只认一个事项编号，不看当前底栏。页签本身在
/// `plan_*_tab.dart` 里，只接收这一周与写入动作（[PlanActions]）。
class PlanPage extends StatefulWidget {
  const PlanPage({
    super.key,
    this.activeTab,
    this.tabIndex = 2,
    this.request,
    this.onOpenMaterials,
    this.watchWeek,
    this.preload,
  }) : initialItemId = null;

  /// 事项详情入口：推入一条事项并展开它的操作面板，不参与底栏切栏。
  const PlanPage.detail({super.key, required String itemId, this.watchWeek})
    : initialItemId = itemId,
      activeTab = null,
      tabIndex = 2,
      request = null,
      onOpenMaterials = null,
      preload = null;

  /// 详情页要展开的事项；为空时按底栏页处理。
  final String? initialItemId;

  /// 底栏当前栏的下标；为空时按常驻当前页处理，二级入口直接打开安排。
  final ValueListenable<int>? activeTab;
  final int tabIndex;

  /// 底栏放行预读时为真：首页读完之后在后台先订阅本周，第一次切过来直接
  /// 是内容，不再在切栏动画里看一段骨架。
  final ValueListenable<bool>? preload;

  /// 从别的栏目跳到安排时带的请求；每次变化都把页签复位到日程。
  final ValueListenable<int>? request;
  final VoidCallback? onOpenMaterials;

  /// 一周数据的流式读法；为空时订阅应用根里的安排服务。
  ///
  /// 测试传入可控制的流，用来按周交回数据，并验证换周只保留最新一条订阅。
  final Stream<PlanWeek> Function(DateTime weekStart)? watchWeek;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  /// 订阅带回的一周数据；换周与刷新都会换掉它。
  PlanWeek? _week;

  /// 目标周的周一；页面决定要读哪一周时改它。
  DateTime? _weekAnchor;

  /// 屏幕上这一份数据属于哪一周；数据到达之后才更新，列表据此淡入，
  /// 同一周的刷新与从详情返回不闪。
  DateTime? _shownAnchor;

  /// 当前目标周的订阅；为空表示还没有切到过安排页。
  ///
  /// 换周与重试都只换一条流，写入之后的重读、迟到结果的丢弃都由数据层与
  /// [LiveView] 完成（ADR-0014）。
  Stream<WeekSnapshot>? _weekStream;

  /// 首读失败的说明；已经显示过内容时保留那一份，不换成错误页。
  String? _error;

  bool _openedInitial = false;
  int _tab = 0;

  /// 系统学习列表是否展开全部计划；与页签状态一起留在页面上。
  bool _showAllPlans = false;

  /// 周视图是否展开；换周重建页签时保持展开，滑动与滚动位置由页签自己保留。
  bool _showWeekGrid = false;

  /// 进过的页签常驻：切回来不再重建，滚动位置一并保住。
  final Set<int> _visited = {0};

  bool get _active =>
      widget.activeTab == null || widget.activeTab!.value == widget.tabIndex;

  /// 当前栏，或者底栏已经放行预读：两种情况都可以开始订阅。
  bool get _shouldRead => _active || (widget.preload?.value ?? false);

  /// 底栏页放行预读或切到安排之后，四个页签一次建好；详情入口不预建页签，
  /// 它只显示调用方要展开的那一条事项。
  bool get _shouldKeepAllTabs =>
      widget.preload?.value == true || (_active && widget.activeTab != null);

  /// 本地写入失败时给一句可行动的说明；异常本身进本机诊断记录。
  void _reportFailure(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    String? kept,
    String? next,
  }) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: action,
      kind: kind,
      kept: kept,
      next: next,
    );
    showToast(context, message);
  }

  /// 撤销之后的重读由订阅完成，提交服务仍要求一个回调，这里不额外做什么。
  @override
  void initState() {
    super.initState();
    widget.activeTab?.addListener(_onActiveChanged);
    widget.preload?.addListener(_onActiveChanged);
    widget.request?.addListener(_onRequestChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_weekStream != null) {
      _preloadTabs(notify: false);
      return;
    }
    if (!_shouldRead) return;
    final weekStart = _weekAnchor ?? _currentWeekStart();
    _weekAnchor = weekStart;
    _weekStream = _createStream(weekStart);
    _preloadTabs(notify: false);
  }

  @override
  void didUpdateWidget(covariant PlanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTab != widget.activeTab) {
      oldWidget.activeTab?.removeListener(_onActiveChanged);
      widget.activeTab?.addListener(_onActiveChanged);
    }
    if (oldWidget.preload != widget.preload) {
      oldWidget.preload?.removeListener(_onActiveChanged);
      widget.preload?.addListener(_onActiveChanged);
    }
    if (oldWidget.request != widget.request) {
      oldWidget.request?.removeListener(_onRequestChanged);
      widget.request?.addListener(_onRequestChanged);
    }
    if (_weekStream == null && _shouldRead) {
      final weekStart = _weekAnchor ?? _currentWeekStart();
      _weekAnchor = weekStart;
      setState(() {
        _weekStream = _createStream(weekStart);
        _preloadTabs(notify: false);
      });
    } else {
      _preloadTabs(notify: false);
    }
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onActiveChanged);
    widget.preload?.removeListener(_onActiveChanged);
    widget.request?.removeListener(_onRequestChanged);
    super.dispose();
  }

  DateTime _currentWeekStart() =>
      AppScope.of(context).timePolicy
          .naturalWeekStart(AppScope.of(context).timePolicy.now);

  Stream<WeekSnapshot> _createStream(DateTime weekStart) {
    final read = widget.watchWeek ?? AppScope.of(context).study.plan.watchWeek;
    return read(weekStart).map((week) => (weekStart: weekStart, week: week));
  }

  /// 重试首读：只换一条订阅，已经显示的一周保留到新数据回来。
  void _reload() {
    final weekStart = _weekAnchor ?? _shownAnchor;
    if (weekStart == null) return;
    setState(() {
      _weekStream = _createStream(weekStart);
      _error = null;
    });
  }

  /// 订阅带回一份数据：按周一是哪一周决定保留还是丢掉。
  void _onWeek(WeekSnapshot snapshot) {
    if (snapshot.weekStart != _weekAnchor) return;
    setState(() {
      _week = snapshot.week;
      _shownAnchor = snapshot.weekStart;
      _error = null;
    });
    unawaited(_openInitial(snapshot));
  }

  void _onWeekError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取安排',
      kind: 'plan_week_read',
      kept: '已经显示的一周保持不变',
      next: '可以在页面内重试',
    );
    setState(() => _error = message);
    showToast(context, message);
  }

  /// 详情入口：首份数据回来之后按编号补读事项并展开它。
  Future<void> _openInitial(WeekSnapshot snapshot) async {
    final itemId = widget.initialItemId;
    if (itemId == null || _openedInitial) return;
    _openedInitial = true;
    final item = await _itemById(itemId);
    if (!mounted || item == null) return;
    await _actions().openItem(item);
  }

  /// 底栏切到安排、或预读放行时开始订阅，并把四个页签一次建好。
  void _onActiveChanged() {
    if (!mounted || !_shouldRead) return;
    final needStream = _weekStream == null;
    final needTabs = _shouldKeepAllTabs && _visited.length < 4;
    if (!needStream && !needTabs) return;
    if (needStream) {
      final weekStart = _weekAnchor ?? _currentWeekStart();
      _weekAnchor = weekStart;
      setState(() {
        _weekStream = _createStream(weekStart);
        _preloadTabs(notify: false);
      });
      return;
    }
    _preloadTabs();
  }

  /// 四个页签一次建好：页签只接收这一周的数据，建好不额外读库；切页签时
  /// 直接显示内容，滚动位置与展开状态也一起留住。
  void _preloadTabs({bool notify = true}) {
    if (!_shouldKeepAllTabs || _visited.length == 4) return;
    void apply() => _visited.addAll(const [1, 2, 3]);
    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  /// 从别的栏目跳过来：把页签复位到日程，并保证已经订阅周数据。
  void _onRequestChanged() {
    setState(() {
      _tab = 0;
      _visited.add(0);
      if (_shouldKeepAllTabs) _visited.addAll(const [1, 2, 3]);
    });
    _onActiveChanged();
  }

  /// 换周只换一条新的流，旧订阅由 [LiveView] 退订。
  void _selectWeek(DateTime date) {
    final policy = AppScope.of(context).timePolicy;
    final weekStart = policy.naturalWeekStart(date);
    if (weekStart == _weekAnchor) return;
    setState(() {
      _weekAnchor = weekStart;
      _weekStream = _createStream(weekStart);
      _error = null;
    });
  }

  /// 从当前目标周前后移动；连续点按时按目标周累加，不等上一次读回。
  void _stepWeek(int weeks) {
    final from = _weekAnchor ?? _shownAnchor;
    if (from == null) return;
    _selectWeek(DateTime(from.year, from.month, from.day + 7 * weeks));
  }

  /// 已完成列表里可能读到的事项目前不在这一份数据里：先查已读到的，再补读。
  Future<PlanItem?> _itemById(String id) async {
    for (final item in _week?.items ?? const <PlanItem>[]) {
      if (item.id == id) return item;
    }
    try {
      return await AppScope.of(context).study.plan.itemById(id);
    } catch (_) {
      return null;
    }
  }

  /// 页面这一周的写入动作；每次重建换一份，页签按需调用。
  PlanActions _actions() => PlanActions(
    context: context,
    week: _week,
    onReportFailure: _reportFailure,
    goalName: _goalName,
    openStudy: openPlanItem,
    openDiscussion: openDiscussion,
    openStudyPlan: openStudyPlan,
  );

  String _goalName(String? id) {
    if (id == null) return '无归属';
    final goals = _week?.goals ?? const <LearningGoal>[];
    return goals.where((goal) => goal.id == id).firstOrNull?.title ?? '目标已删除';
  }

  /// 周视图里点到一段预约：按编号补读事项，再打开它的操作面板。
  Future<void> _openBlock(ScheduledItem entry) async {
    final item = await _itemById(entry.block.planItemId);
    if (!mounted) return;
    if (item == null) {
      showToast(context, entry.itemTitle);
      return;
    }
    await _actions().openItem(item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final week = _week;
    final actions = _actions();
    return TabScaffold(
      header: ZhixinHeader(
        nested: false,
        title: const Text(tabPlan),
        actions: [
          // 查找入口常驻标题栏：周数据还没读完时也能进入；查找页自己读数据，
          // 不参与这一页的周订阅与页签结构。
          ZhixinHeaderAction(
            icon: FLucideIcons.search,
            tooltip: '查找安排',
            onPressed: () => openPlanSearch(context),
          ),
          if (week != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: forui.FButton(
                variant: forui.FButtonVariant.secondary,
                size: forui.FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: () => actions.capacity(),
                prefix: const Icon(FLucideIcons.calculator),
                child: const Text('这周能做什么'),
              ),
            ),
            moreMenu(
              label: '更多安排操作',
              icon: FLucideIcons.ellipsisVertical,
              items: [
                // 新建事项与查找图标同占标题栏右侧的宽度：窄屏放大文字时
                // 两者并排会溢出，新建入口因此收进更多菜单，事项页签里另有
                // 一个“新建”按钮。
                ZhixinMenuItem(
                  label: '新建事项',
                  subtitle: '名称、说明与可选截止日期',
                  onSelected: () => actions.addItem(),
                ),
                ZhixinMenuItem(
                  label: '预约时间',
                  subtitle: '为一项未完成的事项选一段时间',
                  onSelected: () => actions.schedule(),
                ),
                ZhixinMenuItem(
                  label: '整组顺延',
                  subtitle: '本周$buddyName排的弹性预约一起向后移',
                  onSelected: () => actions.shiftWeek(),
                ),
                ZhixinMenuItem(
                  label: '新建目标',
                  onSelected: () => actions.addGoal(),
                ),
                ZhixinMenuItem(
                  label: '添加课表',
                  onSelected: () => actions.addTimetable(),
                ),
              ],
            ),
          ],
        ],
      ),
      child: _weekStream == null
          ? const SizedBox.shrink()
          // 首读中的骨架、读取失败与已经读到的内容都交给一条订阅决定：
          // 数据到达就重建，写入之后的重读由数据层与 [LiveView] 完成。
          : LiveView<WeekSnapshot>(
              stream: _weekStream,
              onData: _onWeek,
              onError: _onWeekError,
              builder: (context, snapshot, loading) {
                final week = _week;
                if (week != null) return _loadedWeek(theme, week, actions);
                // 还没有内容：首读中先摆出页签与骨架，失败时留下说明与重试。
                if (_error != null) return _errorNotice(theme);
                if (loading) return _loadingWeek(theme);
                return _errorNotice(theme);
              },
            ),
    );
  }

  /// 首读中的页面：页签先就位，读完只在下面换内容，页面不往下跳。
  Widget _loadingWeek(ZhixinTheme theme) => PageWidth(
    child: Column(
      children: [
        _tabBar(theme),
        Expanded(
          child: ListSkeleton(
            rows: 3,
            padding: EdgeInsets.fromLTRB(0, theme.space.sm, 0, 0),
          ),
        ),
      ],
    ),
  );

  /// 首读失败时的一个出口：说明与重试留在同一处。
  Widget _errorNotice(ZhixinTheme theme) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: theme.space.page,
      vertical: theme.space.xl,
    ),
    child: Center(
      child: InlineNotice(
        message: _error ?? '安排读取失败，请刷新本机数据后重试。',
        onRetry: _reload,
      ),
    ),
  );

  /// 读到内容之后整页淡入；之后换周按前后次序左右滑过去，换页签同样滑列表。
  Widget _loadedWeek(ZhixinTheme theme, PlanWeek week, PlanActions actions) =>
      FadeIn(
        child: PageWidth(
          child: Column(
            children: [
              _tabBar(theme),
              // 已经显示的一周保留时，读取失败在页签下方说明一次并就地重试。
              if (_error != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    theme.space.page,
                    0,
                    theme.space.page,
                    theme.space.sm,
                  ),
                  child: InlineNotice(message: _error!, onRetry: _reload),
                ),
              Expanded(
                // 换周换的是同一块位置上的内容：旧的一周滑出去，新的一周进来。
                child: SlideSwap(
                  identity: _shownAnchor!,
                  order: _weekOrder(_shownAnchor!),
                  child: TabSlideStack(
                    index: _tab,
                    // 四个页签常驻，切换只换显示：切回来不再重建，滚动位置与
                    // 已读到的内容都留住；首次进入某个页签时才建。
                    children: [
                      for (var tab = 0; tab < 4; tab++)
                        KeyedSubtree(
                          key: ValueKey('plan-tab-layer-$tab'),
                          child: _visited.contains(tab)
                              ? _tabContent(week, actions, tab)
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// 周在时间上的序号，只用来判断换周的方向：往后一周变大。
  static int _weekOrder(DateTime weekStart) =>
      weekStart.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// 页签固定在列表上方：原来它随列表滚走，看到日程中段时想切到事项要先滚回顶部。
  Widget _tabBar(ZhixinTheme theme) => Padding(
    padding: EdgeInsets.fromLTRB(
      theme.space.page,
      theme.space.xs,
      theme.space.page,
      theme.space.sm,
    ),
    child: ZhixinSegmented<int>(
      segments: const [
        ZhixinSegment(value: 0, label: planTabSchedule),
        ZhixinSegment(value: 1, label: planTabItems),
        ZhixinSegment(value: 2, label: planTabGoals),
        ZhixinSegment(value: 3, label: aiChanges),
      ],
      selected: _tab,
      onChanged: (tab) => setState(() {
        _tab = tab;
        _visited.add(tab);
      }),
    ),
  );

  /// 每个页签自己的滚动位置由各自的 [CustomScrollView] 与 PageStorageKey 保住。
  Widget _tabContent(PlanWeek week, PlanActions actions, int tab) {
    final weekStart = _shownAnchor!;
    return switch (tab) {
      0 => PlanScheduleTab(
        week: week,
        weekStart: weekStart,
        actions: actions,
        onSelectWeek: _selectWeek,
        onStepWeek: _stepWeek,
        onOpenMaterials: widget.onOpenMaterials,
        onOpenBlock: _openBlock,
        showAllPlans: _showAllPlans,
        showWeekGrid: _showWeekGrid,
        onToggleAllPlans: () => setState(() => _showAllPlans = !_showAllPlans),
        onToggleWeekGrid: () => setState(() => _showWeekGrid = !_showWeekGrid),
      ),
      1 => PlanItemsTab(
        week: week,
        weekStart: weekStart,
        actions: actions,
        visible: _active && _tab == 1,
      ),
      2 => PlanGoalsTab(week: week, actions: actions),
      _ => PlanOperationsTab(week: week, actions: actions),
    };
  }
}
