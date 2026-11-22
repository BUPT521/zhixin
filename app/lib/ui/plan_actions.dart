import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/plan_service.dart';
import '../data/repository/schedule_repository.dart';
import '../data/revisions/revision_models.dart';
import '../domain/models/study.dart';
import '../domain/models/write_result.dart';
import 'copy.dart';
import 'format.dart';
import 'goal_dialog.dart';
import 'capacity_sheet.dart';
import 'plan_dialogs.dart';
import 'undo_feedback.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 从事项打开学习页；页面把导航入口传进来，动作层不依赖 navigation.dart，
/// 也就不会经由导航模块反向依赖页面。
typedef PlanOpenStudy = Future<void> Function(
  BuildContext context,
  PlanItem item,
);

/// 打开一条已有讨论。
typedef PlanOpenDiscussion = Future<void> Function(
  BuildContext context,
  String conversationId,
);

/// 打开系统学习计划。
typedef PlanOpenStudyPlan = Future<void> Function(
  BuildContext context,
  String planId,
);

/// 安排页的写入动作：页签只负责排列界面，对话框、服务调用与回执都走这里。
///
/// 动作只依赖页面传入的当前一周与刷新回调，不持有页面的 State；页签拿到同一个
/// 实例，按需调用其中几个方法。写完之后的一周数据由订阅带回，动作不自己重读。
class PlanActions {
  PlanActions({
    required this.context,
    required this.week,
    required this.onReportFailure,
    required this.goalName,
    required this.openStudy,
    required this.openDiscussion,
    required this.openStudyPlan,
  });

  /// 页面传进来的上下文；每次重建都换一份，对话框与提示都从这里取主题。
  final BuildContext context;

  /// 页面当前这一周的数据；为空表示首读还没有完成。
  final PlanWeek? week;

