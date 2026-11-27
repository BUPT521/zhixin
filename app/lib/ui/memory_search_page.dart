import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/memory_service.dart';
import '../domain/models/memory.dart';
import 'copy.dart';
import 'failure_feedback.dart';
import 'memory_actions.dart';
import 'navigation.dart';
import 'search_state.dart';
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

  /// 本页的查找状态：请求序号、输入防抖、分页与结果都在这一份里。
  final SearchState<Memory> _matches = SearchState<Memory>();

  MemoryKind? _kind;
  MemoryScopeFilter _scope = const MemoryScopeFilter.all();
  MemoryStatus _status = MemoryStatus.active;

  /// 范围标识到显示名的对应与本次条件的命中总数：服务随每页一起给出，页面
  /// 只在取回结果时记下，用于条数与范围标签。
  Map<String, String> _scopeLabels = const {};
  int? _matched;

  /// 查找失败的就地说明；重试按当前条件重取第一页。
  String? _notice;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _matches.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 范围选项要读应用根上的目标与材料；读不到时仍可按其他条件查找。
    unawaited(_loadScopeOptions());
    // 第一页立即取，首帧就按读取中显示骨架，不先闪一下入口提示。
    unawaited(_search());
  }

  @override
  void dispose() {
    _matches.removeListener(_onSearchChanged);
    _matches.dispose();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
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

  /// 按一组条件取一页：把服务返回值换成 [PagedResult]，范围名字与命中总数记在
  /// 页面；失败说明在这里生成，保留原始调用栈。
  SearchPage<Memory> _pageFetcher(MemorySearchQuery query) {
    return (offset) async {
      final loadingMore = _matches.loadingMore;
      try {
        final results = await AppScope.of(context).memory.edit
            .search(query, offset: offset, pageSize: kSearchPageSize);
        _scopeLabels = results.scopeLabels;
        _matched = results.matched;
        return PagedResult<Memory>(
          items: results.memories,
          hasMore: results.hasMore,
          nextOffset: results.nextOffset,
          total: results.matched,
        );
      } catch (error, stack) {
        if (mounted) {
          _notice = describeFailure(
            context,
            error,
            stack,
            action: loadingMore ? '继续读取记忆查找结果' : '查找记忆',
            kind: loadingMore ? 'memory_search_page' : 'memory_search',
            kept: loadingMore ? '已经显示的记忆没有改动' : '屏幕上已经显示的记忆保持不变',
            next: loadingMore ? '可以再点一次“加载更多结果”' : '可以点重试再找一次',
          );
        }
        rethrow;
      }
    };
  }

  /// 立即按当前条件重取第一页；筛选变化、重试与写入之后都走这里。
  Future<void> _search() async {
    _notice = null;
    await _matches.refresh(
      active: _status != MemoryStatus.deleted,
      fetch: _pageFetcher(_queryCondition),
    );
  }

  /// 输入变化：先按有条件的读取中显示，等输入停下来再查，只留最后一次。
  void _onTextChanged(String _) {
    _notice = null;
    final query = _queryCondition;
    _matches.onQueryChanged(
      active: query.status != MemoryStatus.deleted,
      fetch: _pageFetcher(query),
    );
  }

  /// 接着向后取一页；过滤与排序已经在前一页完成，这里只追加新的条目。
  Future<void> _loadMore() async {
    _notice = null;
    await _matches.loadMore();
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
                onChange: (value) => _onTextChanged(value.text),
              ),
              textInputAction: TextInputAction.search,
              onSubmit: (_) => _search(),
              hint: '搜索记忆正文',
            ),
          ),
          _filters(theme),
          if (_matches.isLoading) const forui.FProgress(),
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

    final page = _matches.page;
    if (page == null) {
      if (_matches.isFailed || _matches.phase == SearchPhase.idle) {
        return const SingleChildScrollView(
          child: EmptyState(
            icon: FLucideIcons.search,
            title: '输入要查找的文字',
            description: '可以按正文关键词、类别、适用范围与状态查找；查找只在本机完成，不调用模型。',
          ),
        );
      }
      return const ListSkeleton(rows: 3);
    }

    final query = _queryCondition;
    if (page.isEmpty) {
      if (query.isDefault) {
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

    final showEnd = !page.hasMore && page.length >= kSearchPageSize;
    return ListView(
      controller: _scroll,
      padding: theme.space.pageInsets(top: theme.space.xs),
      children: [
        if (query.isDefault)
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
              '共 ${_matched ?? page.total ?? page.length} 条命中',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ),
        for (final memory in page.items) _tile(theme, memory),
        if (page.hasMore)
          LoadMoreFooter(
            label: '加载更多结果',
            loading: _matches.loadingMore,
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
