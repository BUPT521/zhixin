import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_proposal_service.dart';
import '../domain/models/question.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'memory_actions.dart';
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

  /// 适用范围标识到显示名的对应；与记忆页同一份解析，取自记忆页的读法。
  Map<String, String>? _scopeLabels;

  List<MemoryProposal> _proposals = const [];
  List<String> _notes = const [];
  List<String> _skipped = const [];
  QuestionRow? _current;
  bool _busy = false;

  /// 处理提案失败时就地说明；读取记录的失败单独一条，显示在列表上方。
  String? _actionNotice;
  String? _readNotice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库，等依赖就绪之后再订阅。
    _stream ??= AppScope.of(context).memory.proposals.watchQuestions();
    if (_scopeLabels == null) unawaited(_loadScopeLabels());
  }

  /// 读回目标与材料的标题：提案里的范围只存标识，显示时换成用户认得的名字。
  ///
  /// 读不到时退回通用说法，不影响提案本身；两个入口都只读，不改任何数据。
  Future<void> _loadScopeLabels() async {
    await AppScope.of(context).memory.edit.loadPage().then(
      (view) {
        if (!mounted) return;
        setState(() => _scopeLabels = view.scopeLabels);
      },
      onError: (Object error, StackTrace stack) {
        // 范围名字只是补充说明，读不到时显示通用说法。
      },
    );
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
      next: '可以点重试再读一次',
    );
    setState(() => _readNotice = message);
  }

  void _clearReadNotice() {
    if (_readNotice == null) return;
    setState(() => _readNotice = null);
  }

  /// 读取失败后的重试：换一条新流，读到结果之前保留已经显示的记录。
  void _reloadQuestions() {
    setState(() {
      _readNotice = null;
      _stream = AppScope.of(context).memory.proposals.watchQuestions();
    });
  }

  Future<void> _propose(QuestionRow row) async {
    setState(() {
      _busy = true;
      _actionNotice = null;
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
        _actionNotice = describeFailure(
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
      showMemoryReceipt(context, '已记下这条记忆', result.commitId!, reload: _reload);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _actionNotice = describeFailure(
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

  bool _isCurrent(QuestionRow row) =>
      _current?.question.conversationId == row.question.conversationId;

  /// 范围标识换成目标名或材料名；两者都没有时写明用于全部学习。
  String _scopeLabel(String? scope) {
    if (scope == null) return '全部学习';
    final labels = _scopeLabels;
    if (labels == null) return '所属目标或材料';
    return memoryScopeLabel(labels, scope);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('从作答整理记忆'), showBack: true),
      child: LiveView<List<QuestionRow>>(
        stream: _stream,
        onError: _onReadError,
        onData: (_) => _clearReadNotice(),
        builder: (context, questions, loading) {
          if (loading) {
            return ListView(
              padding: theme.space.pageInsets(),
              children: [
                if (_readNotice != null)
                  InlineNotice(
                    message: _readNotice!,
                    onRetry: _reloadQuestions,
                  ),
                const ListSkeleton(rows: 3),
              ],
            );
          }
          final rows = questions ?? const <QuestionRow>[];
          if (rows.isEmpty) {
            return ListView(
              padding: theme.space.pageInsets(),
              children: [
                if (_readNotice != null)
                  InlineNotice(
                    message: _readNotice!,
                    onRetry: _reloadQuestions,
                  ),
                const EmptyState(
                  icon: FLucideIcons.listChecks,
                  title: '还没有可以整理的作答',
                  description: '提交一次作答之后，这里会列出可以从这次作答里记下什么的记录。',
                ),
              ],
            );
          }
          return ListView(
            padding: theme.space.pageInsets(),
            children: [
              const SectionHeading(
                title: '最近有作答的记录',
                subtitle:
                    '用过提示后做错的、或隔一段时间独立完成的，才会提出可以记下的记忆；'
                    '确认之后写入，也能撤销。',
                first: true,
              ),
              if (_readNotice != null)
                InlineNotice(message: _readNotice!, onRetry: _reloadQuestions),
              for (final row in rows) ...[
                _rowTile(theme, row),
                ExpandReveal(
                  visible: _isCurrent(row),
                  child: _proposalBlock(theme),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _rowTile(ZhixinTheme theme, QuestionRow row) {
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        title: Text(
          row.question.displayStem,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            if (row.question.sourceRef != null) row.question.sourceRef!,
            row.lastAttempt?.judgmentLabel ?? '未判断',
          ].join(' · '),
        ),
        suffix: const Icon(FLucideIcons.chevronRight),
        selected: _isCurrent(row),
        enabled: !_busy,
        onPress: () => _propose(row),
      ),
    );
  }

  /// 整理结果紧接在被点记录下方展开，用户不必把整页滚到底。
  Widget _proposalBlock(ZhixinTheme theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.md,
        theme.space.sm,
        0,
        theme.space.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy)
            const ListSkeleton(rows: 2, rowHeight: 64)
          else ...[
            if (_actionNotice != null) InlineNotice(message: _actionNotice!),
            if (_proposals.isEmpty && _notes.isEmpty && _skipped.isEmpty)
              Text(
                '这次没有可以记下的判断。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            for (final proposal in _proposals) _proposalCard(theme, proposal),
            for (final note in _notes)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(
                  note,
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ),
            for (final skipped in _skipped)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
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

  Widget _proposalCard(ZhixinTheme theme, MemoryProposal proposal) {
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TagRow(
                children: [
                  StatusTag(proposal.kind.label, tone: TagTone.accent),
                  StatusTag(_scopeLabel(proposal.scope)),
                ],
              ),
              SizedBox(height: theme.space.xs),
              Text(proposal.content, style: theme.text.bodyMedium),
              SizedBox(height: theme.space.xs),
              Text(
                '来源：${proposal.sourceLabel}',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              Text(
                '依据：${proposal.basis}',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy
                        ? null
                        : () => setState(() {
                            _proposals = _proposals
                                .where((item) => item.id != proposal.id)
                                .toList(growable: false);
                          }),
                    child: const Text('这次不记'),
                  ),
                  SizedBox(width: theme.space.xs),
                  forui.FButton(
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : () => _accept(proposal),
                    child: const Text('记下'),
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
