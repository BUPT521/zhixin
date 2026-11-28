import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/paged_result.dart';
import '../application/plan_search.dart';
import '../application/prefetch_service.dart';
import '../domain/models/study.dart';
import '../domain/rules/time_policy.dart' show naturalDay;
import 'date_time_dialogs.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'navigation.dart';
import 'search_state.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_toast.dart';

/// 安排里的查找：按标题、目标、状态与截止日期查找事项与计划步骤。
///
/// 关键词匹配事项标题与说明；目标按编号、状态按 [PlanItemStatus] 筛；日期用
/// 日期按事项的截止日期筛选。
/// 结果按时间从晚到早排，分页继续加载，超过四十条时也能翻到最早一条；查询
/// 全部在本机完成，断网或没有配置模型时同样可用。第一页、翻页与请求序号由共用的
/// [SearchState] 负责，查询与筛选条件留在页面上，换条件时发起一次新的查找。
class PlanSearchPage extends StatefulWidget {
  const PlanSearchPage({super.key, this.search});

  /// 查找读法；为空时走应用根里的安排服务，测试可以换一份。
  final PlanSearchRunner? search;

  @override
  State<PlanSearchPage> createState() => _PlanSearchPageState();
}

class _PlanSearchPageState extends State<PlanSearchPage> {
  final TextEditingController _keyword = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 查找的共用状态：请求序号、结果、翻页与空态都由它保存。
  late final SearchState<PlanSearchHit> _searchState =
      SearchState<PlanSearchHit>(
        pageSize: kSearchPageSize,
        key: (hit) => hit.id,
      );

  /// 最近一次失败时的说明；第一页失败显示在结果区，翻页失败留在列表上方。
  String? _notice;

  /// 失败时的调用栈，交给 `describeFailure` 写进本机诊断记录。
  StackTrace? _failureStack;

  /// 屏幕上这一份结果对应的条件；空态里写的就是它。
  PlanSearchQuery _applied = const PlanSearchQuery();

  /// 目标筛选的编号；空串表示全部目标。
  String _goalId = '';
  PlanItemStatus? _status;
  DateTime? _day;

  List<LearningGoal> _goals = const [];
  bool _optionsRequested = false;

  @override
  void initState() {
    super.initState();
    _searchState.addListener(_onSearchStateChanged);
  }

