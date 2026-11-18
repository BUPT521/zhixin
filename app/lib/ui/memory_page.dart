import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_service.dart';
import '../domain/models/memory.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'memory_actions.dart';
import 'navigation.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: ZhixinHeader(
        title: const Text('记忆'),
        showBack: true,
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.search,
            tooltip: '查找记忆',
            onPressed: () => openMemorySearch(context),
          ),
          ZhixinHeaderAction(
            icon: FLucideIcons.plus,
            tooltip: '添加记忆',
            onPressed: () => addMemory(context),
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
                  onPress: () => addMemory(context),
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
                onSelected: () => restoreMemory(context, memory),
              ),
            ZhixinMenuItem(
              label: '修改',
              onSelected: () => editMemory(context, memory),
            ),
            ZhixinMenuItem(
              label: '删除',
              onSelected: () => deleteMemory(context, memory, scopeLabels),
            ),
          ],
        ),
      ),
    );
  }
}
