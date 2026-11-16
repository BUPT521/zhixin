import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_proposal_service.dart';
import '../domain/models/question.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'undo_feedback.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 从已提交作答整理记忆：列出最近有作答的记录，逐条查看提案再决定是否记下。
///
/// 提案带来源作答复核、适用范围与判断依据；确认之后走记忆页同一套提交与撤销，
/// 在提示条里可以撤回。这里只整理本机记录，不调用模型。
class MemoryProposalPage extends StatefulWidget {
  const MemoryProposalPage({super.key});

  @override
  State<MemoryProposalPage> createState() => _MemoryProposalPageState();
}

class _MemoryProposalPageState extends State<MemoryProposalPage> {
  /// 一屏订阅：最近有作答的记录随作答、判断与记忆的写入更新（ADR-0014）。
  ///
  /// 提案只在这一页按用户点选的那条记录提取，不随订阅变化；接受建议之后的
  /// 列表重读由数据层完成，页面不再自己重读。
  Stream<List<QuestionRow>>? _stream;

  List<MemoryProposal> _proposals = const [];
  List<String> _notes = const [];
  List<String> _skipped = const [];
  QuestionRow? _current;
  bool _busy = false;
  String? _notice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库，等依赖就绪之后再订阅。
    _stream ??= AppScope.of(context).memory.proposals.watchQuestions();
  }

  void _onReadError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取有作答的记录',
      kind: 'memory_proposal',
      kept: '屏幕上已经显示的记录保持不变',
      next: '可以稍后再打开这一页',
    );
    showToast(context, message);
  }

  Future<void> _propose(QuestionRow row) async {
    setState(() {
      _busy = true;
      _notice = null;
      _current = row;
    });
    try {
      final outcome = await AppScope.of(context).memory.proposals
          .propose(row.question.conversationId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _proposals = outcome.proposals;
        _notes = outcome.notes;
        _skipped = outcome.skipped;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '整理这次作答的记忆',
          kind: 'memory_proposal',
          kept: '已经保存的记录没有改动',
          next: '可以稍后再试',
        );
      });
    }
  }

  Future<void> _accept(MemoryProposal proposal) async {
    setState(() => _busy = true);
    try {
      final result = await AppScope.of(context).memory.proposals
          .accept(proposal);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _proposals = _proposals
            .where((item) => item.id != proposal.id)
            .toList(growable: false);
        _notes = const [];
      });
      if (!result.changed) {
        showToast(context, result.skippedReason ?? '这条来源已经处理过，没有重复写入。');
        return;
      }
      showActionToast(
        context,
        '已记下这条记忆',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, result.commitId!, reload: _reload),
      );
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '记下这条记忆',
          kind: 'memory_proposal',
          kept: '这条提案仍在待确认',
          next: '可以稍后再试',
        );
      });
    }
  }

  Future<void> _reload() async {
    final current = _current;
    if (current != null) await _propose(current);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('从作答整理记忆'), showBack: true),
      child: LiveView<List<QuestionRow>>(
        stream: _stream,
        onError: _onReadError,
        builder: (context, questions, loading) => loading
            ? const PageLoading()
            : ListView(
                padding: theme.space.pageInsets(),
                children: [
                  Text(
                    '从已提交作答整理可核对的记忆：只有用过提示后做错、或隔一段时间后独立完成'
                    '才会提出提案；在帮助下做对与独立性未说明只保留说明。确认后写入记忆，'
                    '可以从提示条或数据版本页撤销。',
                    style: theme.text.bodyMedium,
                  ),
                  if (_busy) const forui.FProgress(),
                  if (_notice != null) InlineNotice(message: _notice!),
                  SizedBox(height: context.zhixin.space.gap),
                  Text('最近有作答的记录', style: theme.text.titleSmall),
                  for (final row in questions!)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: forui.FTile(
                        title: Text(
                          row.question.displayStem,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (row.question.sourceRef != null)
                              row.question.sourceRef!,
                            row.lastAttempt?.judgmentLabel ?? '未判断',
                          ].join(' · '),
                        ),
                        suffix: const Icon(FLucideIcons.chevronRight),
                        onPress: () => _propose(row),
                      ),
                    ),
                  if (_current != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      '提案：${_current!.question.displayStem}',
                      style: theme.text.titleSmall,
                    ),
                    if (_proposals.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text('这次没有可以记下的判断。'),
                      ),
                    for (final proposal in _proposals)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: forui.FCard(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '[${proposal.kind.label}] ${proposal.content}',
                                  style: theme.text.bodyMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '来源：${proposal.sourceLabel}；'
                                  '范围：${proposal.scope ?? '全部学习'}',
                                  style: theme.text.bodySmall,
                                ),
                                Text(
                                  '依据：${proposal.basis}',
                                  style: theme.text.bodySmall,
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    forui.FButton(
                                      variant: forui.FButtonVariant.ghost,
                                      mainAxisSize: MainAxisSize.min,
                                      onPress: _busy
                                          ? null
                                          : () => setState(() {
                                              _proposals = _proposals
                                                  .where(
                                                    (item) =>
                                                        item.id != proposal.id,
                                                  )
                                                  .toList(growable: false);
                                            }),
                                      child: const Text('这次不记'),
                                    ),
                                    forui.FButton(
                                      mainAxisSize: MainAxisSize.min,
                                      onPress: _busy
                                          ? null
                                          : () => _accept(proposal),
                                      child: const Text('记下'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    for (final note in _notes)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(note, style: theme.text.bodySmall),
                      ),
                    for (final skipped in _skipped)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          skipped,
                          style: theme.text.bodySmall.copyWith(
                            color: theme.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}
