import 'package:calendar_view/calendar_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    as flutter_material
    show Material, MaterialType;

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import 'plan_dialogs.dart';
import '../application/plan_service.dart';
import '../data/repository/schedule_repository.dart';
import '../data/revisions/revision_models.dart';
import '../domain/models/study.dart';
import 'capacity_sheet.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_dialog.dart';
import 'discussion_page.dart';
import 'study_entry.dart';
import 'study_plan_page.dart';
import 'workspace_widgets.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_menu.dart';
import 'zhixin_segmented.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 安排：每周日程、系统学习、学习事项与 AI 改动的撤销。
class PlanPage extends StatefulWidget {
  const PlanPage({
    super.key,
    this.activeTab,
    this.tabIndex = 2,
    this.request,
    this.initialItemId,
    this.onOpenMaterials,
  });

  final int? initialItemId;

  /// 底栏当前栏的下标；为空时按常驻当前页处理，二级入口直接打开安排。
  final ValueListenable<int>? activeTab;
  final int tabIndex;

  /// 从别的栏目跳到安排时带的请求；每次变化都把页签复位到日程。
  final ValueListenable<int>? request;
  final VoidCallback? onOpenMaterials;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  PlanWeek? _week;
  late DateTime _anchor;
  bool _loading = true;
  bool _started = false;
  bool _openedInitial = false;
  int _tab = 0;
  bool _showAllPlans = false;

  bool _showWeekGrid = false;
  final _weekGridKey = GlobalKey<WeekViewState<Object>>();
  int _weekRequest = 0;
  String? _error;

  /// 进过的页签常驻：切回来不再重建，滚动位置一并保住。
  final Set<int> _visited = {0};

  /// 数据版本在页面里监听：整库恢复之后自己重读，父级不再包一层。
  ValueListenable<int>? _dataVersion;

  /// 当前显示的是哪一周；读完换周之后才更新，列表据此淡入，
  /// 同一周的刷新与从详情返回不闪。
  DateTime? _shownAnchor;

  /// 已完成事项按页展开；默认不读，避免每次打开安排页都把历史读一遍。
  List<PlanItem> _doneItems = const [];
  bool _doneLoaded = false;
  bool _loadingDone = false;
  bool _hasMoreDone = false;
  bool _doneLoadFailed = false;
  bool _doneLoadScheduled = false;
  static const int _donePageSize = 30;

  bool get _active =>
      widget.activeTab == null || widget.activeTab!.value == widget.tabIndex;

