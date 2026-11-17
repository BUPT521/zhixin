import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_service.dart';
import '../domain/models/memory.dart';
import 'copy.dart';
import 'date_time_dialogs.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_select.dart';
import 'zhixin_toast.dart';

/// 记忆：搭子记得什么，可改、可删、可补一条。
///
/// 有效条目按偏好、限制、困难、进展四类分组；过期的仍留在原来那一类里并标
/// 「已过期」，可以延长有效期或删除。已删除与被取代的条目不在这里出现，追溯
/// 走数据版本页。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  /// 记忆页一屏的订阅：记忆条目与范围名字一起读回（ADR-0014）。
  ///
  /// 保存、删除与撤销之后的重新读取都由数据层完成，页面不再自己重读。
  Stream<MemoryPageView>? _stream;

  /// 读取失败时就地说明；有内容时仍显示上一份结果。
  String? _notice;

  /// 四个类型分组的顺序与 §3.6 一致。
  static const List<MemoryKind> _kinds = [
    MemoryKind.preference,
    MemoryKind.constraint,
    MemoryKind.difficulty,
    MemoryKind.progress,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库，等依赖就绪之后再订阅。
    _stream ??= AppScope.of(context).memory.edit.watchMemories();
  }

  void _onReadError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取记忆',
      kind: 'memory_read',
      kept: '屏幕上已经显示的记忆保持不变',
      next: '可以点重试再读一次',
    );
    setState(() => _notice = message);
  }

  /// 读取失败后的重试：换一条新流，读到结果之前保留已经显示的条目。
  void _reload() {
    setState(() {
      _notice = null;
      _stream = AppScope.of(context).memory.edit.watchMemories();
    });
  }

  void _clearNotice() {
    if (_notice == null) return;
    setState(() => _notice = null);
  }

  Future<void> _add() async {
    final draft = await showZhixinDialog<_MemoryDraft>(
      context: context,
      builder: (_) => const _MemoryDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      final result = await AppScope.of(context).memory.edit.add(
        kind: draft.kind,
        content: draft.content,
        validUntil: draft.validUntil,
      );
      if (!mounted || !result.changed) return;
      _receipt('已记下这条记忆', result.commitId!);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '保存这条记忆',
        kind: 'memory_add',
        kept: '记忆没有写入',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  Future<void> _edit(Memory memory) async {
    final draft = await showZhixinDialog<_MemoryDraft>(
      context: context,
      builder: (_) => _MemoryDialog(memory: memory),
    );
    if (draft == null || !mounted) return;
    try {
      final result = await AppScope.of(context).memory.edit.save(
        memory,
        kind: draft.kind,
        content: draft.content,
        validUntil: draft.validUntil,
      );
      if (!mounted) return;
      if (!result.changed) {
        showToast(context, result.skippedReason ?? '这条记忆没有变化。');
        return;
      }
      _receipt('已修改这条记忆', result.commitId!);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '修改这条记忆',
        kind: 'memory_edit',
        kept: '记忆仍是修改前的内容',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  Future<void> _delete(Memory memory, Map<String, String> scopeLabels) async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除这条记忆',
      content: Text('${_deleteImpact(memory, scopeLabels)}“${memory.content}”'),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await AppScope.of(context).memory.edit.delete(memory.id);
      if (!mounted || !result.changed) return;
      _receipt('已删除这条记忆', result.commitId!);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '删除这条记忆',
        kind: 'memory_delete',
        kept: '这条记忆还在',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  /// 过期条目可以手动恢复：选一个新的有效期，写回之后重新参与检索。
  Future<void> _restore(Memory memory) async {
    final now = AppScope.of(context).timePolicy.now;
    final picked = await showZhixinDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 10, now.month, now.day),
    );
    if (picked == null || !mounted) return;
    try {
      final result = await AppScope.of(context).memory.edit.save(
        memory,
        kind: memory.kind,
        content: memory.content,
        validUntil: picked,
      );
      if (!mounted) return;
      if (!result.changed) {
        showToast(context, result.skippedReason ?? '这条记忆没有变化。');
        return;
      }
      _receipt('已恢复这条记忆', result.commitId!);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '恢复这条记忆',
        kind: 'memory_restore',
        kept: '这条记忆仍是过期的状态',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  /// 删除前说明会影响哪些建议：按类型说清不再被参考的内容，按范围说清影响面。
  String _deleteImpact(Memory memory, Map<String, String> scopeLabels) {
    final scope = memory.scope;
    final place = scope == null
        ? '全部学习里'
        : '「${scopeLabels[scope] ?? '范围已删除'}」下';
    final effect = switch (memory.kind) {
      MemoryKind.preference => '讲解与建议不再参考这条偏好',
      MemoryKind.constraint => '回答不再按这条限制安排',
      MemoryKind.difficulty => '讲解不再针对这类困难',
      MemoryKind.progress => '安排不再参考这条进展',
      MemoryKind.unknown => '后续回答不再使用这条记忆',
    };
    return '删除后，$place的$effect。';
  }

  /// 保存、删除与恢复的提示条指向各自提交；撤销按反向规则写回并追加撤销提交。
  void _receipt(String message, int commitId) {
    showActionToast(
      context,
      message,
      label: '撤销',
      onPressed: () => _undo(commitId),
    );
  }

  /// 撤销写回之后的重读由订阅完成，这里不再手动刷新列表。
  Future<void> _undo(int commitId) => undoCommitWithFeedback(context, commitId);

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('记忆'),
        showBack: true,
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.plus,
            tooltip: '添加记忆',
            onPressed: _add,
          ),
        ],
      ),
      child: LiveView<MemoryPageView>(
        stream: _stream,
        onError: _onReadError,
        onData: (_) => _clearNotice(),
        builder: (context, view, loading) => ListView(
          padding: theme.space.pageInsets(),
          children: [
            if (_notice != null)
              InlineNotice(message: _notice!, onRetry: _reload),
            if (loading)
              const ListSkeleton(rows: 3)
            else
              ..._sections(theme, view!, AppScope.of(context).timePolicy.now),
          ],
        ),
      ),
    );
  }

  /// 按类型分组列出有效条目；过期的留在本组末尾并标出，已停用的只在页尾留一句。
  List<Widget> _sections(ZhixinTheme theme, MemoryPageView view, DateTime now) {
    final memories = view.memories;
    final active = memories.where((memory) => memory.active).toList();
    final inactive = memories.where((memory) => !memory.active).toList();
    if (memories.isEmpty) {
      return [
        forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.brain,
            title: emptyMemory,
            description:
                '搭子会在使用中逐步记住你的偏好与卡住的地方，'
                '例如“先给提示，再看完整解答”。',
            action: Wrap(
              spacing: theme.space.sm,
              runSpacing: theme.space.sm,
              alignment: WrapAlignment.center,
              children: [
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: _add,
                  prefix: const Icon(FLucideIcons.plus),
                  child: const Text('添加记忆'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => openMemoryProposal(context),
                  child: const Text('从作答整理'),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    final groups = <MemoryKind, List<Memory>>{};
    for (final memory in active) {
      groups.putIfAbsent(memory.kind, () => []).add(memory);
    }

    final children = <Widget>[];
    var first = true;
    for (final kind in _kinds) {
      final group = groups[kind];
      if (group == null || group.isEmpty) continue;
      children.add(
        SectionHeading(
          title: kind.label,
          first: first,
          action: first
              ? ZhixinHeaderButton(
                  label: '从作答整理',
                  onPressed: () => openMemoryProposal(context),
                )
              : null,
        ),
      );
      // 有效条目在前，过期的排在本组末尾并带「已过期」标签。
      for (final memory in group.where((memory) => memory.isValidAt(now))) {
        children.add(_tile(theme, memory, view.scopeLabels, now));
      }
      for (final memory in group.where((memory) => !memory.isValidAt(now))) {
        children.add(_tile(theme, memory, view.scopeLabels, now));
      }
      first = false;
    }

    final unknown = groups[MemoryKind.unknown];
    if (unknown != null && unknown.isNotEmpty) {
      children.add(
        SectionHeading(title: MemoryKind.unknown.label, first: first),
      );
      for (final memory in unknown) {
        children.add(_tile(theme, memory, view.scopeLabels, now));
      }
    }

    if (inactive.isNotEmpty) {
      children.add(
        Padding(
          padding: EdgeInsets.only(top: theme.space.sectionTop),
          child: Text(
            '已删除的记忆可在数据版本里查看。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return children;
  }

  Widget _tile(
    ZhixinTheme theme,
    Memory memory,
    Map<String, String> scopeLabels,
    DateTime now,
  ) {
    final expired = !memory.isValidAt(now);
    final scope = memory.scope == null
        ? null
        : scopeLabels[memory.scope] ?? '范围已删除';
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        title: Text(memory.content),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: theme.space.tight),
            TagRow(
              children: [
                StatusTag(memory.kind.label),
                StatusTag(
                  memory.sourceLabel,
                  tone: memory.fromModel ? TagTone.attention : TagTone.neutral,
                ),
                if (expired) const StatusTag('已过期', tone: TagTone.muted),
              ],
            ),
            SizedBox(height: theme.space.xs),
            Text(
              ['有效期：${memory.validLabel}', ?scope].join(' · '),
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        suffix: moreMenu(
          items: [
            if (expired)
              ZhixinMenuItem(
                label: '恢复（延长有效期）',
                onSelected: () => _restore(memory),
              ),
            ZhixinMenuItem(label: '修改', onSelected: () => _edit(memory)),
            ZhixinMenuItem(
              label: '删除',
              onSelected: () => _delete(memory, scopeLabels),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryDraft {
  const _MemoryDraft({
    required this.kind,
    required this.content,
    this.validUntil,
  });

  final MemoryKind kind;
  final String content;
  final DateTime? validUntil;
}

class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({this.memory});

  final Memory? memory;

  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  late MemoryKind _kind = widget.memory?.kind ?? MemoryKind.preference;
  late final TextEditingController _content = TextEditingController(
    text: widget.memory?.content ?? '',
  );
  DateTime? _until;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _until = widget.memory?.validUntil;
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _pickUntil() async {
    final now = AppScope.of(context).timePolicy.now;
    final picked = await showZhixinDatePicker(
      context: context,
      initialDate: _until != null && _until!.isBefore(now)
          ? now
          : _until ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 10, now.month, now.day),
    );
    if (mounted && picked != null) setState(() => _until = picked);
  }

  void _save() {
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _contentError = '先写一句要记住的内容再保存。');
      return;
    }
    Navigator.of(context)
        .pop(_MemoryDraft(kind: _kind, content: content, validUntil: _until));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: Text(widget.memory == null ? '记一条' : '修改记忆'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZhixinSelect<MemoryKind>(
            value: _kind,
            label: '类型',
            options: {
              for (final kind in MemoryKind.values)
                if (kind != MemoryKind.unknown) kind: kind.label,
            },
            onChange: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(
              controller: _content,
              onChange: (_) {
                if (_contentError != null) {
                  setState(() => _contentError = null);
                }
              },
            ),
            minLines: 2,
            maxLines: 4,
            label: const Text('内容'),
          ),
          if (_contentError != null)
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Text(
                _contentError!,
                style: theme.text.bodySmall.copyWith(color: theme.colors.error),
              ),
            ),
          SizedBox(height: theme.space.gap),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有效期',
                style: theme.text.labelMedium.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              SizedBox(height: theme.space.xs),
              Wrap(
                spacing: theme.space.xs,
                runSpacing: theme.space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _pickUntil,
                    prefix: const Icon(FLucideIcons.calendarDays, size: 16),
                    child: Text(
                      _until == null ? '长期有效' : '有效至 ${dateText(_until)}',
                    ),
                  ),
                  if (_until != null)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => setState(() => _until = null),
                      child: const Text('改回长期'),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
