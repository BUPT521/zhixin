import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/plan_service.dart';
import '../domain/models/study.dart';
import 'format.dart';
import 'goal_dialog.dart';
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

/// 事项面板选中的命令：跳转与改状态各一条，不再用字符串约定动作。
///
/// 面板把命令交回页面，由 [PlanActions.openItem] 分派；写成枚举之后，增删一条
/// 命令时编译器会检查分派是否补齐，字符串拼错不会静默变成“什么都不做”。
enum _ItemCommand { study, source, plan, start, complete }

/// 安排页的写入动作：页签只负责排列界面，对话框、服务调用与回执都走这里。
///
/// 动作使用页面传入的数据与导航回调，写入后的数据由页面订阅更新。
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
  final PlanOverview? week;

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

  /// 暂停目标并提供撤销。
  Future<void> pauseGoal(LearningGoal goal) async {
    try {
      final result = await AppScope.of(context).study.plan.pauseGoal(goal.id);
      if (!context.mounted) return;
      final commitId = result.commitId;
      if (commitId != null) {
        showActionToast(
          context,
          '已暂停目标',
          label: '撤销',
          onPressed: () => undoCommitWithFeedback(context, commitId),
        );
      }
    } catch (error, stack) {
      if (!context.mounted) return;
      _report(error, stack, action: '暂停目标', kind: 'plan_goal_pause');
    }
  }

  /// 恢复暂停的目标；恢复后可继续使用该目标。
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

  /// 修改事项状态；写入之后的数据由订阅带回。
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

  /// 打开事项的操作面板，按用户选择跳转或改状态。
  Future<void> openItem(PlanItem item) async {
    final canOpen = item.isStudyStep || item.conversationId != null;
    final action = await showZhixinSheet<_ItemCommand>(
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
        // 动作分三层：打开学习内容是主按钮，单独一行；跳转到来源与计划在其后，状态操作最后显示。
        final navigation = <Widget>[
          if (item.conversationId != null)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, _ItemCommand.source),
              prefix: const Icon(FLucideIcons.messageCircle),
              child: const Text('返回来源讨论'),
            ),
          if (item.studyPlanId != null)
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, _ItemCommand.plan),
              prefix: const Icon(FLucideIcons.route),
              child: const Text('打开学习计划'),
            ),
        ];
        final status = <Widget>[
          if (item.status == PlanItemStatus.todo)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, _ItemCommand.start),
              child: const Text('标记进行中'),
            ),
          if (item.open)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.pop(sheetContext, _ItemCommand.complete),
              prefix: const Icon(FLucideIcons.check),
              child: Text(item.isStudyStep ? '完成这一步' : '完成事项'),
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
              if (item.dueAt case final due?)
                fact(FLucideIcons.calendar, '截止于 ${shortTime(due)}'),
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
                  onPress: () =>
                      Navigator.pop(sheetContext, _ItemCommand.study),
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
    switch (action) {
      case _ItemCommand.study:
        await openStudy(context, item);
      case _ItemCommand.source:
        await openDiscussion(context, item.conversationId!);
      case _ItemCommand.plan:
        await openStudyPlan(context, item.studyPlanId!);
      case _ItemCommand.start:
        await setStatus(item, PlanItemStatus.doing);
      case _ItemCommand.complete:
        await setStatus(item, PlanItemStatus.done);
    }
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
