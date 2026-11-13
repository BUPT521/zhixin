import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material;

import 'theme.dart';

import '../app_scope.dart';
import '../application/search_service.dart';
import '../application/semantic_index_service.dart';
import '../domain/models/evidence.dart';
import '../domain/models/search.dart';
import '../domain/models/study.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
import 'materials_page.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';

/// 记录页的本地查找：讨论消息、题目、已提交作答与材料页一起找，点开回到
/// 原记录。
///
/// 查找范围是用户主动选择的，默认本机全部记录；回答时使用的范围由当前讨论
/// 决定，两者不共用。原文与关键词查找不调用网络，断网或没有配置模型时同样
/// 可用；用户按下“按意思找”之后才请求嵌入服务，语义命中与本地结果按名次
/// 融合成同一份记录列表。
class RecordsSearchPage extends StatefulWidget {
  const RecordsSearchPage({
    super.key,
    required this.onOpenLearning,
    required this.onOpenDiscussion,
  });

  final Future<void> Function(int questionId) onOpenLearning;
  final Future<void> Function(int conversationId) onOpenDiscussion;

  @override
  State<RecordsSearchPage> createState() => _RecordsSearchPageState();
}

class _RecordsSearchPageState extends State<RecordsSearchPage> {
  /// 一次“按意思找”最多取多少条语义候选；融合后仍按页面大小切片。
  static const int _semanticLimit = 40;

  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  SearchResults? _results;
  bool _loading = false;
  bool _loadingMore = false;
  String? _notice;
  EvidenceScope _scope = const EvidenceScope.userAll();
  bool _scopeMenuOpen = false;

  /// 每次查询或筛选变化都换一个编号，晚到的旧结果直接丢弃。
  final SearchRequestGate _requests = SearchRequestGate();
  String _appliedQuery = '';

  /// 本次融合使用的语义命中；查询或范围变化时清空，需要重新按。
  List<EvidenceHit> _semanticHits = const [];
  SemanticCancelToken? _semanticToken;
  bool _semanticLoading = false;
  bool _semanticFailed = false;
  bool _semanticEmptyIndex = false;
  bool _semanticAttempted = false;

  List<LearningGoal> _goals = const [];
  List<Material> _materials = const [];

