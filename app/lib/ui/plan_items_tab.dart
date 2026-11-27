import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/plan_service.dart';
import '../domain/models/study.dart';
import 'copy.dart';
import 'format.dart';
import 'live_view.dart';
import 'plan_actions.dart';
import 'workspace_widgets.dart';
import 'zhixin_menu.dart';

/// 骨架卡的四周留白取 space.md。
const _skeletonPadding = 12.0;

/// 安排页的事项页签：未完成的事项与按页展开的已完成事项。
class PlanItemsTab extends StatefulWidget {
  const PlanItemsTab({
    super.key,
    required this.week,
    required this.actions,
    required this.visible,
  });

  final PlanOverview week;

  final PlanActions actions;

  /// 这个页签是不是当前页签；不可见时不续读下一页。
  final bool visible;

  @override
  State<PlanItemsTab> createState() => _PlanItemsTabState();
}

class _PlanItemsTabState extends State<PlanItemsTab> {
  /// 已完成事项第一页的订阅；收起时置空，`LiveView` 随之退订。
  Stream<List<PlanItem>>? _doneStream;

  /// 第一页；订阅每带回一页就换掉这一份，界面由 `LiveView` 的 builder 重建。
  List<PlanItem> _doneFirst = const [];

  /// 继续读取的页：按完成时间接着往后，去重之后接在第一页后面。
  List<PlanItem> _doneOlder = const [];

  bool _doneExpanded = false;

  /// 正在读下一页；第一页的读取状态由 `LiveView` 的 loading 给出。
  bool _loadingDone = false;

  /// 列表底部有重试入口：第一页读取失败，或续读下一页失败。
  bool _doneLoadFailed = false;

  /// 失败的是第一页：重试要换一条订阅重读，而不是接着往下翻。
  bool _doneFirstFailed = false;

  bool _doneLoadScheduled = false;
  static const int _donePageSize = 30;

  /// 屏幕上已经读到的已完成事项：第一页在前，继续读取的页去重之后接在后面。
  List<PlanItem> get _doneItems {
    if (_doneOlder.isEmpty) return _doneFirst;
    final seen = {for (final item in _doneFirst) item.id};
    return [
      ..._doneFirst,
      for (final item in _doneOlder)
        if (seen.add(item.id)) item,
    ];
  }

  /// 还没读到的已完成事项数量由安排页的总数决定，写入之后跟着一起更新。
  bool get _hasMoreDone => _doneItems.length < widget.week.doneItemCount;

  bool get _canLoadMoreDone =>
      widget.visible &&
      _doneExpanded &&
      _hasMoreDone &&
      !_loadingDone &&
      !_doneLoadFailed;

  /// 展开或收起已完成事项；展开时给出订阅，收起时撤掉，已经读出的内容留着。
  void _toggleDone() {
    if (_loadingDone) return;
    if (_doneExpanded) {
      // 已经读出的内容留到收起动画结束，下次展开再重新订阅第一页。
      setState(() {
        _doneExpanded = false;
        _doneStream = null;
        _doneOlder = const [];
        _doneLoadFailed = false;
        _doneFirstFailed = false;
      });
      return;
    }
    setState(() {
      _doneExpanded = true;
      _doneOlder = const [];
      _doneLoadFailed = false;
      _doneFirstFailed = false;
      _doneStream = AppScope.of(context).study.plan
          .watchDoneItems(limit: _donePageSize);
    });
  }

  /// 第一页回来了：换掉屏幕上的一屏，写入之后的重读也走这里。
  void _onDoneFirst(List<PlanItem> page) {
    _doneFirst = page;
    _doneLoadFailed = false;
    _doneFirstFailed = false;
  }

  /// 第一页读取失败：已经读出的内容保持不变，列表底部留重试入口。
  void _onDoneError(Object error, StackTrace stack) {
    if (!mounted) return;
    setState(() {
      _doneLoadFailed = true;
      _doneFirstFailed = true;
    });
    _reportFailure(
      error,
      stack,
      action: '读取已完成事项',
      kind: 'plan_done_read',
      kept: '已经读出的内容保持不变',
      next: '可以在列表底部重试',
    );
  }

  /// 继续读取已完成的下一页；已经读到的内容保持不变，失败时留下重试入口。
  Future<void> _loadMoreDone() async {
    if (_loadingDone || !_hasMoreDone) return;
    final offset = _doneItems.length;
    setState(() {
      _loadingDone = true;
      _doneLoadFailed = false;
    });
    try {
      final page = await AppScope.of(context).study.plan
          .doneItems(limit: _donePageSize, offset: offset);
      if (!mounted) return;
      setState(() {
        _doneOlder = [..._doneOlder, ...page];
        _loadingDone = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loadingDone = false;
        _doneLoadFailed = true;
        _doneFirstFailed = false;
      });
      _reportFailure(
        error,
        stack,
        action: '读取已完成事项',
        kind: 'plan_done_read',
        kept: '已经读出的内容保持不变',
        next: '可以在列表底部重试',
      );
    }
  }

