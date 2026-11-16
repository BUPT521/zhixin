import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import '../ai/ai_chat_service.dart';
import '../app_scope.dart';
import '../application/study_plan_service.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/material.dart';
import '../domain/models/study_plan.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_toast.dart';

/// 从一份材料建立系统学习：选页码范围，提出顺序，确认后保存。
///
/// 从已有讨论开始时传入 `conversationId`，计划会保留原讨论标识；`initialPage`
/// 用当前页作为默认起点。计划页、材料页与讨论页都用这个入口，保存之后由
/// 导航入口打开新建的计划，页面不再各自构造路由。
Future<void> showStudyPlanSetup(
  BuildContext context, {
  required Material material,
  String? conversationId,
  int? initialPage,
}) async {
  final scope = AppScope.of(context);
  final bounds = await scope.library.material.pageBounds(material.id);
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
    final messages = await scope.chat.discussion.history(conversationId);
    final selected = selectBuddyHistory(messages);
    final focus = selected
        .map(
          (message) =>
              '${message.role == MessageRole.user ? '用户' : buddyName}：${message.content.trim()}',
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
    final view = await scope.study.systemPlan.createPlan(
      materialId: material.id,
      pageFrom: result.pageFrom,
      pageTo: result.pageTo,
      steps: result.steps,
      goalId: material.goalId,
      conversationId: conversationId,
    );
    if (!context.mounted) return;
    await openStudyPlan(context, view.plan.id);
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
      final proposal = await AppScope.of(context).study.systemPlan.propose(
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
          if (_notice != null) InlineNotice(message: _notice!),
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
