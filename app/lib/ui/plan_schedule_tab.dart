import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/plan_service.dart';
import '../domain/models/study.dart';
import 'copy.dart';
import 'format.dart';
import 'plan_actions.dart';
import 'plan_week_view.dart';
import 'workspace_widgets.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_menu.dart';
import 'zhixin_toast.dart';

/// 安排页的日程页签：本周预约、系统学习计划与固定课表。
///
/// 页签只接收页面读好的一周与写入动作；换周、回到本周与整组顺延都交给
/// [PlanActions] 与页面回调，页签自己不读数据、不建订阅。
class PlanScheduleTab extends StatefulWidget {
  const PlanScheduleTab({
    super.key,
    required this.week,
    required this.weekStart,
    required this.actions,
    required this.onSelectWeek,
    required this.onStepWeek,
    required this.onOpenMaterials,
    required this.onOpenBlock,
    required this.showAllPlans,
    required this.showWeekGrid,
    required this.onToggleAllPlans,
    required this.onToggleWeekGrid,
  });

  final PlanWeek week;

  /// 这一份数据属于哪一周的周一；周视图与标题按它排日期。
  final DateTime weekStart;

  final PlanActions actions;

  /// 回到指定日期所在的那一周。
  final ValueChanged<DateTime> onSelectWeek;

  /// 从当前目标周前后移动。
  final ValueChanged<int> onStepWeek;

  /// 从日程跳到材料页；为空时不显示入口。
  final VoidCallback? onOpenMaterials;

  /// 周视图里点到一段预约。
  final ValueChanged<ScheduledItem> onOpenBlock;

  /// 系统学习列表是不是展开全部计划；视图状态由页面保存，换周重建页签时不丢。
  final bool showAllPlans;

  /// 周视图是否展开；同样由页面保存，换周之后保持展开。
  final bool showWeekGrid;

  /// 切换系统学习列表的展开范围。
  final VoidCallback onToggleAllPlans;

  /// 展开或收起周视图。
  final VoidCallback onToggleWeekGrid;

  @override
  State<PlanScheduleTab> createState() => _PlanScheduleTabState();
}

