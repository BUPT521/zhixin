import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_proposal_service.dart';
import '../domain/models/question.dart';
import 'failure_feedback.dart';
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
  List<QuestionRow> _questions = const [];
  List<MemoryProposal> _proposals = const [];
  List<String> _notes = const [];
  List<String> _skipped = const [];
  QuestionRow? _current;
  bool _loading = true;
  bool _busy = false;
  String? _notice;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库与设置，等依赖就绪后再读一次。
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final scope = AppScope.of(context);
      final questions = await scope.conversations.questionRows(limit: 20);
      if (!mounted) return;
      setState(() {
        _questions = questions;
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
          action: '读取有作答的记录',
          kind: 'memory_proposal',
          kept: '已经保存的记录没有改动',
          next: '可以稍后再试',
        );
      });
    }
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
      final commitId = await AppScope.of(context).memory.proposals
          .accept(proposal);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _proposals = _proposals
            .where((item) => item.id != proposal.id)
            .toList(growable: false);
        _notes = const [];
      });
      if (commitId == null) {
        showToast(context, '这条来源已经处理过，没有重复写入。');
        return;
      }
      showActionToast(
        context,
        '已记下这条记忆',
        label: '撤销',
        onPressed: () =>
            undoCommitWithFeedback(context, commitId, reload: _reload),
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
      child: _loading
          ? const Center(child: forui.FCircularProgress())
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
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _notice!,
                      style: TextStyle(color: theme.colors.error),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('最近有作答的记录', style: theme.text.titleSmall),
                for (final row in _questions)
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
    );
  }
}
