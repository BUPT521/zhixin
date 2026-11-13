import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../ai/ai_chat_service.dart';
import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/material.dart';
import '../domain/models/study.dart';
import '../domain/models/study_plan.dart';
import 'discussion_page.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'plan_dialogs.dart';
import 'study_entry.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
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
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final scope = AppScope.of(context);
      final view = await scope.studyPlanService.view(widget.planId);
      final (blocks, sessions) = await (
        scope.schedule.nextBlocksForItems(
          view.steps.map((step) => step.id),
          scope.timePolicy.now,
        ),
        scope.studyPlanService.latestSessionsForSteps(
          view.steps.map((step) => step.id),
        ),
      ).wait;
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: conversationId),
      ),
    );
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
        await scope.conversations.byId(stepConversationId) != null;
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
        await scope.studyPlanService.setStepStatus(
          widget.planId,
          step.id,
          PlanItemStatus.doing,
        );
        final id = await scope.studyPlanService.startAtCurrent(
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
      final service = AppScope.of(context).planService;
      final end = draft.start.add(Duration(minutes: draft.minutes));
      final commitId = block == null
          ? await service.scheduleItem(
              planItemId: step.id,
              start: draft.start,
              end: end,
            )
          : await service.moveBlock(block.id, start: draft.start, end: end);
      await _load();
      if (!mounted) return;
      showActionToast(
        context,
        block == null ? '已为这一步预约时间' : '已改约这一步的时间',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _load),
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
      await AppScope.of(context).studyPlanService
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
      final id = await scope.studyPlanService.startTemporary(widget.planId);
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
    final service = AppScope.of(context).studyPlanService;
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
      return const forui.FScaffold(
        child: Center(child: forui.FCircularProgress()),
      );
    }
    if (view == null) {
      return forui.FScaffold(
        header: const ZhixinHeader(title: Text('系统学习'), showBack: true),
        child: Center(child: Text(_notice ?? '未找到这份学习计划')),
      );
    }
    final plan = view.plan;
    return forui.FScaffold(
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
          const SizedBox(height: 8),
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
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _notice!,
                style: TextStyle(color: theme.colors.error),
              ),
            ),
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

/// 从一份材料建立系统学习：选页码范围，提出顺序，确认后保存。
///
/// 从已有讨论开始时传入 `conversationId`，计划会保留原讨论标识；`initialPage`
/// 用当前页作为默认起点。
Future<void> showStudyPlanSetup(
  BuildContext context, {
  required Material material,
  int? conversationId,
  int? initialPage,
}) async {
  final scope = AppScope.of(context);
  final bounds = await scope.materials.pageBounds(material.id);
  final firstPage = bounds.first;
  final lastPage = bounds.last;
  if (firstPage == null || lastPage == null) {
    if (context.mounted) {
      showToast(context, '这份材料还没有页码和原文');
    }
    return;
  }
  String? conversationFocus;
  if (conversationId != null) {
    final messages = await scope.discussionService.history(conversationId);
    final selected = selectBuddyHistory(messages);
    final focus = selected
        .map(
          (message) =>
              '${message.role == 'user' ? '用户' : '搭子'}：${message.content.trim()}',
        )
        .join('\n');
    if (focus.isNotEmpty) conversationFocus = focus;
  }
  if (!context.mounted) return;
  final result = await showZhixinDialog<_PlanSetupResult>(
    context: context,
    builder: (_) => _PlanSetupDialog(
      material: material,
      initialPage: initialPage,
      firstPage: firstPage,
      lastPage: lastPage,
      conversationFocus: conversationFocus,
    ),
  );
  if (result == null || !context.mounted) return;
  try {
    final view = await scope.studyPlanService.createPlan(
      materialId: material.id,
      pageFrom: result.pageFrom,
      pageTo: result.pageTo,
      steps: result.steps,
      goalId: material.goalId,
      conversationId: conversationId,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudyPlanPage(planId: view.plan.id),
      ),
    );
  } catch (error, stack) {
    if (!context.mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '创建学习计划',
      kind: 'study_plan_create',
      kept: '没有写入计划',
      next: '可以再试一次',
    );
    showToast(context, message);
  }
}

class _PlanSetupResult {
  const _PlanSetupResult({
    required this.pageFrom,
    required this.pageTo,
    required this.steps,
  });

  final int pageFrom;
  final int pageTo;
  final List<StudyStepDraft> steps;
}

class _PlanSetupDialog extends StatefulWidget {
  const _PlanSetupDialog({
    required this.material,
    required this.firstPage,
    required this.lastPage,
    this.initialPage,
    this.conversationFocus,
  });