  /// 本地写入失败时给一句可行动的说明；异常本身进本机诊断记录。
  final void Function(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    String? kept,
    String? next,
  })
  onReportFailure;

  /// 事项所属目标的名称；目标已删除或没有归属时给出说明。
  final String? Function(String? goalId) goalName;

  /// 打开学习页、来源讨论与学习计划；导航入口由页面注入。
  final PlanOpenStudy openStudy;
  final PlanOpenDiscussion openDiscussion;
  final PlanOpenStudyPlan openStudyPlan;

  /// 新建事项；对话框里没有选择目标时写入无归属的事项。
  Future<void> addItem() async {
    final data = week;
    final goals = data == null
        ? const <LearningGoal>[]
        : data.goals.where((goal) => goal.active).toList(growable: false);
    final draft = await showZhixinDialog<ItemDraft>(
      context: context,
      builder: (_) => ItemDialog(goals: goals),
    );
    if (draft == null || !context.mounted) return;
    try {
      await AppScope.of(context).study.plan.addItem(
        title: draft.title,
        goalId: draft.goalId,
        note: draft.note,
        dueAt: draft.dueAt,
        minutes: draft.minutes,
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '保存学习事项',
        kind: 'plan_item_save',
        kept: '事项没有创建',
      );
    }
  }

  /// 新建目标；结束日期可以不填。
  Future<void> addGoal() async {
    final draft = await showGoalDialog(context);
    if (draft == null || !context.mounted) return;
    try {
      await AppScope.of(context).study.plan.addGoal(
        title: draft.title,
        scopeText: draft.scope,
        dueDate: draft.dueDate,
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '保存目标',
        kind: 'plan_goal_save',
        kept: '目标没有创建',
      );
    }
  }

  /// 暂停目标；可以先取消该目标下未开始的弹性安排。
  Future<void> pauseGoal(LearningGoal goal) async {
    final scope = AppScope.of(context);
    final service = scope.study.plan;
    final flexible = await service.flexibleFutureCount(goal.id);
    if (!context.mounted) return;
    var cancelFlexible = false;
    final confirmed = await showZhixinDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => ZhixinDialogLayout(
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
              onPress: () => Navigator.of(dialogContext).pop(false),
              child: const Text('保留目标'),
            ),
            forui.FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.of(dialogContext).pop(true),
              child: const Text('暂停'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final result = await service.pauseGoal(
        goal.id,
        cancelFlexibleFuture: cancelFlexible,
      );
      if (!context.mounted || !result.changed) return;
      showActionToast(
        context,
        '已暂停「${goal.title}」'
        '${cancelFlexible ? '，并取消 $flexible 项弹性安排' : ''}',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '暂停目标',
        kind: 'plan_goal_pause',
        kept: '目标与预约保持原样',
      );
    }
  }

  /// 恢复暂停的目标；暂停时取消的弹性安排不会自动排回来。
  Future<void> resumeGoal(LearningGoal goal) async {
    try {
      await AppScope.of(context).study.plan.resumeGoal(goal.id);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '恢复目标',
        kind: 'plan_goal_resume',
        kept: '目标状态没有改动',
      );
    }
  }

  /// 结束目标之前先说明影响；已有讨论、事项与学习结果都保留。
  Future<void> closeGoal(LearningGoal goal) async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '结束「${goal.title}」',
      content: const Text('结束目标后，已有讨论、事项和学习结果会继续保留。'),
      confirmLabel: '结束',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await AppScope.of(context).study.plan.closeGoal(goal.id);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '结束目标',
        kind: 'plan_goal_close',
        kept: '目标与记录保持原样',
      );
    }
  }

  /// 修改事项状态；写入之后的一周数据由订阅带回。
  Future<void> setStatus(PlanItem item, PlanItemStatus status) async {
    try {
      await AppScope.of(context).study.plan.setStatus(item.id, status);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '修改事项状态',
        kind: 'plan_item_status',
        kept: '事项状态没有改动',
      );
    }
  }

  /// 修改优先顺序；0 表示不标优先。
  Future<void> setPriority(PlanItem item, int priority) async {
    try {
      await AppScope.of(context).study.plan.setPriority(item.id, priority);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '修改优先顺序',
        kind: 'plan_item_priority',
        kept: '优先顺序没有改动',
      );
    }
  }

  /// 修改一段预约的状态；从日程菜单恢复为待开始时用到。
  Future<void> setBlockStatus(String id, ScheduleBlockStatus status) async {
    final action = status == ScheduleBlockStatus.planned ? '恢复为待开始' : '修改这次预约';
    try {
      await AppScope.of(context).study.plan.setBlockStatus(id, status);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: action,
        kind: 'plan_block_menu',
        kept: '这次没有写入',
      );
    }
  }

  /// 取消一段预约；撤销由提示条给出，撤销之后订阅重读这一周。
  Future<void> deleteBlock(String id) async {
    try {
      final result = await AppScope.of(context).study.plan.deleteBlock(id);
      if (!context.mounted || !result.changed) return;
      showActionToast(
        context,
        '已取消这次预约',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '修改这次预约',
        kind: 'plan_block_menu',
        kept: '这次没有写入',
      );
    }
  }

  /// 固定或改为弹性；两段之间可以来回切换。
  Future<void> setBlockLocked(String id, bool locked) async {
    try {
      await AppScope.of(context).study.plan.setBlockLocked(id, locked);
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '修改这次预约',
        kind: 'plan_block_menu',
        kept: '这次没有写入',
      );
    }
  }

  /// 为一项未完成的事项预约时间；不指定事项时列出全部未完成的事项。
  Future<void> schedule({PlanItem? item}) async {
    final data = week;
    if (data == null) return;
    final items = item == null
        ? data.items.where((candidate) => candidate.open).toList()
        : [item];
    if (items.isEmpty) {
      showToast(context, '先创建学习事项，再预约时间。');
      return;
    }
    final draft = await showZhixinDialog<BlockDraft>(
      context: context,
      builder: (_) => BlockDialog(items: items),
    );
    if (draft == null || !context.mounted) return;
    try {
      final result = await AppScope.of(context).study.plan.scheduleItem(
        planItemId: draft.itemId,
        start: draft.start,
        end: draft.start.add(Duration(minutes: draft.minutes)),
      );
      if (!context.mounted) return;
      final title = items
          .where((candidate) => candidate.id == draft.itemId)
          .firstOrNull
          ?.title;
      showActionToast(
        context,
        title == null ? '已预约学习时间' : '已预约「$title」',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
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
  Future<void> shiftWeek() async {
    final data = week;
    if (data == null) return;
    final now = AppScope.of(context).timePolicy.now;
    final movable = data.blocks
        .where((entry) {
          final block = entry.block;
          return block.planned &&
              !block.locked &&
              block.source == PlanItemSource.ai &&
              block.startAt.isAfter(now);
        })
        .toList(growable: false);
    if (movable.isEmpty) {
      showToast(context, '本周没有可顺延的$buddyName预约；固定的、自己排的与已经开始的预约保持原时间。');
      return;
    }
    final minutes = await showZhixinAlert<int>(
      context: context,
      title: '整组顺延',
      cancelLabel: '取消',
      content: Text(
        '把本周 ${movable.length} 条尚未开始、由$buddyName排的预约一起向后移动。'
        '固定的、自己排的与已经开始的预约保持原时间。',
      ),
      actions: [
        for (final value in const [30, 60, 120])
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop(value),
            child: Text('$value 分钟'),
          ),
      ],
    );
    if (minutes == null || !context.mounted) return;
    final adjustments = [
      for (final entry in movable)
        ScheduleAdjustment(
          id: entry.block.id,
          start: entry.block.startAt.add(Duration(minutes: minutes)),
          end: entry.block.endAt.add(Duration(minutes: minutes)),
        ),
    ];
    final confirmed = await confirmZhixin(
      context: context,
      title: '整组顺延预览',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('下面 ${movable.length} 条预约会向后移动 $minutes 分钟，确认后才写入：'),
          SizedBox(height: context.zhixin.space.gap),
          for (final entry in movable)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '「${entry.itemTitle}」'
                '${_blockRange(entry.block.startAt, entry.block.endAt)} → '
                '${_blockRange(entry.block.startAt.add(Duration(minutes: minutes)), entry.block.endAt.add(Duration(minutes: minutes)))}',
              ),
            ),
          SizedBox(height: context.zhixin.space.gap),
          Text('任一条与课表或其他预约冲突时，整组保持原样。', style: context.zhixin.text.bodySmall),
        ],
      ),
      confirmLabel: '确认顺延',
    );
    if (!confirmed || !context.mounted) return;
    final scope = AppScope.of(context);
    try {
      final result = await scope.study.plan.rescheduleGroup(adjustments);
      if (!context.mounted) return;
      showActionToast(
        context,
        '已整组顺延 $minutes 分钟，共 ${movable.length} 条预约',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '整组顺延预约',
        kind: 'plan_shift_week',
        kept: '整组预约保持原样',
      );
    }
  }

  /// 添加一节固定课表；学习安排时会避开这节课。
  Future<void> addTimetable() async {
    final draft = await showZhixinDialog<TimetableDraft>(
      context: context,
      builder: (_) => const TimetableDialog(),
    );
    if (draft == null || !context.mounted) return;
    try {
      await AppScope.of(context).study.plan.addTimetable(
        weekday: draft.weekday,
        startTime: draft.start,
        endTime: draft.end,
        title: draft.title,
        location: draft.location,
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '保存课表',
        kind: 'plan_timetable_save',
        kept: '课表没有写入',
      );
    }
  }

  /// 删除一节课之前先说明影响；删除后从提示条撤销，撤销会重新核对预约冲突。
  Future<void> deleteTimetable(TimetableEntry entry) async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除这节课',
      content: Text(
        '删除「${entry.title}」后，'
        '${weekdayLabel(entry.weekday)} ${entry.startTime}–${entry.endTime} '
        '不再参与学习安排的冲突检查。确定删除？',
      ),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    try {
      final result = await AppScope.of(context).study.plan
          .deleteTimetable(entry.id);
      if (!context.mounted || !result.changed) return;
      showActionToast(
        context,
        '已删除课表「${entry.title}」',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '删除课表',
        kind: 'plan_timetable_delete',
        kept: '这节课还在课表里',
      );
    }
  }

  /// 这周能做什么：面板里的预约写入之后，一周数据由订阅重读。
  Future<void> capacity() async {
    await showCapacitySheet(context);
  }

  /// 打开事项的操作面板，按用户选择跳转或改状态。
  Future<void> openItem(PlanItem item) async {
    final block = blockForItem(item);
    final canOpen = item.isStudyStep || item.conversationId != null;
    final action = await showZhixinSheet<String>(
      context: context,
      builder: (sheetContext) {
        final theme = sheetContext.zhixin;
        Widget fact(IconData icon, String text) => Padding(
          padding: EdgeInsets.only(top: theme.space.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: theme.colors.onSurfaceVariant),
              SizedBox(width: theme.space.sm),
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
              onPress: () => Navigator.pop(sheetContext, 'source'),
              prefix: const Icon(FLucideIcons.messageCircle),
              child: const Text('返回来源讨论'),
            ),
          if (item.studyPlanId != null)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, 'plan'),
              prefix: const Icon(FLucideIcons.route),
              child: const Text('打开学习计划'),
            ),
          if (item.open)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, 'schedule'),
              prefix: const Icon(FLucideIcons.calendar),
              child: Text(block == null ? '预约时间' : '改期'),
            ),
        ];
        final status = <Widget>[
          if (item.status == PlanItemStatus.todo)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, 'start'),
              child: const Text('标记进行中'),
            ),
          if (item.open)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, 'complete'),
              prefix: const Icon(FLucideIcons.check),
              child: Text(item.isStudyStep ? '完成这一步' : '完成事项'),
            ),
          if (block != null)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, 'end'),
              child: const Text('结束本次预约'),
            ),
        ];
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            theme.space.xl,
            0,
            theme.space.xl,
            theme.space.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TagRow(
                children: [
                  StatusTag(
                    goalName(item.goalId) ?? '',
                    icon: FLucideIcons.flag,
                  ),
                  StatusTag(
                    item.status.label,
                    tone: item.open ? TagTone.accent : TagTone.muted,
                  ),
                ],
              ),
              SizedBox(height: theme.space.sm),
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
                SizedBox(height: theme.space.md),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(theme.space.md),
                  decoration: BoxDecoration(
                    color: theme.colors.surfaceContainerHigh,
                    borderRadius: theme.radius.card,
                  ),
                  child: Text(item.note!, style: theme.text.bodyMedium),
                ),
              ],
              SizedBox(height: theme.space.page),
              if (canOpen && !item.done) ...[
                forui.FButton(
                  onPress: () => Navigator.pop(sheetContext, 'study'),
                  prefix: const Icon(FLucideIcons.play),
                  child: Text(item.isStudyStep ? '学这一步' : '回到原题'),
                ),
                SizedBox(height: theme.space.sm),
              ],
              if (navigation.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: navigation),
              if (status.isNotEmpty) ...[
                SizedBox(height: context.zhixin.space.gap),
                Wrap(spacing: 4, runSpacing: 4, children: status),
              ],
            ],
          ),
        );
      },
    );
    if (!context.mounted || action == null) return;
    // 从学习页或讨论页返回之后不再重读，订阅已经带回写入的结果。
    if (action == 'study') {
      await openStudy(context, item);
    } else if (action == 'source') {
      await openDiscussion(context, item.conversationId!);
    } else if (action == 'plan') {
      await openStudyPlan(context, item.studyPlanId!);
    } else if (action == 'schedule') {
      await scheduleOrMove(item, block);
    } else if (action == 'start') {
      await setStatus(item, PlanItemStatus.doing);
    } else if (action == 'complete') {
      await setStatus(item, PlanItemStatus.done);
    } else if (action == 'end' && block != null) {
      await endAppointment(block, item);
    }
  }

  /// 为一项已经预约的事项改期；没有预约时新建一段。
  Future<void> scheduleOrMove(PlanItem item, ScheduleBlock? block) async {
    final draft = await showZhixinDialog<BlockDraft>(
      context: context,
      builder: (_) => BlockDialog(
        items: [item],
        initialStart: block?.startAt,
        initialMinutes: block?.endAt.difference(block.startAt).inMinutes,
      ),
    );
    if (draft == null || !context.mounted) return;
    try {
      final service = AppScope.of(context).study.plan;
      final end = draft.start.add(Duration(minutes: draft.minutes));
      final result = block == null
          ? await service.scheduleItem(
              planItemId: item.id,
              start: draft.start,
              end: end,
            )
          : await service.moveBlock(block.id, start: draft.start, end: end);
      if (!context.mounted || !result.changed) return;
      showActionToast(
        context,
        block == null ? '已预约「${item.title}」' : '已改约「${item.title}」',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
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
  Future<void> endAppointment(ScheduleBlock block, PlanItem? item) async {
    final completeLabel = (item?.isStudyStep ?? false) ? '完成这一步' : '完成事项';
    final action = await showZhixinAlert<String>(
      context: context,
      title: '结束本次预约',
      cancelLabel: '取消',
      content: Text(
        '这次预约记为结束，学习进度不变，没做完的内容和草稿会保留。'
        '要把它记为完成，请选择“$completeLabel”。',
      ),
      actions: [
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
    if (action == null || !context.mounted) return;
    try {
      final service = AppScope.of(context).study.plan;
      WriteResult? result;
      if (action == 'complete' && item != null) {
        await service.setStatus(item.id, PlanItemStatus.done);
      } else {
        result = await service.setBlockStatus(
          block.id,
          ScheduleBlockStatus.done,
        );
      }
      if (!context.mounted) return;
      if (result == null || !result.changed) {
        showToast(
          context,
          action == 'complete' ? '已$completeLabel' : '本次预约已结束',
        );
      } else {
        showActionToast(
          context,
          action == 'complete' ? '已$completeLabel' : '本次预约已结束',
          label: '撤销',
          onPressed: () => undoCommitWithFeedback(context, result!.commitId!),
        );
      }
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(
        error,
        stack,
        action: '结束本次预约',
        kind: 'plan_block_end',
        kept: '预约与事项保持原样',
      );
    }
  }

  /// 打开系统学习计划；返回之后的一周数据由订阅带回。
  Future<void> openStudyPlanPage(String id) => openStudyPlan(context, id);

  /// AI 改动的撤销：撤销之后的一周数据由订阅带回。
  Future<void> undo(RevisionCommit commit) =>
      undoCommitWithFeedback(context, commit.id);

  /// 一项事项最近的一段待开始预约；没有预约时为空。
  ScheduleBlock? blockForItem(PlanItem item) {
    final blocks = week?.blocks ?? const <ScheduledItem>[];
    return blocks
        .where(
          (entry) => entry.block.planItemId == item.id && entry.block.planned,
        )
        .map((entry) => entry.block)
        .firstOrNull;
  }

  String _blockRange(DateTime start, DateTime end) {
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final endText = sameDay ? clockOf(end) : '${dayLabel(end)} ${clockOf(end)}';
    return '${shortTime(start)}–$endText';
  }

  void _report(
    Object error,
    StackTrace stack, {
    required String action,
    required String kind,
    String? kept,
    String? next,
  }) {
    onReportFailure(
      error,
      stack,
      action: action,
      kind: kind,
      kept: kept,
      next: next,
    );
  }
}

/// 周视图里点到一段预约时按编号补读事项；读不到时用预约里的标题说明。
Future<PlanItem?> itemForBlock(BuildContext context, String itemId) async {
  try {
    return await AppScope.of(context).study.plan.itemById(itemId);
  } catch (_) {
    return null;
  }
}