class _PlanScheduleTabState extends State<PlanScheduleTab> {
  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return CustomScrollView(
      key: const PageStorageKey<String>('plan-tab-0'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            theme.space.page,
            theme.space.xs,
            theme.space.page,
            theme.space.section,
          ),
          sliver: SliverMainAxisGroup(slivers: _slivers(theme)),
        ),
      ],
    );
  }

  List<Widget> _slivers(ZhixinTheme theme) {
    final week = widget.week;
    final summaries = week.studyPlans;
    final openPlans = summaries
        .where((summary) => summary.plan.open)
        .toList(growable: false);
    final closedPlans = summaries
        .where((summary) => !summary.plan.open)
        .toList(growable: false);
    final visiblePlans = widget.showAllPlans ? summaries : openPlans;
    final schedule = <Object>[
      for (final entry in _dayEntries(week.blocks)) ...[
        entry.key,
        ...entry.value,
      ],
    ];
    return [
      _weekOverview(theme),
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
            1 +
            (openPlans.isEmpty && !widget.showAllPlans ? 1 : openPlans.length),
        itemBuilder: (context, index) {
          if (index == 0) {
            return SectionHeading(
              title: '系统学习',
              subtitle: widget.showAllPlans ? '全部计划' : '进行中的计划，标出下一步与最近一次预约',
              action: widget.onOpenMaterials == null || visiblePlans.isEmpty
                  ? null
                  : SectionLink(
                      label: '选择学习材料',
                      onPressed: widget.onOpenMaterials,
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
        visible: widget.showAllPlans,
        child: SliverList.builder(
          itemCount: closedPlans.length,
          itemBuilder: (context, index) =>
              _studyPlanTile(theme, closedPlans[index]),
        ),
      ),
      _timetableList(theme, showPlanToggle: closedPlans.isNotEmpty),
    ];
  }

  /// 本周概览：换周、回到本周、周视图开关与空周说明。
  Widget _weekOverview(ZhixinTheme theme) {
    final week = widget.week;
    final policy = AppScope.of(context).timePolicy;
    final range = policy.naturalWeekRange(widget.weekStart);
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
                onPressed: () => widget.onStepWeek(-1),
                icon: FLucideIcons.chevronLeft,
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      monthDayRange(range.start, lastDay),
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
                onPressed: () => widget.onStepWeek(1),
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
            onPress: () => widget.onSelectWeek(policy.now),
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
            onPress: widget.onToggleWeekGrid,
            prefix: const Icon(FLucideIcons.grid3x3),
            child: Text(widget.showWeekGrid ? '收起周视图' : '周视图'),
          ),
        ),
      if (widget.showWeekGrid) ...[
        (_) => _WeekGridKeepAlive(
          key: gridKey,
          child: PlanWeekView(
            weekStart: widget.weekStart,
            blocks: week.blocks,
            timetable: week.timetable,
            onWeekSelected: widget.onSelectWeek,
            onBlockTap: widget.onOpenBlock,
            onTimetableTap: _openGridTimetable,
          ),
        ),
        (_) => SizedBox(height: theme.space.md),
      ],
      if (week.blocks.isEmpty)
        (_) => forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.calendarCheck,
            title: currentWeek
                ? emptyWeekAppointments
                : emptyOtherWeekAppointments,
            description: '可以立即开始学习，也可以为已有事项预约时间。',
            action: forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => widget.actions.schedule(),
              child: const Text('选择事项并预约'),
            ),
          ),
        ),
    ];
    return SliverList.builder(
      itemCount: rows.length,
      findChildIndexCallback: (key) => widget.showWeekGrid && key == gridKey
          ? 2 + (currentWeek ? 0 : 1) + (showGridToggle ? 1 : 0)
          : null,
      itemBuilder: (context, index) => rows[index](context),
    );
  }

  /// 固定课表：一节课一行，删除之后可以从提示条撤销。
  Widget _timetableList(ZhixinTheme theme, {required bool showPlanToggle}) {
    final week = widget.week;
    final header = <WidgetBuilder>[
      if (showPlanToggle)
        (_) => Center(
          child: forui.FButton(
            variant: forui.FButtonVariant.ghost,
            size: forui.FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: widget.onToggleAllPlans,
            child: Text(
              widget.showAllPlans
                  ? '只看进行中的计划'
                  : '显示全部计划（${week.studyPlans.length}）',
            ),
          ),
        ),
      (_) => SectionHeading(
        title: '固定课表',
        subtitle: '安排学习时自动避开这些时段',
        action: SectionLink(
          label: '添加',
          icon: FLucideIcons.plus,
          onPressed: () => widget.actions.addTimetable(),
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
              onPressed: () => widget.actions.deleteTimetable(entry),
            ),
          ),
        );
      },
    );
  }

  /// 周视图里点到一节课：只读出这一节的时间，不改数据。
  void _openGridTimetable(TimetableEntry entry) {
    showToast(context, '${entry.title} ${entry.startTime}–${entry.endTime}');
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

  String? _scheduledPlanTitle(ScheduledItem block) {
    final item = widget.week.items
        .where((item) => item.id == block.block.planItemId)
        .firstOrNull;
    final planId = item?.studyPlanId;
    if (planId == null) return null;
    return widget.week.studyPlans
        .where((summary) => summary.plan.id == planId)
        .firstOrNull
        ?.plan
        .title;
  }

  /// 日期与当天的课程单独占一行，标题的写法与记录页共用 [relativeDayHeading]。
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
              Text(
                relativeDayHeading(day, now: now),
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
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    FLucideIcons.graduationCap,
                    size: 14,
                    color: theme.colors.onSurfaceVariant,
                  ),
                  SizedBox(width: theme.space.xs),
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
      padding: EdgeInsets.only(top: theme.space.tight),
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
            SizedBox(width: theme.space.sm),
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
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        onPress: () => widget.onOpenBlock(entry),
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
            SizedBox(height: theme.space.xs),
            TagRow(
              children: [
                if (block.status == ScheduleBlockStatus.cancelled)
                  const StatusTag('已取消', tone: TagTone.muted),
                if (block.status == ScheduleBlockStatus.done)
                  const StatusTag('本次预约已结束', tone: TagTone.muted),
                if (entry.itemStatus == PlanItemStatus.done)
                  const StatusTag('这一步已完成', tone: TagTone.accent),
                block.locked
                    ? const StatusTag('已固定', icon: FLucideIcons.lock)
                    : const StatusTag('弹性', tone: TagTone.muted),
                if (block.source == PlanItemSource.ai)
                  const StatusTag('$buddyName排的', icon: FLucideIcons.sparkles),
              ],
            ),
          ],
        ),
        suffix: _blockMenu(entry),
      ),
    );
  }

  Widget _blockMenu(ScheduledItem block) {
    final item = widget.week.items
        .where((candidate) => candidate.id == block.block.planItemId)
        .firstOrNull;
    return moreMenu(
      items: [
        if (block.block.planned)
          ZhixinMenuItem(
            label: '结束本次预约',
            onSelected: () => widget.actions.endAppointment(block.block, item),
          ),
        if (block.block.planned && item != null && item.open)
          ZhixinMenuItem(
            label: item.isStudyStep ? '完成这一步' : '完成事项',
            onSelected: () =>
                widget.actions.setStatus(item, PlanItemStatus.done),
          ),
        if (!block.block.planned && (item?.open ?? true))
          ZhixinMenuItem(
            label: '恢复为待开始',
            onSelected: () => widget.actions.setBlockStatus(
              block.block.id,
              ScheduleBlockStatus.planned,
            ),
          ),
        ZhixinMenuItem(
          label: block.block.locked ? '改为弹性' : '固定这次',
          onSelected: () => widget.actions.setBlockLocked(
            block.block.id,
            !block.block.locked,
          ),
        ),
        ZhixinMenuItem(
          label: '取消这次',
          onSelected: () => widget.actions.deleteBlock(block.block.id),
        ),
      ],
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
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: LeadingIcon(
          plan.done ? FLucideIcons.circleCheck : FLucideIcons.route,
          tone: plan.done ? TagTone.muted : TagTone.accent,
        ),
        title: Text(plan.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: theme.space.xs),
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
        onPress: () => widget.actions.openStudyPlanPage(plan.id),
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
