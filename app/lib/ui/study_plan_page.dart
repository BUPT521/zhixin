import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'format.dart';
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

class _StudyPlanPageState extends State<StudyPlanPage>
    with DataVersionWatcher<StudyPlanPage> {
  StudyPlanView? _view;
  Map<int, ScheduleBlock> _nextBlocks = const {};
  Map<int, StudySession> _sessions = const {};
  bool _loading = true;
  bool _busy = false;
  bool _started = false;
  String? _notice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    watchDataVersion(AppScope.of(context).dataVersion);
    if (_started) return;
    _started = true;
    _load();
  }

  /// 推进步骤与打开讨论都在页面里发起，动作结束会自己重读；忙碌时不叠加。
  @override
  bool get dataVersionActive => !_busy;

  @override
  void onDataVersionChanged() {
    _load();
  }

  Future<void> _load() async {
    try {
      final scope = AppScope.of(context);
      final view = await scope.study.systemPlan.view(widget.planId);
      final (blocks, sessions) = await (
        scope.study.plan.nextBlocksForItems(view.steps.map((step) => step.id)),
        scope.study.systemPlan.latestSessionsForSteps(
          view.steps.map((step) => step.id),
        ),
      ).wait;
      if (!mounted) return;
      // 结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _view = view;
        _nextBlocks = blocks;
        _sessions = sessions;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取学习计划',
          kind: 'study_plan_read',
          kept: '计划与步骤没有改动',
          next: '可以返回再打开',
        );
      });
    }
  }

  Future<void> _openDiscussion(int conversationId) async {
    await openDiscussion(context, conversationId);
    await _load();
  }

  Future<void> _studyStep(PlanItem step) async {
    if (_busy) return;
    final scope = AppScope.of(context);
    final sourceConversationId = _view?.plan.conversationId;
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
        if (mounted) await _load();
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
    final block = _nextBlocks[step.id];
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
      await _load();
      if (!mounted || !result.changed) return;
      showActionToast(
        context,
        block == null ? '已为这一步预约时间' : '已改约这一步的时间',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, result.commitId!, reload: _load),
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
      await _load();
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
    final view = _view;
    if (view == null) return;
    final service = AppScope.of(context).study.systemPlan;
    try {
      if (view.plan.open) {
        await service.pause(widget.planId);
      } else {
        await service.resume(widget.planId);
      }
      await _load();
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
    final theme = context.zhixin;
    final view = _view;
    if (_loading) {
      return const DetailScaffold(child: PageLoading());
    }
    if (view == null) {
      return DetailScaffold(
        header: const ZhixinHeader(title: Text('系统学习'), showBack: true),
        child: Center(child: Text(_notice ?? '未找到这份学习计划')),
      );
    }
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
          for (final step in view.steps) _stepCard(theme, step, view),
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

  Widget _stepCard(ZhixinTheme theme, PlanItem step, StudyPlanView view) {
    final isCurrent = view.currentStep?.id == step.id;
    final block = _nextBlocks[step.id];
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
              if (step.done && _sessions[step.id] != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '这次学习：${shortTime(_sessions[step.id]!.startedAt)}–'
                    '${shortTime(_sessions[step.id]!.endedAt ?? _sessions[step.id]!.startedAt)}'
                    '${_sessions[step.id]!.outcomeLabel == null ? '' : ' · ${_sessions[step.id]!.outcomeLabel}'}',
                    style: theme.text.bodySmall,
                  ),
                ),
                if (_sessions[step.id]!.summary?.trim().isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '困难：${_sessions[step.id]!.summary!.trim()}',
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