  bool _scopeOptionsRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 范围选项要读应用根上的仓库，放在 initState 里会依赖尚未就绪的上下文。
    if (_scopeOptionsRequested) return;
    _scopeOptionsRequested = true;
    _loadScopeOptions();
  }

  @override
  void dispose() {
    _semanticToken?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadScopeOptions() async {
    try {
      final scope = AppScope.of(context);
      final goals = await scope.tasks.activeGoals();
      final materials = await scope.materials.list();
      if (!mounted) return;
      setState(() {
        _goals = goals;
        _materials = materials;
      });
    } catch (_) {
      // 范围选项读取失败时仍可查找全部记录，不阻塞本次查找。
    }
  }

  /// 取消耗时中的语义请求并回到纯本地结果。
  void _cancelSemantic() {
    _semanticToken?.cancel();
    _semanticToken = null;
    _semanticHits = const [];
    _semanticLoading = false;
    _semanticFailed = false;
    _semanticEmptyIndex = false;
    _semanticAttempted = false;
  }

  Future<void> _search(String text) async {
    final query = text.trim();
    final requestId = _requests.start();
    _cancelSemantic();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _notice = null;
        _appliedQuery = '';
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
      final results = await AppScope.of(context).searchService.searchPage(
        query,
        scope: _scope,
        pageSize: SearchService.defaultPageSize,
      );
      // 快速切换查询或筛选时，只有最后一次请求能写入页面。
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _results = results;
        _appliedQuery = query;
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
          action: '搜索本机记录',
          kind: 'search_read',
          kept: '已经保存的记录没有改动',
          next: '可以再搜一次',
        );
      });
    }
  }

  /// 先取语义命中，再以同一份命中重查第一页；本地结果在等待期间保持不动。
  Future<void> _searchByMeaning() async {
    final query = _query.text.trim();
    if (query.isEmpty || _semanticLoading) return;
    final scope = AppScope.of(context);
    final index = scope.semanticIndex;
    if (!index.configured) return;
    _semanticToken?.cancel();
    final token = SemanticCancelToken();
    _semanticToken = token;
    setState(() {
      _semanticLoading = true;
      _semanticFailed = false;
      _semanticEmptyIndex = false;
      _semanticAttempted = false;
      _notice = null;
    });
    SemanticResult result;
    try {
      result = await index.search(
        query,
        scope: _scope,
        limit: _semanticLimit,
        cancelToken: token,
      );
    } catch (_) {
      result = const SemanticResult(failure: SemanticFailure.error);
    }
    if (!mounted || !identical(_semanticToken, token)) return;
    _semanticToken = null;
    if (result.failure == SemanticFailure.cancelled) {
      setState(() => _semanticLoading = false);
      return;
    }
    if (!result.usable) {
      setState(() {
        _semanticLoading = false;
        _semanticFailed = true;
        _semanticHits = const [];
        _semanticAttempted = true;
      });
      return;
    }
    setState(() {
      _semanticLoading = false;
      _semanticHits = result.hits;
      _semanticEmptyIndex = result.entries == 0;
      _semanticAttempted = true;
    });
    if (result.hits.isNotEmpty) await _reloadFused(query);
  }

  /// 用已经取回的语义命中重查第一页，整表按融合顺序刷新。
  Future<void> _reloadFused(String query) async {
    final requestId = _requests.start();
    setState(() {
      _loading = true;
      _loadingMore = false;
    });
    try {
      final results = await AppScope.of(context).searchService.searchPage(
        query,
        scope: _scope,
        pageSize: SearchService.defaultPageSize,
        semanticHits: _semanticHits,
      );
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _results = results;
        _appliedQuery = query;
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
          action: '合并按意思找到的结果',
          kind: 'search_fusion',
          kept: '已经显示的记录没有改动',
          next: '可以再按一次“按意思找”',
        );
      });
    }
  }

  /// 接着向后取一页；排序与去重已经在前一页完成，这里只追加新记录。
  Future<void> _loadMore() async {
    final results = _results;
    if (results == null || !results.hasMore || _loadingMore) return;
    final requestId = _requests.start();
    setState(() => _loadingMore = true);
    try {
      final next = await AppScope.of(context).searchService.searchPage(
        _appliedQuery,
        scope: _scope,
        offset: results.nextOffset,
        pageSize: SearchService.defaultPageSize,
        semanticHits: _semanticHits,
      );
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
          action: '继续读取查找结果',
          kind: 'search_page',
          kept: '已经显示的记录没有改动',
          next: '可以再点一次“加载更多结果”',
        );
      });
    }
  }

  /// 把这一条来源加入下一次回答；只保存在应用根上，不写进记录。
  void _bring(EvidenceHit hit) {
    AppScope.of(context).broughtSources.add(hit.identity);
    setState(() {});
  }

  Future<void> _openMaterial(EvidenceHit hit) async {
    final materialId = hit.location.materialId;
    if (materialId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MaterialDetailPage(
          materialId: materialId,
          pageFrom: hit.location.pageNo,
          pageTo: hit.location.pageNo,
          stepTitle: '搜索命中的原文',
        ),
      ),
    );
  }

  String get _scopeLabel {
    return switch (_scope.kind) {
      EvidenceScopeKind.all => '本机全部记录',
      EvidenceScopeKind.goal =>
        '目标：${_goals.where((goal) => goal.id == _scope.goalId).map((goal) => goal.title).firstOrNull ?? '已删除的目标'}',
      EvidenceScopeKind.material =>
        '材料：${_materials.where((material) => material.id == _scope.materialId).map((material) => material.title).firstOrNull ?? '已删除的材料'}',
    };
  }

  /// 一条状态行，说明语义这一步正在做什么、为什么没有补充结果。
  String? get _semanticStatus {
    if (_semanticLoading) return '正在按意思找…';
    if (_semanticFailed) return '按意思的部分没有完成，下面是原文与关键词结果';
    if (_semanticEmptyIndex) return '语义索引还没有内容，可以在设置里更新';
    if (_semanticAttempted && _semanticHits.isEmpty) return '没有找到意思相近的记录';
    return null;
  }

  Widget _scopeMenu() {
    return forui.FPopoverMenu.tiles(
      control: forui.FPopoverControl.lifted(
        shown: _scopeMenuOpen,
        onChange: (open) => setState(() => _scopeMenuOpen = open),
      ),
      menuAnchor: AlignmentDirectional.topEnd,
      childAnchor: AlignmentDirectional.bottomEnd,
      style: const .delta(maxWidth: 320),
      semanticsLabel: '查找范围',
      barrierSemanticsLabel: '关闭查找范围',
      builder: (context, controller, _) => ZhixinIconButton(
        tooltip: '查找范围',
        onPressed: controller.toggle,
        icon: FLucideIcons.slidersHorizontal,
      ),
      menuBuilder: (context, controller, _) {
        forui.FTile option(String label, EvidenceScope scope) {
          final selected =
              scope.kind == _scope.kind &&
              scope.goalId == _scope.goalId &&
              scope.materialId == _scope.materialId;
          return forui.FTile(
            title: Text(label),
            selected: selected,
            suffix: selected
                ? Icon(FLucideIcons.check, color: context.zhixin.colors.primary)
                : null,
            onPress: () {
              controller.hide();
              setState(() => _scope = scope);
              if (_query.text.trim().isNotEmpty) _search(_query.text);
            },
          );
        }

        return [
          forui.FTileGroup(
            children: [option('本机全部记录', const EvidenceScope.userAll())],
          ),
          if (_goals.isNotEmpty)
            forui.FTileGroup(
              children: [
                for (final goal in _goals)
                  option('目标：${goal.title}', EvidenceScope.userGoal(goal.id)),
              ],
            ),
          if (_materials.isNotEmpty)
            forui.FTileGroup(
              children: [
                for (final material in _materials)
                  option(
                    '材料：${material.title}',
                    EvidenceScope.userMaterial(material.id),
                  ),
              ],
            ),
        ];
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final results = _results;
    return forui.FScaffold(
      header: ZhixinHeader(
        title: const Text('搜索记录'),
        showBack: true,
        actions: [
          PopScope<void>(
            canPop: !_scopeMenuOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _scopeMenuOpen) {
                setState(() => _scopeMenuOpen = false);
              }
            },
            child: _scopeMenu(),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: forui.FTextField(
              control: .managed(controller: _query),
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmit: _search,
              hint: '搜索讨论、题目、作答或材料原文',
              suffixBuilder: (_, style, _) => ZhixinIconButton(
                tooltip: '搜索',
                onPressed: () => _search(_query.text),
                icon: FLucideIcons.search,
                style: style.clearButtonStyle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  FLucideIcons.filter,
                  size: 16,
                  color: theme.colors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '查找范围：$_scopeLabel；回答只使用本次讨论的范围',
                    style: theme.text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          _semanticBar(theme),
          if (_loading) const forui.FProgress(),
          if (AppScope.of(context).broughtSources.length > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  Icon(
                    FLucideIcons.listChecks,
                    size: 16,
                    color: theme.colors.primary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '已加入 ${AppScope.of(context).broughtSources.length} 条来源，'
                      '只对下一次回答有效。',
                      style: theme.text.bodySmall,
                    ),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () {
                      setState(
                        () => AppScope.of(context).broughtSources.clear(),
                      );
                    },
                    child: const Text('清除'),
                  ),
                ],
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _notice!,
                style: TextStyle(color: theme.colors.error),
              ),
            ),
          Expanded(child: _resultsArea(theme, results)),
        ],
      ),
    );
  }

  /// “按意思找”与它的一条状态说明；没有配置嵌入来源时按钮不可用。
  Widget _semanticBar(ZhixinTheme theme) {
    final configured = AppScope.of(context).semanticIndex.configured;
    final status = _semanticStatus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: configured && !_semanticLoading
                    ? _searchByMeaning
                    : null,
                prefix: const Icon(FLucideIcons.brain, size: 18),
                child: const Text('按意思找'),
              ),
              const SizedBox(width: 8),
              if (!configured)
                Expanded(
                  child: Text('配置语义索引后可以按意思找', style: theme.text.bodySmall),
                ),
            ],
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                status,
                style: theme.text.bodySmall.copyWith(
                  color: _semanticFailed ? theme.colors.error : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resultsArea(ZhixinTheme theme, SearchResults? results) {
    if (results == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '输入要查找的文字，按原样查找题号、公式、原句和带下划线的名称，'
            '普通问句会同时按关键词查找。\n查找范围：$_scopeLabel。',
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium,
          ),
        ),
      );
    }
    if (results.isEmpty) {
      // “按意思找”还在进行时本地可能暂时为空，空态等这一步结束再判断。
      if (_semanticLoading) return const SizedBox.shrink();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有找到「${results.query}」。\n'
            '可以换一段原句，或把查找范围改回本机全部记录。',
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium,
          ),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final entry in results.entries) _entryTile(theme, entry),
        if (results.hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(
              child: forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: _loadingMore ? null : _loadMore,
                prefix: _loadingMore
                    ? const forui.FCircularProgress(size: .xs)
                    : const Icon(FLucideIcons.chevronDown),
                child: Text(_loadingMore ? '正在读取…' : '加载更多结果'),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(child: Text('已经到最后一条', style: theme.text.bodySmall)),
          ),
        if (_semanticHits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Center(
              child: Text(
                '按意思查找最多读取前 ${SearchService.fusionWindow} 条本地候选。',
                style: theme.text.bodySmall,
              ),
            ),
          ),
      ],
    );
  }

  /// 一条记录或一页材料；两类卡片沿用原有样式，只在语义独有时加标签。
  Widget _entryTile(ZhixinTheme theme, SearchEntry entry) {
    final material = entry.hits
        .where((hit) => hit.kind == EvidenceKind.materialPage)
        .firstOrNull;
    if (material != null) return _materialTile(theme, entry, material);
    return _recordTile(theme, entry);
  }

  Widget _materialTile(ZhixinTheme theme, SearchEntry entry, EvidenceHit hit) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: forui.FTile(
        prefix: const Icon(FLucideIcons.bookOpen),
        title: Text(hit.title),
        subtitle: Text(
          hit.snippet,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        suffix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.semanticOnly) _semanticTag(theme),
            if (hit.literal)
              forui.FTooltip(
                tipBuilder: (_, _) => const Text('原样命中'),
                child: const Icon(FLucideIcons.type),
              ),
            ZhixinIconButton(
              tooltip: '加入本次回答',
              icon: FLucideIcons.listPlus,
              onPressed: () => _bring(hit),
            ),
          ],
        ),
        onPress: () => _openMaterial(hit),
      ),
    );
  }

  Widget _recordTile(ZhixinTheme theme, SearchEntry entry) {
    final conversationId = entry.hits
        .map((hit) => hit.location.conversationId)
        .whereType<int>()
        .firstOrNull;
    final question = entry.hits
        .where((hit) => hit.kind == EvidenceKind.question)
        .firstOrNull;
    final message = entry.hits
        .where((hit) => hit.kind == EvidenceKind.message)
        .firstOrNull;
    final answers = entry.hits
        .where((hit) => hit.kind == EvidenceKind.answer)
        .toList(growable: false);
    final title =
        question?.title ??
        message?.title ??
        answers.firstOrNull?.title ??
        '一次讨论';
    final details = <String>[
      if (message != null) '讨论：${message.snippet}',
      for (final answer in answers) '作答：${answer.snippet}',
      if (question?.sourceRef != null) '出处：${question!.sourceRef}',
    ].join('\n');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: forui.FTile(
        prefix: Icon(
          question == null
              ? FLucideIcons.messageCircle
              : FLucideIcons.notebookPen,
        ),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: details.isEmpty
            ? null
            : Text(details, maxLines: 3, overflow: TextOverflow.ellipsis),
        suffix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.semanticOnly) _semanticTag(theme),
            ZhixinIconButton(
              tooltip: '加入本次回答',
              icon: FLucideIcons.listPlus,
              onPressed: entry.hits.isEmpty
                  ? null
                  : () => _bring(entry.hits.first),
            ),
            if (conversationId != null &&
                (question != null || answers.isNotEmpty))
              ZhixinIconButton(
                tooltip: '继续作答',
                onPressed: () => widget.onOpenLearning(conversationId),
                icon: FLucideIcons.pencil,
              ),
          ],
        ),
        onPress: conversationId == null
            ? null
            : () => widget.onOpenDiscussion(conversationId),
      ),
    );
  }

  /// “按意思”小标签：只有语义一路找到的记录才显示。
  Widget _semanticTag(ZhixinTheme theme) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colors.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '按意思',
        style: theme.text.labelSmall.copyWith(
          color: theme.colors.onSecondaryContainer,
        ),
      ),
    );
  }
}
