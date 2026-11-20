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
///
/// 页码与讨论历史在对话框里读取：点开对话框就有反馈，读完再填页码与来源，
/// 不在打开之前空等一段。
Future<void> showStudyPlanSetup(
  BuildContext context, {
  required Material material,
  String? conversationId,
  int? initialPage,
}) async {
  final scope = AppScope.of(context);
  final result = await showZhixinDialog<_PlanSetupResult>(
    context: context,
    builder: (_) => _PlanSetupDialog(
      material: material,
      initialPage: initialPage,
      conversationId: conversationId,
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
    this.initialPage,
    this.conversationId,
  });

  final Material material;
  final int? initialPage;
  final String? conversationId;

  @override
  State<_PlanSetupDialog> createState() => _PlanSetupDialogState();
}

class _PlanSetupDialogState extends State<_PlanSetupDialog> {
  final _from = TextEditingController();
  final _to = TextEditingController();

  /// 材料实际可选的页码；读完之前为空。
  int? _firstPage;
  int? _lastPage;

  /// 从已有讨论带过来的最近几轮文字，作为生成顺序的上下文。
  String? _conversationFocus;

  StudyPlanProposal? _proposal;
  ({int from, int to})? _proposedRange;
  bool _loading = false;
  bool _reading = true;
  String? _notice;
  bool _started = false;

  /// 页码与片段在文件名与提示里的说法不同，统一从这里取。
  String get _unit => widget.material.isDocx ? '片段' : '页';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _read();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  /// 读取可选页码与讨论焦点：打开对话框之后立刻开始，读完再填表单。
  Future<void> _read() async {
    setState(() {
      _reading = true;
      _notice = null;
    });
    try {
      final scope = AppScope.of(context);
      final bounds = await scope.library.material.pageBounds(
        widget.material.id,
      );
      var focus = '';
      final conversationId = widget.conversationId;
      if (conversationId != null) {
        final messages = await scope.chat.discussion.history(conversationId);
        focus = selectBuddyHistory(messages)
            .map(
              (message) =>
                  '${message.role == MessageRole.user ? '用户' : buddyName}：${message.content.trim()}',
            )
            .join('\n');
      }
      if (!mounted) return;
      final firstPage = bounds.first;
      final lastPage = bounds.last;
      if (firstPage == null || lastPage == null) {
        setState(() {
          _reading = false;
          _firstPage = null;
          _lastPage = null;
          _notice = '这份材料还没有页码和原文；补充原文后可以建立学习顺序。';
        });
        return;
      }
      setState(() {
        _reading = false;
        _firstPage = firstPage;
        _lastPage = lastPage;
        _conversationFocus = focus.isEmpty ? null : focus;
        final start = (widget.initialPage ?? firstPage).clamp(
          firstPage,
          lastPage,
        );
        _from.text = '$start';
        _to.text = '$lastPage';
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取材料页码',
          kind: 'study_plan_setup_read',
          kept: '计划还没有开始建立',
          next: '可以点「重试」再读一次',
        );
      });
    }
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
    final firstPage = _firstPage;
    final lastPage = _lastPage;
    if (firstPage == null || lastPage == null) return;
    final from = int.tryParse(_from.text.trim()) ?? 0;
    final to = int.tryParse(_to.text.trim()) ?? 0;
    if (from < firstPage || to > lastPage || to < from) {
      setState(
        () => _notice =
            '页码范围无效：$_unit 应在 $firstPage–$lastPage 之间，'
            '且结束$_unit不早于起始$_unit。',
      );
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
        conversationFocus: _conversationFocus,
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
    final firstPage = _firstPage;
    final lastPage = _lastPage;
    final ready = !_reading && firstPage != null && lastPage != null;
    final canSave =
        ready &&
        !_loading &&
        steps.isNotEmpty &&
        _proposedRange?.from == int.tryParse(_from.text.trim()) &&
        _proposedRange?.to == int.tryParse(_to.text.trim());
    return ZhixinDialogLayout(
      title: Text('系统学习《${widget.material.title}》'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_reading)
            Padding(
              padding: EdgeInsets.symmetric(vertical: theme.space.xl),
              child: const forui.FProgress(),
            )
          else if (!ready)
            InlineNotice(message: _notice ?? '这份材料还没有页码和原文。', onRetry: _read)
          else ...[
            Text(
              widget.material.isDocx
                  ? '可选第 $firstPage–$lastPage 个片段；先生成顺序，确认后保存。'
                  : '可选第 $firstPage–$lastPage 页；先生成顺序，确认后保存。',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(height: theme.space.gap),
            // 两个范围框等分一行：页码范围一眼能看出是同一组。
            Row(
              children: [
                Expanded(
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
                SizedBox(width: theme.space.md),
                Expanded(
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
              ],
            ),
            SizedBox(height: theme.space.gap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: _loading ? null : _propose,
                child: const Text('生成顺序'),
              ),
            ),
            if (_notice != null)
              Padding(
                padding: EdgeInsets.only(top: theme.space.sm),
                child: InlineNotice(message: _notice!),
              ),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: theme.space.lg),
                child: const forui.FProgress(),
              ),
            if (steps.isNotEmpty) ...[
              SizedBox(height: theme.space.md),
              Text('确认后保存学习顺序', style: theme.text.labelMedium),
              if (proposal != null)
                Text(
                  '来源：${proposal.source.label(isDocx: widget.material.isDocx)}'
                  ' · 覆盖本次所选 ${proposal.pageCount} '
                  '${widget.material.isDocx ? '个片段' : '页'}',
                  style: theme.text.bodySmall,
                ),
              if (notice != null)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs / 2),
                  child: Text(notice, style: theme.text.bodySmall),
                ),
              for (var index = 0; index < steps.length; index++)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.tight),
                  child: forui.FTile(
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
                ),
            ],
          ],
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: canSave
              ? () => Navigator.of(context).pop(
                  _PlanSetupResult(
                    pageFrom: int.tryParse(_from.text.trim()) ?? 1,
                    pageTo: int.tryParse(_to.text.trim()) ?? 1,
                    steps: steps,
                  ),
                )
              : null,
          child: const Text('保存计划'),
        ),
      ],
    );
  }
}