  /// 共用状态每次变化（开始读、读完、翻页、失败）都重画一次。
  void _onSearchStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 目标选项要读应用根上的仓库，放在 initState 里会依赖尚未就绪的上下文。
    if (_optionsRequested) return;
    _optionsRequested = true;
    _loadGoals();
  }

  @override
  void dispose() {
    _searchState.dispose();
    _keyword.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadGoals() async {
    try {
      final scope = AppScope.of(context);
      // 进入“安排”时已经在后台读过目标选项，直接用这一份。
      final goals =
          scope.prefetch.peek<List<LearningGoal>>(
            PrefetchKey.planSearchGoals,
          ) ??
          await scope.study.plan.goals();
      if (!mounted) return;
      setState(() => _goals = goals);
    } catch (_) {
      // 目标选项读取失败时仍可查找全部目标，不阻塞本次查找。
    }
  }

  PlanSearchQuery get _currentQuery => PlanSearchQuery(
    keyword: _keyword.text,
    goalId: _goalId.isEmpty ? null : _goalId,
    status: _status,
    day: _day,
  );

  /// 一次查找：换一个请求序号，晚到的旧结果由共用状态丢弃。
  Future<void> _search() async {
    final query = _currentQuery;
    _notice = null;
    if (query.isEmpty) {
      _applied = query;
      _searchState.clear();
      return;
    }
    await _searchState.refresh(
      active: true,
      fetch: (offset) => _fetchPage(query, offset),
    );
    if (!mounted) return;
    // 成功时记下这一份结果对应的条件，空态与“已经到最后一条”都按它说明。
    if (_searchState.phase == SearchPhase.ready) _applied = query;
    _reportFailure(
      '查找安排',
      kind: 'plan_search_read',
      kept: '已经保存的安排没有改动',
      next: '可以再查一次',
    );
  }

  /// 取一页结果：服务直接返回共用的分页结果。
  ///
  /// 失败时记下调用栈再抛出，页面上的说明由 [describeFailure] 生成。
  Future<PagedResult<PlanSearchHit>> _fetchPage(
    PlanSearchQuery query,
    int offset,
  ) async {
    try {
      return await _runSearch(query, offset: offset);
    } catch (error, stack) {
      _failureStack = stack;
      rethrow;
    }
  }

  /// 第一页或翻页失败时把原始错误转成一句说明。
  void _reportFailure(
    String action, {
    required String kind,
    required String kept,
    required String next,
  }) {
    if (!mounted) return;
    final error = _searchState.error;
    if (error == null) return;
    setState(
      () => _notice = describeFailure(
        context,
        error,
        _failureStack ?? StackTrace.current,
        action: action,
        kind: kind,
        kept: kept,
        next: next,
      ),
    );
  }

  /// 接着向后取一页；已经显示的结果在失败时保持不变。
  Future<void> _loadMore() async {
    await _searchState.loadMore();
    if (!mounted || !_searchState.loadMoreFailed) return;
    _reportFailure(
      '继续读取查找结果',
      kind: 'plan_search_page',
      kept: '已经显示的结果没有改动',
      next: '可以再点一次“加载更多结果”',
    );
  }

  Future<PagedResult<PlanSearchHit>> _runSearch(
    PlanSearchQuery query, {
    required int offset,
  }) {
    final injected = widget.search;
    if (injected != null) return injected(query, offset: offset);
    return AppScope.of(context).study.plan
        .searchPage(query, offset: offset, pageSize: _searchState.pageSize);
  }

  /// 筛选一改就重查；全部条件清空时回到入口提示。
  void _onFilterChanged() {
    unawaited(_search());
  }

  /// 清除全部条件，回到入口提示；没有命中时也给这个出口。
  void _clearFilters() {
    _keyword.clear();
    setState(() {
      _goalId = '';
      _status = null;
      _day = null;
    });
    unawaited(_search());
  }

  /// 点开一条结果：学习步骤按继续位置规则打开，其余事项打开事项详情。
  ///
  Future<void> _openHit(PlanSearchHit hit) async {
    try {
      final item = hit.item;
      if (item.isStudyStep) {
        await openPlanItem(context, item);
      } else {
        await openPlanDetail(context, item.id);
      }
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '打开查找结果',
        kind: 'plan_search_open',
        kept: '事项与学习记录没有改动',
        next: '可以再点一次',
      );
      showToast(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final state = _searchState;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('查找安排'), showBack: true),
      child: Column(
        children: [
          Padding(
            padding: theme.space.pageInsets(
              top: theme.space.sm,
              bottom: theme.space.xs,
            ),
            child: forui.FTextField(
              control: .managed(controller: _keyword),
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              onSubmit: (_) => _search(),
              hint: '搜索事项标题或说明',
              suffixBuilder: (_, style, _) => ZhixinIconButton(
                tooltip: '查找',
                onPressed: _search,
                icon: FLucideIcons.search,
                style: style.clearButtonStyle,
              ),
            ),
          ),
          _filterBar(theme),
          if (state.isLoading) const forui.FProgress(),
          // 翻页失败时结果仍在屏幕上，说明放在列表上方；第一页失败的说明进
          // 结果区。
          if (_notice != null && !state.isFailed)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                0,
                theme.space.page,
                0,
              ),
              child: InlineNotice(message: _notice!),
            ),
          Expanded(child: _resultsArea(theme)),
        ],
      ),
    );
  }

  /// 目标、状态与日期三个筛选；下面一句写明日期用同一个条件。
  Widget _filterBar(ZhixinTheme theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.page,
        theme.space.xs,
        theme.space.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: theme.space.xs,
            runSpacing: theme.space.xs,
            children: [_goalMenu(), _statusMenu(), _dateMenu()],
          ),
          Padding(
            padding: EdgeInsets.only(top: theme.space.xs),
            child: Text('日期按事项的截止日期筛选。', style: theme.text.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _filterButton(String label, IconData icon, VoidCallback onPressed) {
    return forui.FButton(
      variant: forui.FButtonVariant.outline,
      size: forui.FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.min,
      onPress: onPressed,
      prefix: Icon(icon),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// 目标筛选：全部目标与每个目标各一项，按目标编号筛选事项。
  Widget _goalMenu() {
    final label = _goalId.isEmpty ? '目标：全部' : '目标：${_goalLabel(_goalId)}';
    return forui.FPopoverMenu.tiles(
      semanticsLabel: '按目标筛选',
      barrierSemanticsLabel: '关闭目标筛选',
      menuAnchor: AlignmentDirectional.topStart,
      childAnchor: AlignmentDirectional.bottomStart,
      builder: (context, controller, _) =>
          _filterButton(label, FLucideIcons.flag, controller.toggle),
      menuBuilder: (context, controller, _) {
        forui.FTile option(String text, String goalId) => forui.FTile(
          title: Text(text),
          selected: _goalId == goalId,
          suffix: _goalId == goalId
              ? Icon(FLucideIcons.check, color: context.zhixin.colors.primary)
              : null,
          onPress: () {
            controller.hide();
            if (_goalId == goalId) return;
            setState(() => _goalId = goalId);
            _onFilterChanged();
          },
        );
        return [
          forui.FTileGroup(
            children: [
              forui.FTile(
                title: const Text('按目标筛选'),
                subtitle: const Text('适用于学习事项与计划步骤。'),
                enabled: false,
              ),
            ],
          ),
          forui.FTileGroup(
            children: [
              option('全部目标', ''),
              for (final goal in _goals) option('目标：${goal.title}', goal.id),
            ],
          ),
        ];
      },
    );
  }

  /// 状态筛选：全部状态与四个实际状态，没有状态的事项不会出现。
  Widget _statusMenu() {
    final label = _status == null ? '状态：全部' : '状态：${_status!.label}';
    const options = [
      PlanItemStatus.todo,
      PlanItemStatus.doing,
      PlanItemStatus.done,
      PlanItemStatus.deferred,
    ];
    return forui.FPopoverMenu.tiles(
      semanticsLabel: '按状态筛选',
      barrierSemanticsLabel: '关闭状态筛选',
      menuAnchor: AlignmentDirectional.topStart,
      childAnchor: AlignmentDirectional.bottomStart,
      builder: (context, controller, _) =>
          _filterButton(label, FLucideIcons.listChecks, controller.toggle),
      menuBuilder: (context, controller, _) {
        forui.FTile option(String text, PlanItemStatus? status) => forui.FTile(
          title: Text(text),
          selected: _status == status,
          suffix: _status == status
              ? Icon(FLucideIcons.check, color: context.zhixin.colors.primary)
              : null,
          onPress: () {
            controller.hide();
            if (_status == status) return;
            setState(() => _status = status);
            _onFilterChanged();
          },
        );
        return [
          forui.FTileGroup(
            children: [
              forui.FTile(
                title: const Text('按状态筛选'),
                subtitle: const Text('按事项当前状态筛选。'),
                enabled: false,
              ),
            ],
          ),
          forui.FTileGroup(
            children: [
              option('全部状态', null),
              for (final status in options) option(status.label, status),
            ],
          ),
        ];
      },
    );
  }

  /// 日期筛选：全部、今天、明天与自选一天，三者共用同一个自然日区间。
  Widget _dateMenu() {
    final label = _day == null ? '日期：全部' : '日期：${dateText(_day)}';
    final now = AppScope.of(context).timePolicy.now;
    return forui.FPopoverMenu.tiles(
      semanticsLabel: '按日期筛选',
      barrierSemanticsLabel: '关闭日期筛选',
      menuAnchor: AlignmentDirectional.topStart,
      childAnchor: AlignmentDirectional.bottomStart,
      builder: (context, controller, _) =>
          _filterButton(label, FLucideIcons.calendarDays, controller.toggle),
      menuBuilder: (context, controller, _) {
        forui.FTile option(String text, DateTime? day) => forui.FTile(
          title: Text(text),
          selected: _sameDay(_day, day),
          suffix: _sameDay(_day, day)
              ? Icon(FLucideIcons.check, color: context.zhixin.colors.primary)
              : null,
          onPress: () {
            controller.hide();
            setState(() => _day = day);
            _onFilterChanged();
          },
        );
        return [
          forui.FTileGroup(
            children: [
              forui.FTile(
                title: const Text('按日期筛选'),
                subtitle: const Text('只显示截止日期为所选日期的事项。'),
                enabled: false,
              ),
            ],
          ),
          forui.FTileGroup(
            children: [
              option('全部日期', null),
              option('今天', naturalDay(now)),
              option('明天', DateTime(now.year, now.month, now.day + 1)),
              forui.FTile(
                title: const Text('选择日期…'),
                onPress: () {
                  controller.hide();
                  unawaited(_pickDay());
                },
              ),
            ],
          ),
        ];
      },
    );
  }

  Future<void> _pickDay() async {
    final now = AppScope.of(context).timePolicy.now;
    final picked = await showZhixinDatePicker(
      context: context,
      initialDate: _day ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10, 12, 31),
    );
    if (!mounted || picked == null) return;
    setState(() => _day = picked);
    _onFilterChanged();
  }

  static bool _sameDay(DateTime? left, DateTime? right) {
    if (left == null || right == null) return left == right;
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }

  String _goalLabel(String goalId) =>
      _goals
          .where((goal) => goal.id == goalId)
          .map((goal) => goal.title)
          .firstOrNull ??
      '已删除的目标';

  /// 当前条件的说法；“没有命中”时保留它并给出清除入口。
  String get _filterSummary {
    final parts = <String>[
      if (_applied.keyword.trim().isNotEmpty) '关键词「${_applied.keyword.trim()}」',
      if (_applied.goalId != null) '目标：${_goalLabel(_applied.goalId!)}',
      if (_applied.status != null) '状态：${_applied.status!.label}',
      if (_applied.day != null) '日期：${dateText(_applied.day)}',
    ];
    return parts.isEmpty ? '' : parts.join('，');
  }

  Widget _resultsArea(ZhixinTheme theme) {
    final state = _searchState;
    // 第一页读取失败：说明占结果区。
    if (state.isFailed) {
      return SingleChildScrollView(
        padding: theme.space.pageInsets(top: theme.space.xs),
        child: InlineNotice(message: _notice ?? '查找没有完成，可以再查一次。'),
      );
    }
    if (state.page == null) {
      if (state.isLoading) {
        return ListSkeleton(
          rows: 3,
          padding: theme.space.pageInsets(top: theme.space.xs),
        );
      }
      return SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.search,
          title: '查找安排',
          description:
              '按标题、说明、目标、状态或截止日期，查学习事项与计划步骤。'
              '关键词与筛选都在本机完成，断网也能用。',
        ),
      );
    }
    if (state.items.isEmpty) {
      // 新的条件还在读时保留上一份结果，空态等这次读完再判断。
      if (state.isLoading) return const SizedBox.shrink();
      return SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.searchX,
          title: '没有找到符合条件的内容',
          description: _filterSummary.isEmpty
              ? '可以换几个关键词，或换一组筛选条件再试。'
              : '当前筛选：$_filterSummary。可以换关键词或清除筛选再试。',
          action: forui.FButton(
            variant: forui.FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: _clearFilters,
            child: const Text('清除筛选'),
          ),
        ),
      );
    }
    // 结果不足一页时不写“已经到最后一条”，免得刚查完就多一行结束语。
    final showEnd = !state.hasMore && state.items.length >= kSearchPageSize;
    return ListView(
      controller: _scroll,
      padding: theme.space.pageInsets(top: theme.space.xs),
      children: [
        for (final hit in state.items) _hitTile(theme, hit),
        if (state.hasMore)
          LoadMoreFooter(
            label: '加载更多结果',
            loading: state.loadingMore,
            onPressed: _loadMore,
          )
        else if (showEnd)
          Padding(
            padding: EdgeInsets.only(top: theme.space.md),
            child: Center(child: Text('已经到最后一条', style: theme.text.bodySmall)),
          ),
      ],
    );
  }

  /// 一条结果：类型、状态与时间先写清，再给标题与说明摘要。
  Widget _hitTile(ZhixinTheme theme, PlanSearchHit hit) {
    final isStep = hit.item.isStudyStep;
    final leading = isStep ? FLucideIcons.route : FLucideIcons.listChecks;
    final tags = <Widget>[
      StatusTag(isStep ? '计划步骤' : '学习事项', icon: leading),
      StatusTag(
        hit.status.label,
        tone: hit.status.open ? TagTone.accent : TagTone.muted,
      ),
    ];
    final at = hit.at;
    final time = at == null ? '无截止日期' : '截止 ${shortTime(at)}';
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: LeadingIcon(leading, tone: TagTone.muted),
        title: Text(hit.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TagRow(children: tags),
            SizedBox(height: theme.space.xs),
            Text(time, style: theme.text.bodySmall),
            if (hit.note != null)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(
                  hit.note!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        onPress: () => _openHit(hit),
      ),
    );
  }
}