  /// 本地写入失败时给一句可行动的说明；异常本身进本机诊断记录。
  void _reportFailure(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    String? kept,
    String next = '可以再试一次',
  }) {
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
    widget.request?.addListener(_onRequestChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchDataVersion(AppScope.of(context).dataVersion);
    if (_started) return;
    _started = true;
    final policy = AppScope.of(context).timePolicy;
    _anchor = policy.naturalWeekStart(policy.now);
    // 未显示的页面不提前读取，也不在后台保留转圈；切到安排时再加载。
    if (_active) _load();
  }

  @override
  void didUpdateWidget(covariant PlanPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      oldWidget.request?.removeListener(_onRequestChanged);
      widget.request?.addListener(_onRequestChanged);
    }
    if (oldWidget.activeTab != widget.activeTab) {
      oldWidget.activeTab?.removeListener(_onActiveChanged);
      widget.activeTab?.addListener(_onActiveChanged);
    }
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onActiveChanged);
    widget.request?.removeListener(_onRequestChanged);
    _dataVersion?.removeListener(_onDataChanged);
    super.dispose();
  }

  /// 切到这一栏时立刻发起读取；结果回来时等切栏动画结束再填。
  void _onActiveChanged() {
    if (!mounted || !_active) return;
    _load();
  }

  /// 从别的栏目跳到安排：页签复位到日程，常驻页签不重读。
  void _onRequestChanged() {
    if (!mounted) return;
    setState(() {
      _tab = 0;
      _visited.add(0);
    });
  }

  void _watchDataVersion(ValueListenable<int> version) {
    if (identical(version, _dataVersion)) return;
    _dataVersion?.removeListener(_onDataChanged);
    _dataVersion = version;
    version.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted || !_active) return;
    _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    final anchor = _anchor;
    final request = ++_weekRequest;
    try {
      final week = await scope.study.plan.loadWeek(anchor);
      if (!mounted || request != _weekRequest) return;
      // 结果回来时若还在切栏或返回动画里，等动画走完再填。
      await context.afterTransition();
      if (!mounted || request != _weekRequest) return;
      setState(() {
        _week = week;
        _shownAnchor = anchor;
        _loading = false;
        _error = null;
        _doneItems = const [];
        _doneLoaded = false;
        _loadingDone = false;
        _hasMoreDone = false;
        _doneLoadFailed = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _weekRequest) return;
        final grid = _weekGridKey.currentState;
        if (grid != null && grid.currentDate != anchor) grid.jumpToWeek(anchor);
      });
      if (!_openedInitial && widget.initialItemId != null) {
        final item =
            week.items
                .where((item) => item.id == widget.initialItemId)
                .firstOrNull ??
            await _itemById(widget.initialItemId!);
        if (mounted && request == _weekRequest && item != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || request != _weekRequest || _openedInitial) return;
            _openedInitial = true;
            _showItem(item);
          });
        }
      }
    } catch (error, stack) {
      if (!mounted || request != _weekRequest) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取安排',
        kind: 'plan_read',
        kept: '已经保存的安排没有改动',
        next: '可以点右上角刷新，或切换页面再回来',
      );
      setState(() {
        _loading = false;
        _error = message;
      });
      showToast(context, message);
    }
  }

  void _selectWeek(DateTime date) {
    final anchor = AppScope.of(context).timePolicy.naturalWeekStart(date);
    if (anchor == _anchor) return;
    _anchor = anchor;
    _load();
  }

  /// 已完成列表目前读回的事项；日程里点到的已完成事项可能还不在这一页里。
  PlanItem? _cachedItem(int id) {
    for (final item in _week?.items ?? const <PlanItem>[]) {
      if (item.id == id) return item;
    }
    for (final item in _doneItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<PlanItem?> _itemById(int id) async {
    final cached = _cachedItem(id);
    if (cached != null) return cached;
    try {
      return await AppScope.of(context).tasks.byId(id);
    } catch (_) {
      return null;
    }
  }

  /// 展开或继续读取已完成事项；一次读一页，顺序按最近完成时间。
  Future<void> _loadDone({bool reset = false}) async {
    final week = _week;
    if (week == null || _loadingDone || (!reset && !_hasMoreDone)) return;
    final offset = reset ? 0 : _doneItems.length;
    setState(() {
      _loadingDone = true;
      _doneLoadFailed = false;
    });
    try {
      final page = await AppScope.of(context).study.plan
          .doneItems(limit: _donePageSize, offset: offset);
      if (!mounted || !identical(_week, week)) return;
      setState(() {
        _doneItems = reset ? page : [..._doneItems, ...page];
        _doneLoaded = true;
        _hasMoreDone =
            page.length == _donePageSize &&
            _doneItems.length < week.doneItemCount;
        _loadingDone = false;
      });
    } catch (error, stack) {
      if (!mounted || !identical(_week, week)) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取已完成事项',
        kind: 'plan_done_read',
        kept: '已经读出的内容保持不变',
        next: reset ? '可以再次展开已完成事项' : '可以在列表底部重试',
      );
      setState(() {
        _loadingDone = false;
        _doneLoadFailed = !reset;
      });
      showToast(context, message);
    }
  }

  /// 事项页签滚到距底部一屏以内时续读，收起列表或刷新后丢弃已排队的请求。
  bool _onItemsScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (notification.depth != 0 ||
        (notification is! ScrollUpdateNotification &&
            notification is! OverscrollNotification) ||
        metrics.extentAfter > metrics.viewportDimension ||
        _doneLoadScheduled ||
        !_canLoadMoreDone) {
      return false;
    }
    final items = _doneItems;
    _doneLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _doneLoadScheduled = false;
      if (mounted && _canLoadMoreDone && identical(items, _doneItems)) {
        _loadDone();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    return false;
  }

  bool get _canLoadMoreDone =>
      _active &&
      _tab == 1 &&
      _doneLoaded &&
      _hasMoreDone &&
      !_loadingDone &&
      !_doneLoadFailed;

  Future<void> _addGoal() async {
    final draft = await showGoalDialog(context);
    if (draft == null || !mounted) return;
    try {
      await AppScope.of(context).study.plan.addGoal(
        title: draft.title,
        scopeText: draft.scope,
        dueDate: draft.dueDate,
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '保存目标',
        kind: 'plan_goal_save',
        kept: '目标没有创建',
      );
    }
  }

  Future<void> _pauseGoal(LearningGoal goal) async {
    final scope = AppScope.of(context);
    final service = scope.study.plan;
    final flexible = await service.flexibleFutureCount(goal.id);
    if (!mounted) return;
    var cancelFlexible = false;
    final confirmed = await showZhixinDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ZhixinDialogLayout(
          title: Text('暂停「${goal.title}」'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '暂停目标后，独立讨论、已完成记录和固定安排都会保留；'
                '其他目标的安排照常进行。',
              ),
              if (flexible > 0)
                forui.FCheckbox(
                  value: cancelFlexible,
                  onChange: (value) =>
                      setDialogState(() => cancelFlexible = value),
                  label: Text('同时取消该目标下 $flexible 项未开始的弹性安排'),
                  description: const Text('固定安排保持原时间；取消的时间块可在安排页查看。'),
                ),
            ],
          ),
          actions: [
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.of(context).pop(false),
              child: const Text('保留目标'),
            ),
            forui.FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.of(context).pop(true),
              child: const Text('暂停'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final commitId = await service.pauseGoal(
        goal.id,
        cancelFlexibleFuture: cancelFlexible,
      );
      await _load();
      if (!mounted || commitId == null) return;
      showActionToast(
        context,
        '已暂停「${goal.title}」'
        '${cancelFlexible ? '，并取消 $flexible 项弹性安排' : ''}',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '暂停目标',
        kind: 'plan_goal_pause',
        kept: '目标与预约保持原样',
      );
    }
  }

  Future<void> _resumeGoal(LearningGoal goal) async {
    try {
      await AppScope.of(context).study.plan.resumeGoal(goal.id);
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '恢复目标',
        kind: 'plan_goal_resume',
        kept: '目标状态没有改动',
      );
    }
  }

  Future<void> _addItem() async {
    final week = _week;
    final goals = week == null
        ? const <LearningGoal>[]
        : week.goals.where((goal) => goal.active).toList(growable: false);
    final draft = await showZhixinDialog<ItemDraft>(
      context: context,
      builder: (_) => ItemDialog(goals: goals),
    );
    if (draft == null || !mounted) return;
    try {
      await AppScope.of(context).study.plan.addItem(
        title: draft.title,
        goalId: draft.goalId,
        note: draft.note,
        dueAt: draft.dueAt,
        minutes: draft.minutes,
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '保存学习事项',
        kind: 'plan_item_save',
        kept: '事项没有创建',
      );
    }
  }

  Future<void> _schedule({PlanItem? item}) async {
    final week = _week;
    if (week == null) return;
    final items = item == null
        ? week.items.where((item) => item.open).toList()
        : [item];
    if (items.isEmpty) {
      showToast(context, '先创建学习事项，再预约时间。');
      return;
    }
    final draft = await showZhixinDialog<BlockDraft>(
      context: context,
      builder: (_) => BlockDialog(items: items),
    );
    if (draft == null || !mounted) return;
    try {
      final commitId = await AppScope.of(context).study.plan.scheduleItem(
        planItemId: draft.itemId,
        start: draft.start,
        end: draft.start.add(Duration(minutes: draft.minutes)),
      );
      await _load();
      if (!mounted) return;
      final title = items
          .where((item) => item.id == draft.itemId)
          .firstOrNull
          ?.title;
      showActionToast(
        context,
        title == null ? '已预约学习时间' : '已预约「$title」',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '安排学习时间',
        kind: 'plan_schedule',
        kept: '这次没有写入',
        next: '可以换一个时间再试',
      );
    }
  }

  /// 把本周尚未开始、由搭子排的弹性预约整组顺延。
  ///
  /// 固定的、用户自己排的与已经开始或结束的预约保持原样；选完分钟数后先列出
  /// 每条预约从什么时间改到什么时间，确认之后才写入。任一条与课表或其他预约
  /// 冲突时，整组保持原样。
  Future<void> _shiftWeek() async {
    final week = _week;
    if (week == null) return;
    final now = AppScope.of(context).timePolicy.now;
    final movable = week.blocks
        .where((entry) {
          final block = entry.block;
          return block.planned &&
              !block.locked &&
              block.source == 'ai' &&
              block.startAt.isAfter(now);
        })
        .toList(growable: false);
    if (movable.isEmpty) {
      showToast(context, '本周没有可顺延的搭子预约；固定的、自己排的与已经开始的预约保持原时间。');
      return;
    }
    final minutes = await showZhixinAlert<int>(
      context: context,
      title: '整组顺延',
      content: Text(
        '把本周 ${movable.length} 条尚未开始、由搭子排的预约一起向后移动。'
        '固定的、自己排的与已经开始的预约保持原时间。',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        for (final value in const [30, 60, 120])
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop(value),
            child: Text('$value 分钟'),
          ),
      ],
    );
    if (minutes == null || !mounted) return;
    final adjustments = [
      for (final entry in movable)
        ScheduleAdjustment(
          id: entry.block.id,
          start: entry.block.startAt.add(Duration(minutes: minutes)),
          end: entry.block.endAt.add(Duration(minutes: minutes)),
        ),
    ];
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '整组顺延预览',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('下面 ${movable.length} 条预约会向后移动 $minutes 分钟，确认后才写入：'),
          const SizedBox(height: 8),
          for (final entry in movable)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '「${entry.itemTitle}」'
                '${_blockRange(entry.block.startAt, entry.block.endAt)} → '
                '${_blockRange(entry.block.startAt.add(Duration(minutes: minutes)), entry.block.endAt.add(Duration(minutes: minutes)))}',
              ),
            ),
          const SizedBox(height: 8),
          Text('任一条与课表或其他预约冲突时，整组保持原样。', style: context.zhixin.text.bodySmall),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('确认顺延'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    final scope = AppScope.of(context);
    try {
      final commitId = await scope.study.plan.rescheduleGroup(adjustments);
      await _load();
      if (!mounted) return;
      showActionToast(
        context,
        '已整组顺延 $minutes 分钟，共 ${movable.length} 条预约',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '整组顺延预约',
        kind: 'plan_shift_week',
        kept: '整组预约保持原样',
      );
    }
  }

  String _blockRange(DateTime start, DateTime end) {
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final endText = sameDay ? clockOf(end) : '${dayLabel(end)} ${clockOf(end)}';
    return '${shortTime(start)}–$endText';
  }

  Future<void> _addTimetable() async {
    final draft = await showZhixinDialog<TimetableDraft>(
      context: context,
      builder: (_) => const TimetableDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      await AppScope.of(context).study.plan.addTimetable(
        weekday: draft.weekday,
        startTime: draft.start,
        endTime: draft.end,
        title: draft.title,
        location: draft.location,
      );
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '保存课表',
        kind: 'plan_timetable_save',
        kept: '课表没有写入',
      );
    }
  }

  /// 删除一节课之前先说明影响；删除后从提示条撤销，撤销会重新核对预约冲突。
  Future<void> _deleteTimetable(TimetableEntry entry) async {
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '删除这节课',
      content: Text(
        '删除「${entry.title}」后，'
        '${weekdayLabel(entry.weekday)} ${entry.startTime}–${entry.endTime} '
        '不再参与学习安排的冲突检查。确定删除？',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          variant: forui.FButtonVariant.destructive,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    try {
      final commitId = await AppScope.of(context).study.plan
          .deleteTimetable(entry.id);
      await _load();
      if (!mounted) return;
      showActionToast(
        context,
        '已删除课表「${entry.title}」',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '删除课表',
        kind: 'plan_timetable_delete',
        kept: '这节课还在课表里',
      );
    }
  }

  Future<void> _undo(RevisionCommit commit) =>
      undoCommitWithFeedback(context, commit.id, reload: _load);

  Future<void> _setStatus(PlanItem item, PlanItemStatus status) async {
    try {
      await AppScope.of(context).study.plan.setStatus(item.id, status);
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '修改事项状态',
        kind: 'plan_item_status',
        kept: '事项状态没有改动',
      );
    }
  }

  Future<void> _capacity() async {
    await showCapacitySheet(context);
    if (mounted) await _load();
  }

  ScheduleBlock? _blockForItem(PlanItem item) {
    final blocks = _week?.blocks ?? const <ScheduledItem>[];
    return blocks
        .where(
          (entry) => entry.block.planItemId == item.id && entry.block.planned,
        )
        .map((entry) => entry.block)
        .firstOrNull;
  }

  Future<void> _showItem(PlanItem item) async {
    final block = _blockForItem(item);
    final canOpen = item.isStudyStep || item.conversationId != null;
    final action = await showZhixinSheet<String>(
      context: context,
      builder: (context) {
        final theme = context.zhixin;
        Widget fact(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: theme.colors.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: theme.text.bodyMedium)),
            ],
          ),
        );
        // 动作分三层：打开学习内容是主按钮，单独一行；跳转到来源与计划、
        // 预约与改期是次一级；改状态的动作放在最后，用文字按钮。
        final navigation = <Widget>[
          if (item.conversationId != null)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'source'),
              prefix: const Icon(FLucideIcons.messageCircle),
              child: const Text('返回来源讨论'),
            ),
          if (item.studyPlanId != null)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'plan'),
              prefix: const Icon(FLucideIcons.route),
              child: const Text('打开学习计划'),
            ),
          if (item.open)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'schedule'),
              prefix: const Icon(FLucideIcons.calendar),
              child: Text(block == null ? '预约时间' : '改期'),
            ),
        ];
        final status = <Widget>[
          if (item.status == PlanItemStatus.todo)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'start'),
              child: const Text('标记进行中'),
            ),
          if (item.open)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'complete'),
              prefix: const Icon(FLucideIcons.check),
              child: Text(item.isStudyStep ? '完成这一步' : '完成事项'),
            ),
          if (block != null)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(context, 'end'),
              child: const Text('结束本次预约'),
            ),
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TagRow(
                children: [
                  StatusTag(_goalName(item.goalId), icon: FLucideIcons.flag),
                  StatusTag(
                    item.status.label,
                    tone: item.open ? TagTone.accent : TagTone.muted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(item.title, style: theme.text.headlineSmall),
              if (item.isStudyStep)
                fact(
                  FLucideIcons.route,
                  '系统学习第 ${item.seq ?? 1} 步'
                  '${item.pageLabel.isEmpty ? '' : '，${item.pageLabel}'}',
                ),
              if (block != null)
                fact(
                  FLucideIcons.calendar,
                  '预约：${shortTime(block.startAt)}'
                  '–${clockOf(block.endAt)}',
                ),
              if (item.estMinutes != null)
                fact(FLucideIcons.timer, '预计 ${item.estMinutes} 分钟'),
              if (!item.open)
                fact(
                  FLucideIcons.circleCheck,
                  '状态：${item.status.label}'
                  '${item.completedAt == null ? '' : '，完成于 ${shortTime(item.completedAt!)}'}',
                ),
              if (item.note != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colors.surfaceContainerHigh,
                    borderRadius: theme.radius.card,
                  ),
                  child: Text(item.note!, style: theme.text.bodyMedium),
                ),
              ],
              const SizedBox(height: 20),
              if (canOpen && !item.done) ...[
                forui.FButton(
                  onPress: () => Navigator.pop(context, 'study'),
                  prefix: const Icon(FLucideIcons.play),
                  child: Text(item.isStudyStep ? '学这一步' : '回到原题'),
                ),
                const SizedBox(height: 10),
              ],
              if (navigation.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: navigation),
              if (status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 4, runSpacing: 4, children: status),
              ],
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'study') {
      await openPlanItem(context, item);
      if (mounted) await _load();
    } else if (action == 'source') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscussionPage(conversationId: item.conversationId),
        ),
      );
      if (mounted) await _load();
    } else if (action == 'plan') {
      await _openStudyPlan(item.studyPlanId!);
    } else if (action == 'schedule') {
      await _scheduleOrMove(item, block);
    } else if (action == 'start') {
      await _setStatus(item, PlanItemStatus.doing);
    } else if (action == 'complete') {
      await _setStatus(item, PlanItemStatus.done);
    } else if (action == 'end' && block != null) {
      await _endAppointment(block, item);
    }
  }

  Future<void> _scheduleOrMove(PlanItem item, ScheduleBlock? block) async {
    final draft = await showZhixinDialog<BlockDraft>(
      context: context,
      builder: (_) => BlockDialog(
        items: [item],
        initialStart: block?.startAt,
        initialMinutes: block?.endAt.difference(block.startAt).inMinutes,
      ),
    );
    if (draft == null || !mounted) return;
    try {
      final service = AppScope.of(context).study.plan;
      final end = draft.start.add(Duration(minutes: draft.minutes));
      final commitId = block == null
          ? await service.scheduleItem(
              planItemId: item.id,
              start: draft.start,
              end: end,
            )
          : await service.moveBlock(block.id, start: draft.start, end: end);
      await _load();
      if (!mounted) return;
      showActionToast(
        context,
        block == null ? '已预约「${item.title}」' : '已改约「${item.title}」',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: block == null ? '预约学习时间' : '调整预约时间',
        kind: 'plan_block_save',
        kept: '这次没有写入',
        next: '可以换一个时间再试',
      );
    }
  }

  /// 结束一次预约只改时间块；完成步骤才推进计划进度。
  Future<void> _endAppointment(ScheduleBlock block, PlanItem? item) async {
    final completeLabel = (item?.isStudyStep ?? false) ? '完成这一步' : '完成事项';
    final action = await showZhixinAlert<String>(
      context: context,
      title: '结束本次预约',
      content: Text(
        '这次预约记为结束，学习进度不变，没做完的内容和草稿会保留。'
        '要把它记为完成，请选择“$completeLabel”。',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop('end'),
          child: const Text('结束本次预约'),
        ),
        if (item != null && item.open)
          forui.FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop('complete'),
            child: Text(completeLabel),
          ),
      ],
    );
    if (action == null || !mounted) return;
    try {
      final service = AppScope.of(context).study.plan;
      int? commitId;
      if (action == 'complete' && item != null) {
        await service.setStatus(item.id, PlanItemStatus.done);
      } else {
        commitId = await service.setBlockStatus(block.id, 'done');
      }
      await _load();
      if (!mounted) return;
      if (commitId == null) {
        showToast(
          context,
          action == 'complete' ? '已$completeLabel' : '本次预约已结束',
        );
      } else {
        showActionToast(
          context,
          action == 'complete' ? '已$completeLabel' : '本次预约已结束',
          label: '撤销',
          onPressed: () =>
              undoCommitWithFeedback(context, commitId!, reload: _load),
        );
      }
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '结束本次预约',
        kind: 'plan_block_end',
        kept: '预约与事项保持原样',
      );
    }
  }

  Future<void> _openStudyPlan(int id) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => StudyPlanPage(planId: id)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final week = _week;
    return forui.FScaffold(
      header: ZhixinHeader(
        nested: false,
        title: const Text('安排'),
        actions: [
          if (week != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: forui.FButton(
                variant: forui.FButtonVariant.secondary,
                size: forui.FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: _capacity,
                prefix: const Icon(FLucideIcons.calculator),
                child: const Text('这周能做什么'),
              ),
            ),
            ZhixinHeaderAction(
              icon: FLucideIcons.plus,
              tooltip: '新建事项',
              onPressed: _addItem,
            ),
            moreMenu(
              label: '更多安排操作',
              icon: FLucideIcons.ellipsisVertical,
              items: [
                ZhixinMenuItem(
                  label: '预约时间',
                  subtitle: '为一项未完成的事项选一段时间',
                  onSelected: _schedule,
                ),
                ZhixinMenuItem(
                  label: '整组顺延',
                  subtitle: '本周搭子排的弹性预约一起向后移',
                  onSelected: _shiftWeek,
                ),
                ZhixinMenuItem(label: '新建目标', onSelected: _addGoal),
                ZhixinMenuItem(label: '添加课表', onSelected: _addTimetable),
              ],
            ),
          ],
        ],
      ),
      child: _week == null && !_active
          ? const SizedBox.shrink()
          : _loading
          // 首读也先摆出页签，读完只在下面换内容，页面不往下跳。
          ? PageWidth(
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
            )
          : week == null
          ? EmptyState(
              icon: FLucideIcons.calendarX,
              title: '安排读取失败',
              description: _error ?? '请刷新本机数据后重试。',
              action: forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _load,
                child: const Text('重试'),
              ),
            )
          // 读完第一次之后整页淡入；之后换页签或换周只淡入列表。
          : FadeIn(
              child: PageWidth(
                child: Column(
                  children: [
                    _tabBar(theme),
                    Expanded(
                      child: FadeIn(
                        trigger: (_tab, _shownAnchor),
                        playOnInit: false,
                        // 四个页签常驻，切换只换显示：切回来不再重建，滚动
                        // 位置与已读到的内容都留住；首次进入某个页签时才建。
                        child: IndexedStack(
                          sizing: StackFit.expand,
                          index: _tab,
                          children: [
                            for (var tab = 0; tab < 4; tab++)
                              if (_visited.contains(tab))
                                _tabList(theme, week, tab)
                              else
                                const SizedBox.shrink(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

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
        ZhixinSegment(value: 0, label: '日程'),
        ZhixinSegment(value: 1, label: '事项'),
        ZhixinSegment(value: 2, label: '目标'),
        ZhixinSegment(value: 3, label: 'AI 改动'),
      ],
      selected: _tab,
      onChanged: (tab) => setState(() {
        _tab = tab;
        _visited.add(tab);
      }),
    ),
  );

  /// 每个页签保留自己的滚动位置，卡片进入视口缓存范围时才构建。
  Widget _tabList(ZhixinTheme theme, PlanWeek week, int tab) =>
      RefreshIndicator(
        onRefresh: _load,
        child: NotificationListener<ScrollNotification>(
          onNotification: tab == 1 ? _onItemsScroll : null,
          child: CustomScrollView(
            key: PageStorageKey<String>('plan-tab-$tab'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  theme.space.page,
                  theme.space.xs,
                  theme.space.page,
                  theme.space.section + 4,
                ),
                sliver: SliverMainAxisGroup(
                  slivers: switch (tab) {
                    0 => _scheduleTab(theme, week),
                    1 => _itemsTab(theme, week),
                    2 => _goalsTab(theme, week),
                    _ => _operationsTab(theme, week),
                  },
                ),
              ),
            ],
          ),
        ),
      );

  List<Widget> _scheduleTab(ZhixinTheme theme, PlanWeek week) {
    final summaries = week.studyPlans;
    final openPlans = summaries
        .where((summary) => summary.plan.open)
        .toList(growable: false);
    final closedPlans = summaries
        .where((summary) => !summary.plan.open)
        .toList(growable: false);
    final visiblePlans = _showAllPlans ? summaries : openPlans;
    final schedule = <Object>[
      for (final entry in _dayEntries(week.blocks)) ...[
        entry.key,
        ...entry.value,
      ],
    ];
    return [
      _weekOverview(theme, week),
      SliverList.builder(
        itemCount: schedule.length,
        itemBuilder: (context, index) => switch (schedule[index]) {
          final DateTime day => _dayHeading(theme, day, week.timetable),
          final ScheduledItem entry => _blockTile(theme, entry),
          _ => throw StateError('无效的日程行'),
        },
      ),
      SliverList.builder(
        itemCount:
            1 + (openPlans.isEmpty && !_showAllPlans ? 1 : openPlans.length),
        itemBuilder: (context, index) {
          if (index == 0) {
            return SectionHeading(
              title: '系统学习',
              subtitle: _showAllPlans ? '全部计划' : '进行中的计划，标出下一步与最近一次预约',
              action: widget.onOpenMaterials == null || visiblePlans.isEmpty
                  ? null
                  : forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: widget.onOpenMaterials,
                      child: const Text('选择学习材料'),
                    ),
            );
          }
          if (openPlans.isNotEmpty) {
            return _studyPlanTile(theme, openPlans[index - 1]);
          }
          return forui.FCard(
            child: EmptyState(
              icon: FLucideIcons.route,
              title: summaries.isEmpty ? '还没有系统学习计划' : '没有进行中的系统学习计划',
              description: summaries.isEmpty
                  ? '选择教材或课件，按页码建立学习顺序。'
                  : '已暂停或已完成的计划默认收起，可以展开查看。',
              action: widget.onOpenMaterials == null
                  ? null
                  : forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: widget.onOpenMaterials,
                      child: const Text('选择学习材料'),
                    ),
            ),
          );
        },
      ),
      ExpandReveal.sliver(
        key: const ValueKey('closed-study-plans'),
        visible: _showAllPlans,
        child: SliverList.builder(
          itemCount: closedPlans.length,
          itemBuilder: (context, index) =>
              _studyPlanTile(theme, closedPlans[index]),
        ),
      ),
      _timetableList(theme, week, showPlanToggle: closedPlans.isNotEmpty),
    ];
  }

  Widget _weekOverview(ZhixinTheme theme, PlanWeek week) {
    final policy = AppScope.of(context).timePolicy;
    final range = policy.naturalWeekRange(_shownAnchor!);
    final currentWeek =
        range.start == policy.naturalWeekRange(policy.now).start;
    final lastDay = DateTime(
      range.start.year,
      range.start.month,
      range.start.day + 6,
    );
    final planned = week.blocks.where((entry) => entry.block.planned).length;
    const gridKey = ValueKey('week-grid');
    final showGridToggle = week.blocks.isNotEmpty || week.timetable.isNotEmpty;
    final rows = <WidgetBuilder>[
      (_) => forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.sm),
          child: Row(
            children: [
              ZhixinIconButton(
                tooltip: '上一周',
                onPressed: () => _selectWeek(
                  DateTime(_anchor.year, _anchor.month, _anchor.day - 7),
                ),
                icon: FLucideIcons.chevronLeft,
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${range.start.month}月${range.start.day}日 – '
                      '${lastDay.month}月${lastDay.day}日',
                      textAlign: TextAlign.center,
                      style: theme.text.titleMedium.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (planned > 0)
                      Text(
                        '${currentWeek ? '本周 · ' : ''}$planned 次预约',
                        textAlign: TextAlign.center,
                        style: theme.text.bodySmall.copyWith(
                          color: theme.colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              ZhixinIconButton(
                tooltip: '下一周',
                onPressed: () => _selectWeek(
                  DateTime(_anchor.year, _anchor.month, _anchor.day + 7),
                ),
                icon: FLucideIcons.chevronRight,
              ),
            ],
          ),
        ),
      ),
      if (!currentWeek)
        (_) => Center(
          child: forui.FButton(
            variant: forui.FButtonVariant.ghost,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: () => _selectWeek(policy.now),
            prefix: const Icon(FLucideIcons.calendarDays),
            child: const Text('回到本周'),
          ),
        ),
      (_) => SizedBox(height: theme.space.md),
      if (showGridToggle)
        (_) => Center(
          child: forui.FButton(
            variant: forui.FButtonVariant.ghost,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: () => setState(() => _showWeekGrid = !_showWeekGrid),
            prefix: const Icon(FLucideIcons.grid3x3),
            child: Text(_showWeekGrid ? '收起周视图' : '周视图'),
          ),
        ),
      if (_showWeekGrid) ...[
        (_) => _WeekGridKeepAlive(key: gridKey, child: _weekGrid(theme, week)),
        (_) => SizedBox(height: theme.space.md),
      ],
      if (week.blocks.isEmpty)
        (_) => forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.calendarCheck,
            title: currentWeek ? '本周暂无预约' : '这一周暂无预约',
            description: '可以立即开始学习，也可以为已有事项预约时间。',
            action: forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: _schedule,
              child: const Text('选择事项并预约'),
            ),
          ),
        ),
    ];
    return SliverList.builder(
      itemCount: rows.length,
      findChildIndexCallback: (key) => _showWeekGrid && key == gridKey
          ? 2 + (currentWeek ? 0 : 1) + (showGridToggle ? 1 : 0)
          : null,
      itemBuilder: (context, index) => rows[index](context),
    );
  }

  Widget _timetableList(
    ZhixinTheme theme,
    PlanWeek week, {
    required bool showPlanToggle,
  }) {
    final header = <WidgetBuilder>[
      if (showPlanToggle)
        (_) => Center(
          child: forui.FButton(
            variant: forui.FButtonVariant.ghost,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: () => setState(() => _showAllPlans = !_showAllPlans),
            child: Text(
              _showAllPlans ? '只看进行中的计划' : '显示全部计划（${week.studyPlans.length}）',
            ),
          ),
        ),
      (_) => SectionHeading(
        title: '固定课表',
        subtitle: '安排学习时自动避开这些时段',
        action: forui.FButton(
          variant: forui.FButtonVariant.ghost,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: _addTimetable,
          prefix: const Icon(FLucideIcons.plus),
          child: const Text('添加'),
        ),
      ),
      if (week.timetable.isEmpty)
        (_) => Text(
          '添加课程时间后，安排学习时会自动检查冲突。',
          style: theme.text.bodySmall.copyWith(
            color: theme.colors.onSurfaceVariant,
          ),
        ),
    ];
    return SliverList.builder(
      itemCount: header.length + week.timetable.length,
      itemBuilder: (context, index) {
        if (index < header.length) return header[index](context);
        final entry = week.timetable[index - header.length];
        return Padding(
          padding: EdgeInsets.only(bottom: theme.space.sm),
          child: forui.FTile(
            prefix: const LeadingIcon(
              FLucideIcons.graduationCap,
              tone: TagTone.neutral,
            ),
            title: Text(entry.title),
            subtitle: Text(
              '${weekdayLabel(entry.weekday)} ${entry.startTime}–${entry.endTime}'
              '${entry.location == null ? '' : '，${entry.location}'}',
            ),
            suffix: ZhixinIconButton(
              tooltip: '删除这节课',
              icon: FLucideIcons.trash2,
              onPressed: () => _deleteTimetable(entry),
            ),
          ),
        );
      },
    );
  }

  Widget _weekGrid(ZhixinTheme theme, PlanWeek week) {
    final weekStart = _shownAnchor!;
    final events = <CalendarEventData<Object>>[];
    for (final entry in week.blocks) {
      final start = entry.block.startAt;
      final end = entry.block.endAt;
      events.add(
        CalendarEventData<Object>(
          date: DateTime(start.year, start.month, start.day),
          startTime: start,
          endTime: end,
          title: entry.itemTitle,
          color: theme.colors.primary,
          event: entry,
        ),
      );
    }
    for (final entry in week.timetable) {
      for (var offset = 0; offset < 7; offset++) {
        final day = DateTime(
          weekStart.year,
          weekStart.month,
          weekStart.day + offset,
        );
        if (day.weekday != entry.weekday) continue;
        final start = _atTime(day, entry.startTime);
        final end = _atTime(day, entry.endTime);
        if (start == null || end == null || !end.isAfter(start)) continue;
        events.add(
          CalendarEventData<Object>(
            date: DateTime(day.year, day.month, day.day),
            startTime: start,
            endTime: end,
            title: entry.title,
            color: theme.colors.outlineVariant,
            event: entry,
          ),
        );
      }
    }
    final controller = EventController<Object>();
    controller.addAll(events);
    return Container(
      height: 420,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: theme.radius.card,
        border: Border.all(color: theme.colors.outlineVariant),
      ),
      child: flutter_material.Material(
        type: flutter_material.MaterialType.transparency,
        child: WeekView<Object>(
          key: _weekGridKey,
          controller: controller,
          initialDay: weekStart,
          startHour: 6,
          endHour: 24,
          heightPerMinute: 0.55,
          showVerticalLines: true,
          weekPageHeaderBuilder: (start, end) => const SizedBox.shrink(),
          weekDayStringBuilder: (index) {
            const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
            return index >= 1 && index <= 7 ? labels[index - 1] : '';
          },
          timeLineStringBuilder: (date, {secondaryDate}) => '${date.hour}:00',
          onPageChange: (date, _) => _selectWeek(date),
          onEventTap: (events, date) =>
              _openGridEvent(events.firstOrNull?.event),
        ),
      ),
    );
  }

  DateTime? _atTime(DateTime day, String text) {
    final parts = text.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return DateTime(day.year, day.month, day.day, hour, minute);
  }

  Future<void> _openGridEvent(Object? event) async {
    if (event is ScheduledItem) {
      final item = await _itemById(event.block.planItemId);
      if (!mounted) return;
      if (item != null) {
        await _showItem(item);
        return;
      }
      showToast(context, event.itemTitle);
      return;
    }
    if (event is TimetableEntry && mounted) {
      showToast(context, '${event.title} ${event.startTime}–${event.endTime}');
    }
  }

  List<Widget> _itemsTab(ZhixinTheme theme, PlanWeek week) {
    final header = <Widget>[
      SectionHeading(
        first: true,
        title: '学习事项',
        subtitle: '默认列出未完成的事项，已完成的按页查看',
        action: forui.FButton(
          variant: forui.FButtonVariant.ghost,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: _addItem,
          prefix: const Icon(FLucideIcons.plus),
          child: const Text('新建'),
        ),
      ),
      if (week.items.isEmpty && week.doneItemCount == 0)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.listChecks,
            title: '暂无学习事项',
            description: '接受讨论中的下一步建议，或直接新建一项。',
          ),
        ),
      if (week.items.isEmpty && week.doneItemCount > 0)
        forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.circleCheck,
            title: '没有未完成的学习事项',
            description: '已完成的 ${week.doneItemCount} 项可以展开查看。',
          ),
        ),
    ];
    return [
      SliverList.builder(
        itemCount: header.length + week.items.length,
        itemBuilder: (context, index) => index < header.length
            ? header[index]
            : _itemTile(theme, week.items[index - header.length]),
      ),
      if (week.doneItemCount > 0) ..._doneSection(theme, week),
    ];
  }

  List<Widget> _doneSection(ZhixinTheme theme, PlanWeek week) {
    final items = _doneItems;
    final hasFooter = _loadingDone || _doneLoadFailed;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: theme.space.sm),
          child: Center(
            child: forui.FButton(
              variant: forui.FButtonVariant.ghost,
              size: forui.FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _loadingDone
                  ? null
                  : () {
                      if (!_doneLoaded) {
                        _loadDone(reset: true);
                        return;
                      }
                      // 保留本页用于收起动画，下次展开时重新读第一页。
                      setState(() {
                        _doneLoaded = false;
                        _hasMoreDone = false;
                        _doneLoadFailed = false;
                      });
                    },
              suffix: Icon(
                _doneLoaded ? FLucideIcons.chevronUp : FLucideIcons.chevronDown,
              ),
              child: Text(
                _doneLoaded ? '收起已完成' : '显示已完成（${week.doneItemCount}）',
              ),
            ),
          ),
        ),
      ),
      ExpandReveal.sliver(
        key: const ValueKey('done-items'),
        visible: _doneLoaded,
        child: SliverList.builder(
          itemCount: 1 + items.length + (hasFooter ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const SectionHeading(title: '已完成', subtitle: '按完成时间从近到远');
            }
            if (index <= items.length) {
              return _itemTile(theme, items[index - 1]);
            }
            if (_loadingDone) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: forui.FCircularProgress()),
              );
            }
            return LoadMoreFooter(
              label: '重试读取更早的已完成事项',
              loading: false,
              onPressed: () => _loadDone(),
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _goalsTab(ZhixinTheme theme, PlanWeek week) {
    final header = <Widget>[
      SectionHeading(
        first: true,
        title: '学习目标',
        subtitle: '多个目标可以同时进行',
        action: forui.FButton(
          variant: forui.FButtonVariant.ghost,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: _addGoal,
          prefix: const Icon(FLucideIcons.plus),
          child: const Text('新建'),
        ),
      ),
      if (week.goals.isEmpty)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.flag,
            title: '按需要建立目标',
            description: '持续学习的相关事项可以归入目标，独立问题单独保留。',
          ),
        ),
    ];
    return [
      SliverList.builder(
        itemCount: header.length + week.goals.length,
        itemBuilder: (context, index) => index < header.length
            ? header[index]
            : _goalTile(theme, week.goals[index - header.length]),
      ),
    ];
  }

  List<Widget> _operationsTab(ZhixinTheme theme, PlanWeek week) {
    final header = <Widget>[
      const SectionHeading(
        first: true,
        title: 'AI 的改动',
        subtitle: '搭子执行过的变更，可以逐条撤销',
      ),
      if (week.operations.isEmpty)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.history,
            title: '暂无 AI 改动',
            description: '这里记录搭子已执行的变更。',
          ),
        ),
    ];
    return [
      SliverList.builder(
        itemCount: header.length + week.operations.length,
        itemBuilder: (context, index) => index < header.length
            ? header[index]
            : _operationTile(theme, week.operations[index - header.length]),
      ),
    ];
  }

  String _goalName(int? id) {
    if (id == null) return '无归属';
    final goals = _week?.goals ?? const <LearningGoal>[];
    return goals.where((goal) => goal.id == id).firstOrNull?.title ?? '目标已删除';
  }

  Future<void> _closeGoal(LearningGoal goal) async {
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '结束「${goal.title}」',
      content: const Text('结束目标后，已有讨论、事项和学习结果会继续保留。'),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('结束'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppScope.of(context).study.plan.closeGoal(goal.id);
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '结束目标',
        kind: 'plan_goal_close',
        kept: '目标与记录保持原样',
      );
    }
  }

  String? _scheduledPlanTitle(ScheduledItem block) {
    final item = _week?.items
        .where((item) => item.id == block.block.planItemId)
        .firstOrNull;
    final planId = item?.studyPlanId;
    if (planId == null) return null;
    return _week?.studyPlans
        .where((summary) => summary.plan.id == planId)
        .firstOrNull
        ?.plan
        .title;
  }

  Map<DateTime, List<ScheduledItem>> _byDay(List<ScheduledItem> blocks) {
    final map = <DateTime, List<ScheduledItem>>{};
    for (final block in blocks) {
      final day = DateTime(
        block.block.startAt.year,
        block.block.startAt.month,
        block.block.startAt.day,
      );
      map.putIfAbsent(day, () => []).add(block);
    }
    return map;
  }

  /// 今天的分组排在最前，其余日期按时间顺序。
  List<MapEntry<DateTime, List<ScheduledItem>>> _dayEntries(
    List<ScheduledItem> blocks,
  ) {
    final now = AppScope.of(context).timePolicy.now;
    final today = DateTime(now.year, now.month, now.day);
    final entries = _byDay(blocks).entries.toList();
    entries.sort((left, right) {
      final leftToday = left.key == today;
      final rightToday = right.key == today;
      if (leftToday != rightToday) return leftToday ? -1 : 1;
      return left.key.compareTo(right.key);
    });
    return entries;
  }

  Widget _goalTile(ZhixinTheme theme, LearningGoal goal) {
    final paused = goal.status == LearningGoalStatus.paused;
    final scope = goal.scopeText?.trim();
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        prefix: LeadingIcon(
          FLucideIcons.flag,
          tone: goal.active
              ? TagTone.accent
              : paused
              ? TagTone.attention
              : TagTone.muted,
        ),
        title: Text(goal.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            TagRow(
              children: [
                StatusTag(
                  goal.status.label,
                  tone: goal.active
                      ? TagTone.accent
                      : paused
                      ? TagTone.attention
                      : TagTone.muted,
                ),
                if (goal.dueDate != null)
                  StatusTag('截止 ${goal.dueDate}', icon: FLucideIcons.calendar),
              ],
            ),
            if (scope != null && scope.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  scope,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        suffix: moreMenu(
          items: [
            if (goal.active)
              ZhixinMenuItem(label: '暂停目标', onSelected: () => _pauseGoal(goal)),
            if (paused)
              ZhixinMenuItem(
                label: '恢复目标',
                onSelected: () => _resumeGoal(goal),
              ),
            ZhixinMenuItem(label: '标记结束', onSelected: () => _closeGoal(goal)),
          ],
        ),
      ),
    );
  }

  Widget _studyPlanTile(ZhixinTheme theme, StudyPlanSummary summary) {
    final plan = summary.plan;
    final next = summary.nextStep;
    final block = summary.nextBlock;
    final muted = theme.text.bodySmall.copyWith(
      color: theme.colors.onSurfaceVariant,
    );
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        prefix: LeadingIcon(
          plan.done ? FLucideIcons.circleCheck : FLucideIcons.route,
          tone: plan.done ? TagTone.muted : TagTone.accent,
        ),
        title: Text(plan.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            TagRow(
              children: [
                StatusTag(
                  plan.statusLabel,
                  tone: plan.open ? TagTone.accent : TagTone.muted,
                ),
                StatusTag(plan.progressLabel),
                if (plan.materialTitle != null)
                  StatusTag(plan.materialTitle!, icon: FLucideIcons.bookOpen),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              next == null ? '全部步骤已完成' : '下一步：${next.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurface,
              ),
            ),
            Text(
              block == null
                  ? '尚未预约'
                  : '最近预约：${shortTime(block.startAt)}–${clockOf(block.endAt)}',
              style: muted,
            ),
          ],
        ),
        suffix: Icon(
          FLucideIcons.chevronRight,
          color: theme.colors.onSurfaceVariant,
        ),
        onPress: () => _openStudyPlan(plan.id),
      ),
    );
  }

  /// 日期与当天的课程单独占一行，预约按条目延迟构建。
  Widget _dayHeading(
    ZhixinTheme theme,
    DateTime day,
    List<TimetableEntry> timetable,
  ) {
    final entries = timetable.where((entry) => entry.weekday == day.weekday);
    final now = AppScope.of(context).timePolicy.now;
    final today = DateTime(now.year, now.month, now.day);
    final isToday = day == today;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isToday) ...[
                const StatusTag('今天', tone: TagTone.accent),
                SizedBox(width: theme.space.sm),
              ],
              Text(
                dayLabel(day),
                style: theme.text.labelLarge.copyWith(
                  color: isToday
                      ? theme.colors.onSurface
                      : theme.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    FLucideIcons.graduationCap,
                    size: 14,
                    color: theme.colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '课：${entries.map((entry) => '${entry.startTime} ${entry.title}').join('、')}',
                      style: theme.text.bodySmall.copyWith(
                        color: theme.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _blockTile(ZhixinTheme theme, ScheduledItem entry) {
    final block = entry.block;
    final planned = block.planned;
    final planTitle = _scheduledPlanTitle(entry);
    final figures = theme.text.figures;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        prefix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3,
              height: 36,
              decoration: BoxDecoration(
                color: planned
                    ? theme.colors.primary
                    : theme.colors.outlineVariant,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clockOf(block.startAt),
                  style: figures.copyWith(
                    color: planned
                        ? theme.colors.onSurface
                        : theme.colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  clockOf(block.endAt),
                  style: figures.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        onPress: () async {
          final item = await _itemById(block.planItemId);
          if (item != null && mounted) await _showItem(item);
        },
        title: Text(
          entry.itemTitle,
          style: planned
              ? null
              : TextStyle(color: theme.colors.onSurfaceVariant),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (planTitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '所属计划：$planTitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 4),
            TagRow(
              children: [
                if (block.status == 'cancelled')
                  const StatusTag('已取消', tone: TagTone.muted),
                if (block.status == 'done')
                  const StatusTag('本次预约已结束', tone: TagTone.muted),
                if (entry.itemStatus == PlanItemStatus.done)
                  const StatusTag('这一步已完成', tone: TagTone.accent),
                block.locked
                    ? const StatusTag('已固定', icon: FLucideIcons.lock)
                    : const StatusTag('弹性', tone: TagTone.muted),
                if (block.source == 'ai')
                  const StatusTag('搭子排的', icon: FLucideIcons.sparkles),
              ],
            ),
          ],
        ),
        suffix: _blockMenu(entry),
      ),
    );
  }

  Widget _itemTile(ZhixinTheme theme, PlanItem item) {
    final note = item.note?.trim();
    final overdue =
        item.open &&
        item.dueAt != null &&
        item.dueAt!.isBefore(AppScope.of(context).timePolicy.now);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        onPress: () => _showItem(item),
        prefix: LeadingIcon(
          item.done
              ? FLucideIcons.circleCheck
              : item.isStudyStep
              ? FLucideIcons.route
              : FLucideIcons.circlePlay,
          tone: item.done
              ? TagTone.muted
              : item.priority > 0
              ? TagTone.attention
              : TagTone.accent,
        ),
        title: Text(item.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            TagRow(
              children: [
                StatusTag(
                  item.status.label,
                  tone: item.open ? TagTone.accent : TagTone.muted,
                ),
                if (item.priority == 2)
                  const StatusTag('最高优先', tone: TagTone.attention)
                else if (item.priority == 1)
                  const StatusTag('优先', tone: TagTone.attention),
                if (item.dueAt != null)
                  StatusTag(
                    '截止 ${dateText(item.dueAt)}',
                    icon: FLucideIcons.calendar,
                    tone: overdue ? TagTone.attention : TagTone.neutral,
                  ),
                if (item.estMinutes != null)
                  StatusTag('约 ${item.estMinutes} 分钟', tone: TagTone.muted),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                item.isStudyStep
                    ? '系统学习第 ${item.seq ?? 1} 步'
                    : _goalName(item.goalId),
                if (item.pageLabel.isNotEmpty) item.pageLabel,
              ].join('，'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (note != null && note.isNotEmpty)
              Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.4),
              ),
          ],
        ),
        suffix: moreMenu(
          items: [
            ZhixinMenuItem(
              label: item.isStudyStep ? '完成这一步' : '完成事项',
              onSelected: () => _setStatus(item, PlanItemStatus.done),
            ),
            ZhixinMenuItem(
              label: '恢复待办',
              onSelected: () => _setStatus(item, PlanItemStatus.todo),
            ),
            ZhixinMenuItem(
              label: '暂缓',
              onSelected: () => _setStatus(item, PlanItemStatus.deferred),
            ),
            if (item.priority != 1)
              ZhixinMenuItem(
                label: '设为优先',
                onSelected: () => _setPriority(item, 1),
              ),
            if (item.priority != 2)
              ZhixinMenuItem(
                label: '设为最高优先',
                onSelected: () => _setPriority(item, 2),
              ),
            if (item.priority != 0)
              ZhixinMenuItem(
                label: '取消优先',
                onSelected: () => _setPriority(item, 0),
              ),
          ],
        ),
      ),
    );
  }

  Widget _blockMenu(ScheduledItem block) {
    final item = _cachedItem(block.block.planItemId);
    return moreMenu(
      items: [
        if (block.block.planned)
          ZhixinMenuItem(
            label: '结束本次预约',
            onSelected: () => _runBlockAction(block, 'end'),
          ),
        if (block.block.planned && item != null && item.open)
          ZhixinMenuItem(
            label: item.isStudyStep ? '完成这一步' : '完成事项',
            onSelected: () => _runBlockAction(block, 'complete'),
          ),
        if (!block.block.planned && (item?.open ?? true))
          ZhixinMenuItem(
            label: '恢复为待开始',
            onSelected: () => _runBlockAction(block, 'restore'),
          ),
        ZhixinMenuItem(
          label: block.block.locked ? '改为弹性' : '固定这次',
          onSelected: () => _runBlockAction(block, 'lock'),
        ),
        ZhixinMenuItem(
          label: '取消这次',
          onSelected: () => _runBlockAction(block, 'delete'),
        ),
      ],
    );
  }

  Future<void> _runBlockAction(ScheduledItem block, String value) async {
    final item = await _itemById(block.block.planItemId);
    if (value == 'end') {
      await _endAppointment(block.block, item);
      return;
    }
    if (value == 'complete' && item != null) {
      await _setStatus(item, PlanItemStatus.done);
      return;
    }
    if (!mounted) return;
    final service = AppScope.of(context).study.plan;
    try {
      final (commitId, message) = switch (value) {
        'restore' => (
          await service.setBlockStatus(block.block.id, 'planned'),
          '已恢复为待开始',
        ),
        'delete' => (await service.deleteBlock(block.block.id), '已取消这次预约'),
        'lock' => (
          await service.setBlockLocked(block.block.id, !block.block.locked),
          block.block.locked ? '已改为弹性' : '已固定这次预约',
        ),
        _ => (null, ''),
      };
      await _load();
      if (!mounted || commitId == null) return;
      showActionToast(
        context,
        message,
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '修改这次预约',
        kind: 'plan_block_menu',
        kept: '这次没有写入',
      );
    }
  }

  Future<void> _setPriority(PlanItem item, int priority) async {
    try {
      await AppScope.of(context).study.plan.setPriority(item.id, priority);
      await _load();
    } catch (error, stack) {
      if (!mounted) return;
      _reportFailure(
        error,
        stack,
        action: '修改优先顺序',
        kind: 'plan_item_priority',
        kept: '优先顺序没有改动',
      );
    }
  }

  Widget _operationTile(ZhixinTheme theme, RevisionCommit commit) {
    final createdAt = commit.createdAt;
    final changes = commit.changeCount == 1
        ? '1 项变化'
        : '${commit.changeCount} 项变化';
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm - 2),
      child: forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.sparkles),
        title: Text(commit.action),
        subtitle: Text(
          createdAt == null ? changes : '${shortTime(createdAt)}，$changes',
        ),
        suffix: forui.FButton(
          variant: forui.FButtonVariant.outline,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: () => _undo(commit),
          prefix: const Icon(FLucideIcons.undo2),
          child: const Text('撤销'),
        ),
      ),
    );
  }
}

/// 周视图展开后保留自己的横向周数和纵向滚动位置。
class _WeekGridKeepAlive extends StatefulWidget {
  const _WeekGridKeepAlive({super.key, required this.child});

  final Widget child;

  @override
  State<_WeekGridKeepAlive> createState() => _WeekGridKeepAliveState();
}

class _WeekGridKeepAliveState extends State<_WeekGridKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
