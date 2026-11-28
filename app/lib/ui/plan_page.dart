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
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_segmented.dart';
import 'zhixin_toast.dart';

/// 安排页的学习事项与目标。
class PlanPage extends StatefulWidget {
  const PlanPage({
    super.key,
    this.activeTab,
    this.tabIndex = 2,
    this.request,
    this.watchOverview,
    this.itemById,
    this.preload,
  }) : initialItemId = null;

  /// 事项详情入口：推入一条事项并展开它的操作面板，不参与底栏切栏。
  const PlanPage.detail({
    super.key,
    required String itemId,
    this.watchOverview,
    this.itemById,
  }) : initialItemId = itemId,
       activeTab = null,
       tabIndex = 2,
       request = null,
       preload = null;

  /// 详情页要展开的事项；为空时按底栏页处理。
  final String? initialItemId;

  /// 底栏当前栏的下标；为空时按常驻当前页处理，二级入口直接打开安排。
  final ValueListenable<int>? activeTab;
  final int tabIndex;

  /// 底栏放行预读时为真：首页读完之后在后台先订阅事项与目标，第一次切过来直接
  /// 是内容，不再在切栏动画里看一段骨架。
  final ValueListenable<bool>? preload;

  /// 从别的栏目跳到安排时带的请求；每次变化都把页签复位到事项。
  final ValueListenable<int>? request;

  final Stream<PlanOverview> Function()? watchOverview;

  /// 按编号补读一条事项；为空时走应用根里的安排服务，测试可以换一份。
  final Future<PlanItem?> Function(String id)? itemById;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  Stream<PlanOverview>? _stream;
  String? _error;

  /// 搜索入口只做跳转，输入框自己的文字始终为空。
  final TextEditingController _searchHint = TextEditingController();

  /// 详情入口补读事项失败时的说明；为空表示没有失败。
  String? _openFailure;
  bool _openedInitial = false;
  int _tab = 0;

  bool get _active =>
      widget.activeTab == null || widget.activeTab!.value == widget.tabIndex;