  /// 读取失败之后重试：第一页失败时换一条订阅，否则继续读下一页。
  void _retryDone() {
    if (_doneFirstFailed) {
      setState(() {
        _doneLoadFailed = false;
        _doneFirstFailed = false;
        _doneStream = AppScope.of(context).study.plan
            .watchDoneItems(limit: _donePageSize);
      });
    } else {
      _loadMoreDone();
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
    final loaded = _doneItems.length;
    _doneLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _doneLoadScheduled = false;
      if (mounted && _canLoadMoreDone && loaded == _doneItems.length) {
        _loadMoreDone();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    return false;
  }

  /// 本地写入失败交给页面统一提示；异常本身进本机诊断记录。
  void _reportFailure(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    String? kept,
    String? next,
  }) {
    widget.actions.onReportFailure(
      error,
      stack,
      action: action,
      kind: kind,
      kept: kept,
      next: next,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LiveView<List<PlanItem>>(
      stream: _doneStream,
      onData: _onDoneFirst,
      onError: _onDoneError,
      builder: (context, _, firstLoading) =>
          NotificationListener<ScrollNotification>(
            onNotification: _onItemsScroll,
            child: CustomScrollView(
              key: const PageStorageKey<String>('plan-tab-1'),
              slivers: [
                SliverPadding(
                  // 左右边距由页面在每一页的外层给出，页签整幅滑进滑出；这里只留上下的间隔。
                  padding: EdgeInsets.only(
                    top: theme.space.xs,
                    bottom: theme.space.section,
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: _slivers(theme, firstLoading: firstLoading),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  List<Widget> _slivers(ZhixinTheme theme, {required bool firstLoading}) {
    final week = widget.week;
    final header = <Widget>[
      SectionHeading(
        first: true,
        title: planItemName,
        subtitle: '默认列出未完成的事项，已完成的按页查看',
        action: SectionLink(
          label: '新建',
          icon: FLucideIcons.plus,
          onPressed: () => widget.actions.addItem(),
        ),
      ),
      if (week.items.isEmpty && week.doneItemCount == 0)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.listChecks,
            title: emptyPlanItems,
            description: '接受讨论中的下一步建议，或直接新建一项。',
          ),
        ),
      if (week.items.isEmpty && week.doneItemCount > 0)
        forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.circleCheck,
            title: emptyPlanItemsNoneOpen,
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
      if (week.doneItemCount > 0)
        ..._doneSection(theme, firstLoading: firstLoading),
    ];
  }

  /// 已完成事项：一个展开入口，展开之后按页追加。
  List<Widget> _doneSection(ZhixinTheme theme, {required bool firstLoading}) {
    final week = widget.week;
    final items = _doneItems;
    final loadingFooter = firstLoading || _loadingDone;
    final hasFooter = loadingFooter || _doneLoadFailed;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: theme.space.sm),
          child: Center(
            child: forui.FButton(
              variant: forui.FButtonVariant.ghost,
              size: forui.FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _loadingDone ? null : _toggleDone,
              suffix: Icon(
                _doneExpanded
                    ? FLucideIcons.chevronUp
                    : FLucideIcons.chevronDown,
              ),
              child: Text(
                _doneExpanded ? '收起已完成' : '显示已完成（${week.doneItemCount}）',
              ),
            ),
          ),
        ),
      ),
      ExpandReveal.sliver(
        key: const ValueKey('done-items'),
        visible: _doneExpanded,
        child: SliverList.builder(
          itemCount: 1 + items.length + (hasFooter ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const SectionHeading(title: '已完成', subtitle: '按完成时间从近到远');
            }
            if (index <= items.length) {
              return _itemTile(theme, items[index - 1]);
            }
            if (loadingFooter) {
              return const Padding(
                padding: EdgeInsets.all(_skeletonPadding),
                child: ListSkeleton(rows: 1, rowHeight: 64),
              );
            }
            return LoadMoreFooter(
              label: _doneFirstFailed ? '重试读取已完成事项' : '重试读取更早的已完成事项',
              loading: false,
              onPressed: _retryDone,
            );
          },
        ),
      ),
    ];
  }

  Widget _itemTile(ZhixinTheme theme, PlanItem item) {
    final note = item.note?.trim();
    final overdue =
        item.open &&
        item.dueAt != null &&
        item.dueAt!.isBefore(AppScope.of(context).timePolicy.now);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        onPress: () => widget.actions.openItem(item),
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
            SizedBox(height: theme.space.xs),
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
            SizedBox(height: theme.space.xs),
            Text(
              [
                item.isStudyStep
                    ? '系统学习第 ${item.seq ?? 1} 步'
                    : widget.actions.goalName(item.goalId),
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
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
        suffix: moreMenu(
          items: [
            ZhixinMenuItem(
              label: item.isStudyStep ? '完成这一步' : '完成事项',
              onSelected: () =>
                  widget.actions.setStatus(item, PlanItemStatus.done),
            ),
            ZhixinMenuItem(
              label: '恢复待办',
              onSelected: () =>
                  widget.actions.setStatus(item, PlanItemStatus.todo),
            ),
            ZhixinMenuItem(
              label: '暂缓',
              onSelected: () =>
                  widget.actions.setStatus(item, PlanItemStatus.deferred),
            ),
            if (item.priority != 1)
              ZhixinMenuItem(
                label: '设为优先',
                onSelected: () => widget.actions.setPriority(item, 1),
              ),
            if (item.priority != 2)
              ZhixinMenuItem(
                label: '设为最高优先',
                onSelected: () => widget.actions.setPriority(item, 2),
              ),
            if (item.priority != 0)
              ZhixinMenuItem(
                label: '取消优先',
                onSelected: () => widget.actions.setPriority(item, 0),
              ),
          ],
        ),
      ),
    );
  }
}