  final Material material;
  final int firstPage;
  final int lastPage;
  final int? initialPage;
  final String? conversationFocus;

  @override
  State<_PlanSetupDialog> createState() => _PlanSetupDialogState();
}

class _PlanSetupDialogState extends State<_PlanSetupDialog> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  StudyPlanProposal? _proposal;
  ({int from, int to})? _proposedRange;
  bool _loading = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    final start = (widget.initialPage ?? widget.firstPage).clamp(
      widget.firstPage,
      widget.lastPage,
    );
    _from.text = '$start';
    _to.text = '${widget.lastPage}';
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _invalidateProposal(TextEditingValue _) {
    final range = _proposedRange;
    if (range == null ||
        (range.from == int.tryParse(_from.text.trim()) &&
            range.to == int.tryParse(_to.text.trim()))) {
      return;
    }
    setState(() {
      _proposal = null;
      _proposedRange = null;
    });
  }

  Future<void> _propose() async {
    final from = int.tryParse(_from.text.trim()) ?? 0;
    final to = int.tryParse(_to.text.trim()) ?? 0;
    if (from < widget.firstPage || to > widget.lastPage || to < from) {
      setState(() => _notice = '页码范围无效。结束页需大于或等于起始页。');
      return;
    }
    setState(() {
      _loading = true;
      _notice = null;
      _proposal = null;
      _proposedRange = null;
    });
    try {
      final proposal = await AppScope.of(context).studyPlanService.propose(
        materialId: widget.material.id,
        pageFrom: from,
        pageTo: to,
        goalId: widget.material.goalId,
        conversationFocus: widget.conversationFocus,
      );
      if (!mounted) return;
      setState(() {
        _proposal = proposal;
        _proposedRange = (from: from, to: to);
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _proposal = null;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '生成学习顺序',
          kind: 'study_plan_generate',
          kept: '计划与已有步骤没有改动',
          next: '可以再试一次',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final proposal = _proposal;
    final steps = proposal?.steps ?? const <StudyStepDraft>[];
    final notice = proposal?.notice;
    return ZhixinDialogLayout(
      title: Text('系统学习《${widget.material.title}》'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 90,
                child: forui.FTextField(
                  control: .managed(
                    controller: _from,
                    onChange: _invalidateProposal,
                  ),
                  enabled: !_loading,
                  keyboardType: TextInputType.number,
                  label: Text(widget.material.isDocx ? '起始片段' : '起始页'),
                ),
              ),
              SizedBox(
                width: 90,
                child: forui.FTextField(
                  control: .managed(
                    controller: _to,
                    onChange: _invalidateProposal,
                  ),
                  enabled: !_loading,
                  keyboardType: TextInputType.number,
                  label: Text(widget.material.isDocx ? '结束片段' : '结束页'),
                ),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: _loading ? null : _propose,
                child: const Text('生成顺序'),
              ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: forui.FProgress(),
            ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('确认后保存学习顺序', style: theme.text.labelMedium),
            if (proposal != null)
              Text(
                '来源：${proposal.source.label(isDocx: widget.material.isDocx)}'
                ' · 覆盖本次所选 ${proposal.pageCount} ${widget.material.isDocx ? '个片段' : '页'}',
                style: theme.text.bodySmall,
              ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(notice, style: theme.text.bodySmall),
              ),
            for (var index = 0; index < steps.length; index++)
              forui.FTile(
                prefix: Text('${index + 1}'),
                title: Text(steps[index].title),
                subtitle: Text(
                  [
                    if (steps[index].pageFrom != null)
                      widget.material.position(
                        steps[index].pageFrom,
                        to: steps[index].pageTo,
                      ),
                    if (steps[index].isPrerequisite) '必要前置内容',
                    if (steps[index].note != null) steps[index].note!,
                  ].join(' · '),
                ),
              ),
          ],
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _notice!,
                style: TextStyle(color: theme.colors.error),
              ),
            ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress:
              steps.isEmpty ||
                  _loading ||
                  _proposedRange?.from != int.tryParse(_from.text.trim()) ||
                  _proposedRange?.to != int.tryParse(_to.text.trim())
              ? null
              : () => Navigator.of(context).pop(
                  _PlanSetupResult(
                    pageFrom: int.tryParse(_from.text.trim()) ?? 1,
                    pageTo: int.tryParse(_to.text.trim()) ?? 1,
                    steps: steps,
                  ),
                ),
          child: const Text('保存计划'),
        ),
      ],
    );
  }
}
