import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/study.dart';
import '../domain/models/study_plan.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_toast.dart';

/// 一份系统学习计划：概览、下一步、全部步骤与临时求助入口。
class StudyPlanPage extends StatefulWidget {
  const StudyPlanPage({super.key, required this.planId});

  final String planId;

  @override
  State<StudyPlanPage> createState() => _StudyPlanPageState();
}

class _StudyPlanPageState extends State<StudyPlanPage> {
  /// 一屏订阅：计划、步骤与场次随写入更新（ADR-0014）。
  ///
  /// 推进步骤与打开讨论之后的重读都由数据层完成，页面不再自己重读。
  Stream<StudyPlanScreen>? _stream;

  /// 最近一次读回的一屏；动作处理从这里取当前计划。
  StudyPlanScreen? _screen;
  bool _busy = false;

  /// 一次性结果说明：一次动作之后的消息，以及它是不是失败。
  ///
  /// 成功与失败都只保存消息与这一个标记，用哪一种是 [ResultNotice] 的事，页面
  /// 不再每次动作各自拼错误框或一行小字。
  String? _notice;
  bool _noticeFailed = false;

  /// 首读失败过：标题栏照常显示，内容区给说明与重试入口。
  bool _readFailed = false;

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
    _readFailed = false;
  }

  /// 读取失败时就地说明一次，不再另弹一条同样的 toast；重试入口随说明给出。
  void _onReadError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取学习计划',
      kind: 'study_plan_read',
      kept: '屏幕上已经显示的计划与步骤保持不变',
      next: '可以点下面「重试」再读一次',
    );
    setState(() {
      _readFailed = true;
      _notice = message;
      _noticeFailed = true;
    });
  }

  /// 重新订阅这份计划；已经显示的内容留到新结果到达。
  void _retryRead() {
    setState(() {
      _readFailed = false;
      _notice = null;
      _noticeFailed = false;
      _stream = AppScope.of(context).study.systemPlan
          .watchScreen(widget.planId);
    });
  }

  /// 记下一条一次性说明；失败的动作与普通说明只差这一个标记。
  void _setNotice(String message, {required bool failed}) {
    setState(() {
      _notice = message;
      _noticeFailed = failed;
    });
  }

  /// 打开这一步的讨论；返回之后这一屏随订阅更新，不再手动重读。
  Future<void> _openDiscussion(String conversationId) async {
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
      _setNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '打开学习步骤',
          kind: 'study_plan_open_step',
          kept: '计划没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mark(PlanItem step, PlanItemStatus status) async {
    try {
      await AppScope.of(context).study.systemPlan
          .setStepStatus(widget.planId, step.id, status);
    } catch (error, stack) {
      if (!mounted) return;
      _setNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '记录学习步骤',
          kind: 'study_plan_step_status',
          kept: '步骤状态没有改动',
          next: '可以再试一次',
        ),
        failed: true,
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
      _setNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '打开临时问题',
          kind: 'study_plan_temporary',
          kept: '计划没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    }
  }

  /// 暂停或恢复计划：按钮写明实际动作，写入之后给一条可以撤销的回执。
  Future<void> _togglePause() async {
    final view = _screen?.view;
    if (view == null) return;
    final service = AppScope.of(context).study.systemPlan;
    final wasOpen = view.plan.open;
    try {
      final result = wasOpen
          ? await service.pause(widget.planId)
          : await service.resume(widget.planId);
      if (!mounted) return;
      final commitId = result.commitId;
      if (!result.changed || commitId == null) {
        _setNotice('计划状态没有变化。', failed: false);
        return;
      }
      showActionToast(
        context,
        wasOpen ? '已暂停这份计划，步骤与进度都保留。' : '已恢复这份计划。',
        label: '撤销',
        onPressed: () => undoCommitWithFeedback(context, commitId),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _setNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '修改学习计划状态',
          kind: 'study_plan_status',
          kept: '计划状态没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveView<StudyPlanScreen>(
      stream: _stream,
      onData: _onScreen,
      onError: _onReadError,
      builder: (context, data, loading) {
        final screen = data ?? _screen;
        if (screen != null) return _planBody(context, screen);
        final theme = context.zhixin;
        // 首读、找不到与读取失败都带同一条标题栏，读完标题不变，页面不跳。
        return DetailScaffold(
          header: const ZhixinHeader(title: Text('系统学习'), showBack: true),
          child: _readFailed
              ? Padding(
                  padding: theme.space.pageInsets(),
                  child: InlineNotice(
                    message: _notice ?? '暂时无法读取这份学习计划。',
                    onRetry: _retryRead,
                  ),
                )
              : loading
              ? Padding(
                  padding: theme.space.pageInsets(),
                  child: const ListSkeleton(rows: 3),
                )
              : _notFound(theme),
        );
      },
    );
  }

  Widget _notFound(ZhixinTheme theme) => Padding(
    padding: theme.space.pageInsets(),
    child: EmptyState(
      icon: FLucideIcons.route,
      title: '没有找到这份学习计划',
      description: '计划可能已经删除；可以回到安排页再打开一份。',
      action: forui.FButton(
        variant: forui.FButtonVariant.outline,
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.maybePop(context),
        child: const Text('返回安排'),
      ),
    ),
  );

  Widget _planBody(BuildContext context, StudyPlanScreen screen) {
    final theme = context.zhixin;
    final view = screen.view;
    final plan = view.plan;
    final current = view.currentStep;
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('系统学习'),
        showBack: true,
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.messageCircle,
            tooltip: '提出临时问题',
            onPressed: _temporary,
          ),
          ZhixinHeaderButton(
            label: plan.open ? '暂停计划' : '恢复计划',
            onPressed: _togglePause,
          ),
        ],
      ),
      child: ListView(
        padding: theme.space.pageInsets(),
        children: [
          _overviewCard(theme, plan),
          // 失败说明紧跟概览卡：哪一步操作失败都在同一屏上方看得到，
          // 不再落到整页最后一项。
          if (_notice != null)
            Padding(
              padding: EdgeInsets.only(top: theme.space.md),
              child: ResultNotice(
                message: _notice!,
                failed: _noticeFailed,
                onRetry: _readFailed ? _retryRead : null,
              ),
            ),
          if (current != null) ...[
            SizedBox(height: theme.space.md),
            _nextStepCard(theme, current),
          ],
          const SectionHeading(title: '全部步骤'),
          if (view.steps.isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: theme.space.sm),
              child: Text('这份计划还没有步骤。', style: theme.text.bodySmall),
            ),
          for (final step in view.steps) _stepRow(theme, screen, step),
        ],
      ),
    );
  }

  /// 概览卡：标题、状态与进度、材料与来源讨论。
  Widget _overviewCard(ZhixinTheme theme, StudyPlan plan) {
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.title, style: theme.text.titleMedium),
            SizedBox(height: theme.space.sm),
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
            if (plan.conversationId != null) ...[
              SizedBox(height: theme.space.sm),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                size: forui.FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: () => _openDiscussion(plan.conversationId!),
                prefix: const Icon(FLucideIcons.messageCircle),
                child: const Text('返回来源讨论'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 下一步卡：这一份计划只有一个主按钮，别的步骤不再各排三个同级按钮。
  Widget _nextStepCard(ZhixinTheme theme, PlanItem step) {
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TagRow(
              children: [
                const StatusTag('下一步', tone: TagTone.accent),
                if (step.pageLabel.isNotEmpty)
                  StatusTag(step.pageLabel, tone: TagTone.muted),
              ],
            ),
            SizedBox(height: theme.space.tight),
            Text(step.title, style: theme.text.titleMedium),
            if (step.note != null) ...[
              SizedBox(height: theme.space.xs),
              Text(step.note!, style: theme.text.bodySmall),
            ],
            SizedBox(height: theme.space.md),
            Row(
              children: [
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : () => _studyStep(step),
                  child: const Text('学这一步'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 全部步骤里的每一步：状态用标签，状态调整收进行尾菜单。
  Widget _stepRow(ZhixinTheme theme, StudyPlanScreen screen, PlanItem step) {
    final isCurrent = screen.view.currentStep?.id == step.id;
    final session = screen.sessions[step.id];
    final label = step.status == PlanItemStatus.todo ? '待学' : step.status.label;
    final details = <String>[
      if (step.done && step.completedAt != null)
        '完成于 ${shortTime(step.completedAt!)}',
      if (step.done && session != null)
        '这次学习：${shortTime(session.startedAt)}–'
            '${shortTime(session.endedAt ?? session.startedAt)}'
            '${session.outcomeLabel == null ? '' : ' · ${session.outcomeLabel}'}',
      if (step.done && (session?.summary?.trim().isNotEmpty ?? false))
        '困难：${session!.summary!.trim()}',
    ];
    final menuItems = <ZhixinMenuItem>[
      if (!step.done)
        ZhixinMenuItem(
          label: '学这一步',
          enabled: !_busy,
          onSelected: () => _studyStep(step),
        ),
      if (!step.done)
        ZhixinMenuItem(
          label: '完成这一步',
          onSelected: () => _mark(step, PlanItemStatus.done),
        ),
      if (step.done)
        ZhixinMenuItem(
          label: '恢复为待学习',
          onSelected: () => _mark(step, PlanItemStatus.todo),
        ),
    ];
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FTile(
        prefix: LeadingIcon(
          step.done
              ? FLucideIcons.circleCheck
              : isCurrent
              ? FLucideIcons.play
              : FLucideIcons.circle,
          tone: step.done
              ? TagTone.muted
              : isCurrent
              ? TagTone.accent
              : TagTone.neutral,
          size: 32,
        ),
        title: Text('第 ${step.seq ?? 1} 步 · ${step.title}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: theme.space.xs),
            TagRow(
              children: [
                StatusTag(
                  label,
                  tone: step.done
                      ? TagTone.muted
                      : isCurrent
                      ? TagTone.accent
                      : TagTone.neutral,
                ),
                if (step.pageLabel.isNotEmpty)
                  StatusTag(step.pageLabel, tone: TagTone.muted),
              ],
            ),
            if (step.note != null && step.note!.trim().isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(step.note!, style: theme.text.bodySmall),
              ),
            for (final detail in details)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs / 2),
                child: Text(detail, style: theme.text.bodySmall),
              ),
          ],
        ),
        suffix: menuItems.isEmpty
            ? null
            : moreMenu(items: menuItems, label: '第 ${step.seq ?? 1} 步的更多操作'),
      ),
    );
  }
}
