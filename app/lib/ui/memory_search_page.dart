import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_service.dart';
import '../application/request_gate.dart';
import '../domain/models/memory.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'memory_actions.dart';
import 'navigation.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_menu.dart';
import 'zhixin_select.dart';

/// 记忆查找：按正文、类别、适用范围与状态筛选，只查本机。
///
/// 结果沿用记忆页的卡片与操作：来源、有效期与状态一起展示，修改、删除与过期
/// 恢复走同一套弹窗与提交回执；默认只列有效与已过期的记忆，已删除的条目不在
/// 这里重新列出，追溯删除前的改动去数据版本页。查找不调用模型，也不改变回答
/// 时使用的记忆范围。
class MemorySearchPage extends StatefulWidget {
  const MemorySearchPage({super.key});

  @override
  State<MemorySearchPage> createState() => _MemorySearchPageState();
}

class _MemorySearchPageState extends State<MemorySearchPage> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final RequestGate _requests = RequestGate();

  MemoryKind? _kind;
  MemoryScopeFilter _scope = const MemoryScopeFilter.all();
  MemoryStatus _status = MemoryStatus.active;

  MemorySearchResults? _results;
  Map<String, String> _scopeLabels = const {};
  String? _notice;
  bool _loading = true;
  bool _loadingMore = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 范围选项要读应用根上的目标与材料；读不到时仍可按其他条件查找。
    unawaited(_loadScopeOptions());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_search());
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadScopeOptions() async {
    try {
      final view = await AppScope.of(context).memory.edit.loadPage();
      if (!mounted) return;
      setState(() => _scopeLabels = view.scopeLabels);
    } catch (_) {
      // 范围名字只是补充说明，读不到时不影响按正文、类别与状态查找。
    }
  }

  MemorySearchQuery get _queryCondition => MemorySearchQuery(
    text: _query.text,
    kind: _kind,
    scope: _scope,
    status: _status,
  );

  /// 取第一页。查询或筛选变化时换一个编号，晚到的旧结果直接丢弃。
  Future<void> _search() async {
    final query = _queryCondition;
    final requestId = _requests.start();
    if (query.status == MemoryStatus.deleted) {
      setState(() {
        _results = null;
        _notice = null;
        _loading = false;
        _loadingMore = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _notice = null;
    });
    try {
      final results = await AppScope.of(context).memory.edit.search(query);
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _results = results;
        _scopeLabels = results.scopeLabels;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '查找记忆',
          kind: 'memory_search',
          kept: '屏幕上已经显示的记忆保持不变',
          next: '可以点重试再找一次',
        );
      });
    }
  }

  /// 接着向后取一页；过滤与排序已经在前一页完成，这里只追加新的条目。
  Future<void> _loadMore() async {
    final results = _results;
    if (results == null || !results.hasMore || _loading || _loadingMore) return;
    final requestId = _requests.start();
    setState(() => _loadingMore = true);
    try {
      final next = await AppScope.of(context).memory.edit
          .search(results.query, offset: results.nextOffset);
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _results = results.append(next);
        _loadingMore = false;
      });
    } catch (error, stack) {
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _loadingMore = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '继续读取记忆查找结果',
          kind: 'memory_search_page',
          kept: '已经显示的记忆没有改动',
          next: '可以再点一次“加载更多结果”',
        );
      });
    }
  }

  /// 写入之后重取当前条件的第一页；撤销也从提示条走同一次重读。
  Future<void> _afterChange(Future<bool> Function() action) async {
    final changed = await action();
    if (!changed || !mounted) return;
    await _search();
  }

  void _resetFilters() {
    _query.clear();
    setState(() {
      _kind = null;
      _scope = const MemoryScopeFilter.all();
      _status = MemoryStatus.active;
      _notice = null;
    });
    unawaited(_search());
  }

  Map<MemoryKind, String> get _kindOptions => {
    MemoryKind.unknown: '全部类别',
    for (final kind in MemoryKind.values)
      if (kind != MemoryKind.unknown) kind: kind.label,
  };

  Map<MemoryStatus, String> get _statusOptions => const {
    MemoryStatus.active: '有效与已过期',
    MemoryStatus.deleted: '已删除',
  };

  Map<MemoryScopeFilter, String> get _scopeOptions => {
    const MemoryScopeFilter.all(): '全部范围',
    const MemoryScopeFilter.unscoped(): '全部学习（不限定范围）',
    for (final entry in _scopeLabels.entries)
      MemoryScopeFilter.scoped(entry.key): entry.value,
  };

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('查找记忆'), showBack: true),
      child: Column(
        children: [
          Padding(
            padding: theme.space.pageInsets(
              top: theme.space.sm,
              bottom: theme.space.xs,
            ),
            child: forui.FTextField(
              key: const ValueKey('memory-search-field'),
              control: .managed(
                controller: _query,
                onChange: (_) => unawaited(_search()),
              ),
              textInputAction: TextInputAction.search,
              onSubmit: (_) => _search(),
              hint: '搜索记忆正文',
            ),
          ),
          _filters(theme),
          if (_loading) const forui.FProgress(),
          if (_notice != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                0,
                theme.space.page,
                0,
              ),
              child: InlineNotice(message: _notice!, onRetry: _search),
            ),
          Expanded(child: _resultsArea(theme)),
        ],
      ),
    );
  }

  /// 类别与状态并排，适用范围单独一行：范围名字较长，和另外两个挤一行会截断。
  Widget _filters(ZhixinTheme theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.page,
        theme.space.xs,
        theme.space.page,
        0,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ZhixinSelect<MemoryKind>(
                  key: const ValueKey('memory-search-kind'),
                  value: _kind ?? MemoryKind.unknown,
                  label: '类别',
                  options: _kindOptions,
                  onChange: (value) {
                    setState(() {
                      _kind = value == null || value == MemoryKind.unknown
                          ? null
                          : value;
                    });
                    unawaited(_search());
                  },
                ),
              ),
              SizedBox(width: theme.space.sm),
              Expanded(
                child: ZhixinSelect<MemoryStatus>(
                  key: const ValueKey('memory-search-status'),
                  value: _status,
                  label: '状态',
                  options: _statusOptions,
                  onChange: (value) {
                    if (value == null || value == _status) return;
                    setState(() => _status = value);
                    unawaited(_search());
                  },
                ),
              ),
            ],
          ),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<MemoryScopeFilter>(
            key: const ValueKey('memory-search-scope'),
            value: _scope,
            label: '适用范围',
            options: _scopeOptions,
            onChange: (value) {
              if (value == null || value == _scope) return;
              setState(() => _scope = value);
              unawaited(_search());
            },
          ),
        ],
      ),
    );
  }

  Widget _resultsArea(ZhixinTheme theme) {
    if (_status == MemoryStatus.deleted) {
      return SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.trash2,
          title: '已删除的记忆不在这里重新列出',
          description: '需要追溯删除前的改动时，打开数据版本查看提交历史、字段变化与恢复入口。',
          action: Wrap(
            spacing: theme.space.sm,
            runSpacing: theme.space.sm,
            alignment: WrapAlignment.center,
            children: [
              forui.FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: () => openDataVersion(context),
                child: const Text('打开数据版本'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: _resetFilters,
                child: const Text('改回有效与已过期'),
              ),
            ],
          ),
        ),
      );
    }

    final results = _results;
    if (results == null) {
      if (_loading) return const ListSkeleton(rows: 3);
      return const SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.search,
          title: '输入要查找的文字',
          description: '可以按正文关键词、类别、适用范围与状态查找；查找只在本机完成，不调用模型。',
        ),
      );
    }

    if (results.isEmpty) {
      if (results.query.isDefault) {
        return SingleChildScrollView(
          child: EmptyState(
            icon: FLucideIcons.brain,
            title: emptyMemory,
            description: '搭子会在使用中逐步记住你的偏好与卡住的地方，例如“先给提示，再看完整解答”。',
          ),
        );
      }
      return SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.searchX,
          title: '没有找到符合条件的记忆',
          description: '可以换一个关键词，或清除筛选后查看有效与已过期的记忆。',
          action: forui.FButton(
            variant: forui.FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: _resetFilters,
            child: const Text('清除筛选'),
          ),
        ),
      );
    }

    final showEnd =
        !results.hasMore &&
        results.memories.length >= MemoryService.searchPageSize;
    return ListView(
      controller: _scroll,
      padding: theme.space.pageInsets(top: theme.space.xs),
      children: [
        if (results.query.isDefault)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.sm),
            child: Text(
              '没有输入关键词，先列出有效与已过期的记忆；输入关键词或选择筛选可以缩小范围。',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          )
        else
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.xs),
            child: Text(
              '共 ${results.matched} 条命中',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ),
        for (final memory in results.memories) _tile(theme, memory),
        if (results.hasMore)
          LoadMoreFooter(
            label: '加载更多结果',
            loading: _loadingMore,
            onPressed: _loadMore,
          )
        else if (showEnd)
          Padding(
            padding: EdgeInsets.only(top: theme.space.md),
            child: Center(child: Text('已经到最后一条', style: theme.text.bodySmall)),
          ),
      ],
    );
  }

  /// 一条结果：正文片段、类别、来源与来源对象、有效期、状态，以及原有编辑入口。
  Widget _tile(ZhixinTheme theme, Memory memory) {
    final expired = !memory.isValidAt(AppScope.of(context).timePolicy.now);
    final scope = memory.scope == null
        ? null
        : _scopeLabels[memory.scope] ?? '范围已删除';
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        title: Text(
          _snippet(memory.content, _queryCondition.text),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: theme.space.tight),
            TagRow(
              children: [
                StatusTag(memory.kind.label),
                StatusTag(
                  expired ? '已过期' : memory.status.label,
                  tone: expired ? TagTone.muted : TagTone.accent,
                ),
                StatusTag(
                  memory.sourceLabel,
                  tone: memory.fromModel ? TagTone.attention : TagTone.neutral,
                ),
              ],
            ),
            SizedBox(height: theme.space.xs),
            Text(
              '来源：${memory.sourceDetail}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
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
                onSelected: () => _afterChange(
                  () => restoreMemory(context, memory, reload: _search),
                ),
              ),
            ZhixinMenuItem(
              label: '修改',
              onSelected: () => _afterChange(
                () => editMemory(context, memory, reload: _search),
              ),
            ),
            ZhixinMenuItem(
              label: '删除',
              onSelected: () => _afterChange(
                () => deleteMemory(
                  context,
                  memory,
                  _scopeLabels,
                  reload: _search,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 正文片段：命中位置附近截一段，长内容也能看见关键词。
  String _snippet(String content, String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) return content;
    final index = content.toLowerCase().indexOf(query.toLowerCase());
    if (index < 0) return content;
    const radius = 60;
    final start = index > radius ? index - radius : 0;
    final end = index + query.length + radius < content.length
        ? index + query.length + radius
        : content.length;
    final text = content
        .substring(start, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${start > 0 ? '…' : ''}$text${end < content.length ? '…' : ''}';
  }
}