  bool get _shouldRead => _active || (widget.preload?.value ?? false);

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
    if (_shouldRead) _stream ??= _watchOverview();
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
    if (_shouldRead) _stream ??= _watchOverview();
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onActiveChanged);
    widget.preload?.removeListener(_onActiveChanged);
    widget.request?.removeListener(_onRequestChanged);
    _searchHint.dispose();
    super.dispose();
  }

  Stream<PlanOverview> _watchOverview() =>
      (widget.watchOverview ?? AppScope.of(context).study.plan.watchOverview)();

  void _reload() => setState(() {
    _stream = _watchOverview();
    _error = null;
  });

  /// 一屏结果到达：清掉失败说明，再处理详情入口。界面由 `LiveView` 的 builder
  /// 用传入的 `data` 重建，这里不再另外 setState，一次结果只重建一次。
  void _onOverview(PlanOverview overview) {
    _error = null;
    unawaited(_openInitial(overview));
  }

  void _onReadError(Object error, StackTrace stack) {
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取安排',
      kind: 'plan_read',
      next: '可以在页面内重试',
    );
    setState(() => _error = message);
  }

  /// 详情入口：先在这一份数据里找，找不到再补读一条。
  ///
  /// 查不到与读失败分开处理：查不到（例如已完成列表里的旧编号）保持现状、不打开
  /// 任何页面；读失败时记下说明，在详情页里就地显示，不再静默。
  Future<void> _openInitial(PlanOverview overview) async {
    final itemId = widget.initialItemId;
    if (itemId == null || _openedInitial) return;
    _openedInitial = true;
    final PlanItem? item;
    try {
      item = await _itemById(overview, itemId);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取事项详情',
        kind: 'plan_item_detail_read',
        kept: '安排与学习记录没有改动',
        next: '可以再试一次',
      );
      setState(() => _openFailure = message);
      return;
    }
    if (!mounted || item == null) return;
    await _actions(overview).openItem(item);
  }

  /// 补读失败之后重试：重新走一遍详情入口，已经读到的说明先收起。
  void _retryOpenInitial(PlanOverview overview) {
    setState(() {
      _openedInitial = false;
      _openFailure = null;
    });
    unawaited(_openInitial(overview));
  }

  void _onActiveChanged() {
    if (!mounted || !_shouldRead) return;
    setState(() => _stream ??= _watchOverview());
  }

  void _onRequestChanged() {
    setState(() => _tab = 0);
    _onActiveChanged();
  }

  /// 已完成列表里可能读到的事项目前不在这一份数据里：先查已读到的，再补读。
  ///
  /// 补读的失败向上抛给 [openInitial]，由它转成说明；这里不把失败吞成“查不到”。
  Future<PlanItem?> _itemById(PlanOverview overview, String id) async {
    for (final item in overview.items) {
      if (item.id == id) return item;
    }
    return (widget.itemById ?? AppScope.of(context).study.plan.itemById)(id);
  }

  /// 页面的写入动作；每次重建换一份，页签按需调用。
  PlanActions _actions(PlanOverview? week) => PlanActions(
    context: context,
    week: week,
    onReportFailure: _reportFailure,
    goalName: (goalId) => _goalName(week, goalId),
    openStudy: openPlanItem,
    openDiscussion: openDiscussion,
    openStudyPlan: openStudyPlan,
  );

  String _goalName(PlanOverview? week, String? id) {
    if (id == null) return '无归属';
    final goals = week?.goals ?? const <LearningGoal>[];
    return goals.where((goal) => goal.id == id).firstOrNull?.title ?? '目标已删除';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return TabScaffold(
      header: ZhixinHeader(
        nested: widget.initialItemId != null,
        showBack: widget.initialItemId != null,
        title: const Text(tabPlan),
      ),
      child: TabbedPageFrame(
        // 搜索入口与记录页放在同一处：点开安排查找页，不再在标题栏放一个图标。
        // 详情入口从一条具体的事项推进来，不摆共用的搜索入口。
        searchField: widget.initialItemId == null ? _searchEntry() : null,
        tabBar: _tabBar(),
        child: _stream == null
            ? _loadingOverview(theme)
            : LiveView<PlanOverview>(
                stream: _stream,
                onData: _onOverview,
                onError: _onReadError,
                builder: (context, overview, loading) {
                  // 只用订阅传进来的这一份数据，不再读页面上的影子字段。
                  if (overview != null) {
                    return _loadedOverview(theme, overview);
                  }
                  if (_error == null && loading) return _loadingOverview(theme);
                  return _errorNotice(theme);
                },
              ),
      ),
    );
  }

  /// 搜索入口：只读的一条，点开安排查找页，输入与筛选都在那一页完成。
  Widget _searchEntry() => forui.FTextField(
    key: const ValueKey('plan-search-entry'),
    control: .managed(controller: _searchHint),
    readOnly: true,
    onTap: () => openPlanSearch(context),
    prefixBuilder: (context, style, variants) =>
        forui.FTextField.prefixIconBuilder(
          context,
          style,
          variants,
          const Icon(FLucideIcons.search, size: 16),
        ),
    hint: '搜索事项、目标与计划',
  );

  /// 首读中的页面：页签先就位，读完只在下面换内容，页面不往下跳。骨架的左右
  /// 边距与读完之后一样。
  Widget _loadingOverview(ZhixinTheme theme) => SingleChildScrollView(
    child: ListSkeleton(
      rows: 3,
      padding: theme.space.pageInsets(top: theme.space.xs),
    ),
  );

  /// 首读失败时的一个出口：说明与重试留在同一处。
  Widget _errorNotice(ZhixinTheme theme) => ListView(
    padding: theme.space.pageInsets(top: theme.space.sm),
    children: [
      InlineNotice(message: _error ?? '安排读取失败，请刷新本机数据后重试。', onRetry: _reload),
    ],
  );

  Widget _loadedOverview(ZhixinTheme theme, PlanOverview overview) {
    final actions = _actions(overview);
    return FadeIn(
      child: Column(
        children: [
          if (_openFailure case final message?)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                theme.space.xs,
                theme.space.page,
                0,
              ),
              child: InlineNotice(
                message: message,
                onRetry: () => _retryOpenInitial(overview),
              ),
            ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                theme.space.xs,
                theme.space.page,
                0,
              ),
              child: InlineNotice(message: _error!, onRetry: _reload),
            ),
          Expanded(
            child: TabSlideStack(
              index: _tab,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: theme.space.page),
                  key: const ValueKey('plan-tab-layer-0'),
                  child: PlanItemsTab(
                    week: overview,
                    actions: actions,
                    visible: _active && _tab == 0,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: theme.space.page),
                  key: const ValueKey('plan-tab-layer-1'),
                  child: PlanGoalsTab(week: overview, actions: actions),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBar() => ZhixinSegmented<int>(
    segments: const [
      ZhixinSegment(
        value: 0,
        label: planTabItems,
        icon: FLucideIcons.listChecks,
      ),
      ZhixinSegment(value: 1, label: planTabGoals, icon: FLucideIcons.flag),
    ],
    selected: _tab,
    onChanged: (tab) => setState(() => _tab = tab),
  );
}
