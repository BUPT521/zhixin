import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'plan_dialogs.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 一份系统学习计划：继续位置、步骤与临时求助入口。
class StudyPlanPage extends StatefulWidget {
  const StudyPlanPage({super.key, required this.planId});

  final int planId;

  @override
  State<StudyPlanPage> createState() => _StudyPlanPageState();
}

class _StudyPlanPageState extends State<StudyPlanPage> {
  /// 一屏订阅：计划、步骤、每一步的预约与场次随写入更新（ADR-0014）。
  ///
  /// 推进步骤、预约与打开讨论之后的重读都由数据层完成，页面不再自己重读。
  Stream<StudyPlanScreen>? _stream;

  /// 最近一次读回的一屏；动作处理从这里取当前计划与预约。
  StudyPlanScreen? _screen;
  bool _busy = false;
  String? _notice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库，等依赖就绪之后再订阅。
    _stream ??= AppScope.of(context).study.systemPlan
        .watchScreen(widget.planId);
  }

  /// 新的一屏回来了：动作处理改用它，界面由订阅重建。
  void _onScreen(StudyPlanScreen screen) {
    _screen = screen;
  }

  void _onReadError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取学习计划',
      kind: 'study_plan_read',
      kept: '屏幕上已经显示的计划与步骤保持不变',
      next: '可以返回再打开这一页',
    );
    showToast(context, message);
  }

  /// 打开这一步的讨论；返回之后这一屏随订阅更新，不再手动重读。
  Future<void> _openDiscussion(int conversationId) async {
    await openDiscussion(context, conversationId);
  }

  Future<void> _studyStep(PlanItem step) async {
    if (_busy) return;
    final scope = AppScope.of(context);
    final sourceConversationId = _screen?.view.plan.conversationId;
    final stepConversationId = step.conversationId;
    final hasPreviousDiscussion =
        stepConversationId != null &&
        stepConversationId != sourceConversationId &&
        await scope.chat.discussion.byId(stepConversationId) != null;
    var newDiscussion = false;
    if (hasPreviousDiscussion && mounted) {
      final choice = await showZhixinAlert<bool>(
        context: context,
        title: '继续这一步',
        content: const Text('这一步已有讨论记录。可以接着上次的位置继续，也可以另开一条讨论。'),
        actions: [
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop(false),
            child: const Text('接着上次'),
          ),
          forui.FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.of(context).pop(true),
            child: const Text('另开讨论'),
          ),
        ],
      );
      if (choice == null || !mounted) return;
      newDiscussion = choice;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (newDiscussion) {
        await scope.study.systemPlan.setStepStatus(
          widget.planId,
          step.id,
          PlanItemStatus.doing,
        );
        final id = await scope.study.systemPlan.startAtCurrent(
          widget.planId,
          newDiscussion: true,
        );
        if (!mounted) return;
        await _openDiscussion(id);
      } else {
        await openPlanItem(context, step);
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '打开学习步骤',
          kind: 'study_plan_open_step',
          kept: '计划没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _schedule(PlanItem step) async {
    final block = _screen?.nextBlocks[step.id];
    final draft = await showZhixinDialog<BlockDraft>(
      context: context,
      builder: (_) => BlockDialog(
        items: [step],
        initialStart: block?.startAt,
        initialMinutes: block?.endAt.difference(block.startAt).inMinutes,
      ),
    );
    if (draft == null || !mounted) return;
    try {
      final service = AppScope.of(context).study.plan;
      final end = draft.start.add(Duration(minutes: draft.minutes));
      final result = block == null
          ? await service.scheduleItem(
              planItemId: step.id,
              start: draft.start,
              end: end,
            )
          : await service.moveBlock(block.id, start: draft.start, end: end);
      if (!mounted || !result.changed) return;
      showActionToast(
        context,
        block == null ? '已为这一步预约时间' : '已改约这一步的时间',
        label: '撤销',
        // 撤销写回之后的重读由订阅完成，这里不再手动刷新这一屏。
        onPressed: () => undoCommitWithFeedback(context, result.commitId!),
      );
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '预约这一步',
          kind: 'study_plan_schedule',
          kept: '这次没有写入',
          next: '可以换一个时间再试',
        ),
      );
    }
  }

  Future<void> _mark(PlanItem step, PlanItemStatus status) async {
    try {
      await AppScope.of(context).study.systemPlan
          .setStepStatus(widget.planId, step.id, status);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '记录学习步骤',
          kind: 'study_plan_step_status',
          kept: '步骤状态没有改动',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _temporary() async {
    final scope = AppScope.of(context);
    try {
      final id = await scope.study.systemPlan.startTemporary(widget.planId);
      if (!mounted) return;
      await _openDiscussion(id);
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '打开临时问题',
          kind: 'study_plan_temporary',
          kept: '计划没有改动',
          next: '可以再试一次',
        ),
      );
    }
  }

  Future<void> _togglePause() async {
    final view = _screen?.view;
    if (view == null) return;
    final service = AppScope.of(context).study.systemPlan;
    try {
      if (view.plan.open) {
        await service.pause(widget.planId);
      } else {
        await service.resume(widget.planId);
      }
    } catch (error, stack) {
      if (!mounted) return;
      setState(
        () => _notice = describeFailure(
          context,
          error,
          stack,
          action: '修改学习计划状态',
          kind: 'study_plan_status',
          kept: '计划状态没有改动',
          next: '可以再试一次',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveView<StudyPlanScreen>(
      stream: _stream,
      onData: _onScreen,
      onError: _onReadError,
      builder: (context, screen, loading) {
        if (loading) return const DetailScaffold(child: PageLoading());
        if (screen == null) {
          return DetailScaffold(
            header: const ZhixinHeader(title: Text('系统学习'), showBack: true),
            child: Center(child: Text(_notice ?? '未找到这份学习计划')),
          );
        }
        return _planBody(context, screen);
      },
    );
  }

  Widget _planBody(BuildContext context, StudyPlanScreen screen) {
    final theme = context.zhixin;
    final view = screen.view;
    final plan = view.plan;
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('系统学习'),
        showBack: true,
        actions: [
          ZhixinHeaderButton(
            label: plan.open ? '暂停' : '继续',
            onPressed: _togglePause,
          ),
        ],
      ),
      child: ListView(
        padding: theme.space.pageInsets(),
        children: [
          forui.FCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plan.title, style: theme.text.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${plan.statusLabel} · ${plan.progressLabel}',
                    style: theme.text.bodySmall,
                  ),
                  if (plan.materialTitle != null)
                    Text(
                      '材料：${plan.materialTitle}',
                      style: theme.text.bodySmall,
                    ),
                  if (plan.conversationId != null)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => _openDiscussion(plan.conversationId!),
                      child: const Text('返回来源讨论'),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.zhixin.space.gap),
          for (final step in view.steps) _stepCard(theme, screen, step),
          const SizedBox(height: 12),
          Wrap(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _temporary,
                prefix: const Icon(FLucideIcons.messageCircle),
                child: const Text('提出临时问题'),
              ),
            ],
          ),
          if (_notice != null) InlineNotice(message: _notice!),
        ],
      ),
    );
  }

  Widget _stepCard(ZhixinTheme theme, StudyPlanScreen screen, PlanItem step) {
    final isCurrent = screen.view.currentStep?.id == step.id;
    final block = screen.nextBlocks[step.id];
    final session = screen.sessions[step.id];
    final label = step.status == PlanItemStatus.todo ? '待学' : step.status.label;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: forui.FCard(
        // 当前要学的那一步用浅色底，和已经完成的步骤分开。
        style: isCurrent
            ? .delta(
                decoration: .shapeDelta(color: theme.colors.secondaryContainer),
              )
            : const .context(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('第 ${step.seq ?? 1} 步', style: theme.text.labelMedium),
                  const SizedBox(width: 8),
                  Text(label, style: theme.text.labelSmall),
                  const Spacer(),
                  if (step.pageLabel.isNotEmpty)
                    Text(step.pageLabel, style: theme.text.bodySmall),
                ],
              ),
              const SizedBox(height: 4),
              Text(step.title, style: theme.text.titleSmall),
              if (step.note != null)
                Text(step.note!, style: theme.text.bodySmall),
              if (block != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '预约：${shortTime(block.startAt)}–${clockOf(block.endAt)}',
                    style: theme.text.bodySmall,
                  ),
                ),
              if (step.done && step.completedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '完成于 ${shortTime(step.completedAt!)}',
                    style: theme.text.bodySmall,
                  ),
                ),
              if (step.done && session != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '这次学习：${shortTime(session.startedAt)}–'
                    '${shortTime(session.endedAt ?? session.startedAt)}'
                    '${session.outcomeLabel == null ? '' : ' · ${session.outcomeLabel}'}',
                    style: theme.text.bodySmall,
                  ),
                ),
                if (session.summary?.trim().isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '困难：${session.summary!.trim()}',
                      style: theme.text.bodySmall,
                    ),
                  ),
              ],
              Wrap(
                spacing: 4,
                children: [
                  if (!step.done)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : () => _studyStep(step),
                      child: const Text('学这一步'),
                    ),
                  if (!step.done)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : () => _schedule(step),
                      child: Text(block == null ? '预约时间' : '改期'),
                    ),
                  if (!step.done)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => _mark(step, PlanItemStatus.done),
                      child: const Text('完成这一步'),
                    ),
                  if (step.done)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => _mark(step, PlanItemStatus.todo),
                      child: const Text('恢复为待学习'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
