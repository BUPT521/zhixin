import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/memory.dart';
import 'date_time_dialogs.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'memory_proposal_page.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_select.dart';
import 'zhixin_toast.dart';

/// 记忆：搭子记得什么，可改、可删、可补一条。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  List<Memory> _memories = const [];
  Map<String, String> _scopeLabels = const {};
  bool _loading = true;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final app = AppScope.of(context);
      final memories = await app.memory.edit.list();
      final goals = await app.tasks.goals();
      final materials = await app.library.material.list();
      if (!mounted) return;
      // 结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _memories = memories;
        _scopeLabels = {
          for (final goal in goals)
            memoryGoalScope(goal.id): '目标：${goal.title}',
          for (final material in materials)
            memoryMaterialScope(material.id): '材料：${material.title}',
        };
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _loading = false);
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取记忆',
        kind: 'memory_read',
        kept: '本机记忆没有改动',
        next: '可以返回再打开',
      );
      showToast(context, message);
    }
  }

  Future<void> _add() async {
    final draft = await showZhixinDialog<_MemoryDraft>(
      context: context,
      builder: (_) => const _MemoryDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      final commitId = await AppScope.of(context).memory.edit.add(
        kind: draft.kind,
        content: draft.content,
        validUntil: draft.validUntil,
      );
      await _load();
      if (!mounted || commitId == null) return;
      _receipt('已记下这条记忆', commitId);
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
      final commitId = await AppScope.of(context).memory.edit
          .save(memory, content: draft.content, validUntil: draft.validUntil);
      await _load();
      if (!mounted) return;
      if (commitId == null) {
        showToast(context, '这条记忆没有变化。');
        return;
      }
      _receipt('已修改这条记忆', commitId);
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

  Future<void> _delete(Memory memory) async {
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '删除这条记忆',
      content: Text('删除后，后续回答将不再使用这条记忆：“${memory.content}”'),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    try {
      final commitId = await AppScope.of(context).memory.edit.delete(memory.id);
      await _load();
      if (!mounted || commitId == null) return;
      _receipt('已删除这条记忆', commitId);
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

  /// 保存与删除的提示条指向各自提交；撤销按反向规则写回并追加撤销提交。
  void _receipt(String message, int commitId) {
    showActionToast(
      context,
      message,
      label: '撤销',
      onPressed: () => _undo(commitId),
    );
  }

  Future<void> _undo(int commitId) =>
      undoCommitWithFeedback(context, commitId, reload: _load);

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final now = AppScope.of(context).timePolicy.now;
    final active = _memories.where((memory) => memory.isValidAt(now)).toList();
    final expired = _memories
        .where((memory) => memory.active && !memory.isValidAt(now))
        .toList();
    final inactive = _memories.where((memory) => !memory.active).toList();
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('记忆'),
        showBack: true,
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.listChecks,
            tooltip: '从作答整理',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MemoryProposalPage(),
              ),
            ),
          ),
        ],
      ),
      child: Stack(
        children: [
          _loading
              ? const Center(child: forui.FCircularProgress())
              : ListView(
                  padding: theme.space.pageInsets(bottom: 96),
                  children: [
                    Text(
                      '这些记忆用于关联学习背景；修改后使用新内容，删除后停止使用。',
                      style: theme.text.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_memories.isEmpty)
                      const forui.FCard(
                        child: EmptyState(
                          icon: FLucideIcons.brain,
                          title: '暂无学习记忆',
                          description: '可以添加一条学习偏好，例如“先给提示，再看完整解答”。',
                        ),
                      ),
                    for (final memory in active) _tile(theme, memory),
                    if (expired.isNotEmpty) ...[
                      const SectionHeading(
                        title: '已过期',
                        subtitle: '有效期已结束，你仍可修改或删除。',
                      ),
                      for (final memory in expired) _tile(theme, memory),
                    ],
                    if (inactive.isNotEmpty) ...[
                      const SectionHeading(title: '已停用'),
                      for (final memory in inactive) _tile(theme, memory),
                    ],
                  ],
                ),
          Align(
            alignment: Alignment.bottomRight,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: _add,
                  prefix: const Icon(FLucideIcons.plus),
                  child: const Text('添加记忆'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ZhixinTheme theme, Memory memory) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: forui.FTile(
        title: Text(memory.content),
        subtitle: Text(
          '${memory.kind.label} · ${memory.sourceLabel} · ${memory.validLabel}'
          '${memory.scope == null ? '' : ' · ${_scopeLabels[memory.scope] ?? '范围已删除'}'}',
        ),
        suffix: moreMenu(
          items: [
            ZhixinMenuItem(label: '修改', onSelected: () => _edit(memory)),
            ZhixinMenuItem(label: '删除', onSelected: () => _delete(memory)),
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

  @override
  Widget build(BuildContext context) {
    return ZhixinDialogLayout(
      title: Text(widget.memory == null ? '记一条' : '修改记忆'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ZhixinSelect<MemoryKind>(
            value: _kind,
            label: '类型',
            options: {for (final kind in MemoryKind.values) kind: kind.label},
            onChange: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: _content),
            minLines: 2,
            maxLines: 4,
            label: const Text('内容'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final now = AppScope.of(context).timePolicy.now;
                  final picked = await showZhixinDatePicker(
                    context: context,
                    initialDate: _until != null && _until!.isBefore(now)
                        ? now
                        : _until ?? now,
                    firstDate: now,
                    lastDate: DateTime(now.year + 10, now.month, now.day),
                  );
                  if (context.mounted && picked != null) {
                    setState(() => _until = picked);
                  }
                },
                child: Text(
                  _until == null ? '长期有效' : '有效至 ${dateText(_until)}',
                ),
              ),
              if (_until != null)
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() => _until = null),
                  child: const Text('改回长期'),
                ),
            ],
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
          onPress: () {
            final content = _content.text.trim();
            if (content.isEmpty) return;
            Navigator.of(context).pop(
              _MemoryDraft(kind: _kind, content: content, validUntil: _until),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
