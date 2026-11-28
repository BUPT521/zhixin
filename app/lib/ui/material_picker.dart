import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/material_search.dart';
import '../application/paged_result.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
import 'search_state.dart';
import 'workspace_widgets.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 一次材料页码选择。
class MaterialSelection {
  const MaterialSelection({
    required this.materialId,
    required this.materialTitle,
    required this.pageNo,
    required this.position,
  });

  final String materialId;
  final String materialTitle;
  final int pageNo;

  /// 这一处在材料里的写法：普通材料是“第 N 页”，Word 材料是“第 N 个片段”。
  final String position;

  String get label => '《$materialTitle》$position';
}

/// 选择材料与页码；没有材料时提示先去记录里导入。
///
/// 第一步按标题、来源和页标签过滤候选材料，第二步选页码。过滤只在本机进行
/// 且不改变返回值：选中哪份材料、哪一页，仍按原来的 [MaterialSelection] 交出。
Future<MaterialSelection?> showMaterialPicker(
  BuildContext context, {
  String? initialMaterialId,
  int? initialPageNo,
}) async {
  final scope = AppScope.of(context);
  final List<Material> materials;
  try {
    materials = await scope.library.material.list();
  } catch (error, stack) {
    if (!context.mounted) return null;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '读取材料列表',
        kind: 'material_picker_read',
        kept: '材料没有改动',
        next: '可以再打开一次',
      ),
    );
    return null;
  }
  if (!context.mounted) return null;
  if (materials.isEmpty) {
    showToast(context, '暂无材料。前往“记录 → 材料”导入页面。');
    return null;
  }
  final material = await showZhixinSheet<Material>(
    context: context,
    title: '这次依据哪份材料',
    builder: (_) => MaterialPicker(
      materials: materials,
      initialMaterialId: initialMaterialId,
    ),
  );
  if (material == null || !context.mounted) return null;

  final pages = await _readPages(context, material);
  if (pages == null || !context.mounted) return null;
  if (pages.isEmpty) {
    showToast(context, '这份材料还没有${material.isDocx ? '片段' : '页面'}');
    return null;
  }
  final page = await showZhixinSheet<MaterialPage>(
    context: context,
    title: '《${material.title}》的${material.isDocx ? '哪一个片段' : '哪一页'}',
    builder: (context) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        for (var index = 0; index < pages.length; index++) ...[
          if (index > 0) SizedBox(height: context.zhixin.space.sm),
          forui.FTile(
            prefix: Icon(
              pages[index].pageNo == initialPageNo
                  ? FLucideIcons.circleDot
                  : FLucideIcons.fileText,
            ),
            title: Text(
              '${material.position(pages[index].pageNo)}'
              '${pages[index].label == null ? '' : ' · ${pages[index].label}'}',
            ),
            subtitle: Text(
              pages[index].preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onPress: () => Navigator.of(context).pop(pages[index]),
          ),
        ],
      ],
    ),
  );
  if (page == null) return null;
  return MaterialSelection(
    materialId: material.id,
    materialTitle: material.title,
    pageNo: page.pageNo,
    position: material.position(page.pageNo),
  );
}

/// 读一份材料的页码：读取失败时给出与材料列表同一套说明，不把异常留给框架。
///
/// 选中材料之后紧接着就要读页码，这一步与前面读材料列表同样可能失败；失败时
/// 返回空并把原因提示出来，调用方据此结束这次选择。
Future<List<MaterialPage>?> _readPages(
  BuildContext context,
  Material material,
) async {
  try {
    return await AppScope.of(context).library.material.pages(material.id);
  } catch (error, stack) {
    if (!context.mounted) return null;
    showToast(
      context,
      describeFailure(
        context,
        error,
        stack,
        action: '读取这份材料的页码',
        kind: 'material_picker_pages',
        kept: '材料没有改动',
        next: '可以再打开一次',
      ),
    );
    return null;
  }
}

/// 材料候选：按标题、来源和页标签过滤，查询变化后只显示最后一次请求的结果。
///
/// 没有查询时显示打开面板时读到的全部材料；有查询时由本地查找分页返回，超过
/// 一页时继续加载，较早的命中也能翻到。没有命中时保留查询并给出清除操作。
class MaterialPicker extends StatefulWidget {
  const MaterialPicker({
    super.key,
    required this.materials,
    this.initialMaterialId,
  });

  /// 打开面板时读到的全部材料；没有查询时直接列出这一份。
  final List<Material> materials;

  final String? initialMaterialId;

  @override
  State<MaterialPicker> createState() => _MaterialPickerState();
}

class _MaterialPickerState extends State<MaterialPicker> {
  final TextEditingController _query = TextEditingController();

  /// 候选材料的查找状态：输入防抖、请求序号与分页都在这一份里，翻页时按
  /// 材料标识去重。
  final SearchState<MaterialMatch> _matches = SearchState<MaterialMatch>(
    key: (match) => match.material.id,
  );

  /// 已经应用的查询词；空串表示按打开面板时读到的全部材料显示。
  String _appliedQuery = '';

  /// 查找失败的就地说明。
  String? _notice;

  @override
  void initState() {
    super.initState();
    _matches.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _matches.removeListener(_onSearchChanged);
    _matches.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _onChanged(String text) {
    // 清除按钮跟着输入框里的字出现，不等这一次查找返回。
    setState(() => _appliedQuery = text.trim());
    _notice = null;
    final query = _appliedQuery;
    _matches.onQueryChanged(
      active: query.isNotEmpty,
      fetch: _pageFetcher(query),
    );
  }

  /// 按一个查询取一页：把服务返回值换成 [PagedResult]，失败说明在这里生成。
  SearchPage<MaterialMatch> _pageFetcher(String query) {
    return (offset) async {
      final loadingMore = _matches.loadingMore;
      try {
        final results = await AppScope.of(context).library.materialSearch
            .searchPage(query, offset: offset, pageSize: kSearchPageSize);
        return PagedResult<MaterialMatch>(
          items: results.matches,
          hasMore: results.hasMore,
          nextOffset: results.nextOffset,
        );
      } catch (error, stack) {
        if (mounted && query == _appliedQuery) {
          _notice = describeFailure(
            context,
            error,
            stack,
            action: loadingMore ? '继续读取材料查找结果' : '查找材料',
            kind: loadingMore
                ? 'material_picker_search_page'
                : 'material_picker_search',
            kept: loadingMore ? '已经显示的材料没有改动' : '材料没有改动',
            next: loadingMore ? '可以再点一次“加载更多结果”' : '可以再查一次',
          );
        }
        rethrow;
      }
    };
  }

  void _search(String text) {
    final query = text.trim();
    setState(() => _appliedQuery = query);
    _notice = null;
    unawaited(
      _matches.refresh(active: query.isNotEmpty, fetch: _pageFetcher(query)),
    );
  }

  Future<void> _loadMore() async {
    _notice = null;
    await _matches.loadMore();
  }

  void _clear() {
    _query.clear();
    _search('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final searching =
        _appliedQuery.isNotEmpty || _matches.phase != SearchPhase.idle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        forui.FTextField(
          key: const ValueKey('material-picker-search'),
          control: .managed(
            controller: _query,
            onChange: (value) => _onChanged(value.text),
          ),
          textInputAction: TextInputAction.search,
          onSubmit: _search,
          hint: '按标题、来源或页标签查找材料',
          prefixBuilder: (context, style, variants) =>
              forui.FTextField.prefixIconBuilder(
                context,
                style,
                variants,
                const Icon(FLucideIcons.search, size: 16),
              ),
          suffixBuilder: (_, style, _) => _query.text.isEmpty
              ? const SizedBox.shrink()
              : ZhixinIconButton(
                  tooltip: '清除查询',
                  onPressed: _clear,
                  icon: FLucideIcons.x,
                  size: forui.FButtonSizeVariant.sm,
                  style: style.clearButtonStyle,
                ),
        ),
        SizedBox(height: theme.space.gap),
        if (_matches.isLoading) const forui.FProgress(),
        if (_notice != null) InlineNotice(message: _notice!),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: searching
                ? _searchRows(theme)
                : [
                    for (
                      var index = 0;
                      index < widget.materials.length;
                      index++
                    ) ...[
                      if (index > 0) SizedBox(height: theme.space.sm),
                      _materialTile(
                        theme,
                        widget.materials[index],
                        selected:
                            widget.materials[index].id ==
                            widget.initialMaterialId,
                      ),
                    ],
                  ],
          ),
        ),
      ],
    );
  }

  /// 查找结果的几行：没有查询、没有命中与有命中各一种状态。
  List<Widget> _searchRows(ZhixinTheme theme) {
    final page = _matches.page;
    if (page == null) {
      return [
        Padding(
          padding: EdgeInsets.symmetric(vertical: theme.space.lg),
          child: Center(child: Text('正在查找…', style: theme.text.bodySmall)),
        ),
      ];
    }
    if (page.isEmpty) {
      return [
        EmptyState(
          icon: FLucideIcons.searchX,
          title: '没有找到「$_appliedQuery」',
          description: '可以换一个标题、来源或页标签再试。',
          action: forui.FButton(
            variant: forui.FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: _clear,
            child: const Text('清除查询'),
          ),
        ),
      ];
    }
    return [
      for (var index = 0; index < page.length; index++) ...[
        if (index > 0) SizedBox(height: theme.space.sm),
        _materialTile(
          theme,
          page.items[index].material,
          match: page.items[index],
          selected: page.items[index].material.id == widget.initialMaterialId,
        ),
      ],
      if (page.hasMore)
        LoadMoreFooter(
          label: '加载更多结果',
          loading: _matches.loadingMore,
          onPressed: _loadMore,
        ),
    ];
  }

  /// 一条候选材料；查找命中时先写命中原因，页内正文命中再附一段片段。
  Widget _materialTile(
    ZhixinTheme theme,
    Material material, {
    MaterialMatch? match,
    required bool selected,
  }) {
    final snippet = match?.snippet;
    final summary =
        '${material.kindLabel} · ${material.pageCount} '
        '${material.isDocx ? '个片段' : '页'}'
        '${material.sourceRef == null ? '' : ' · ${material.sourceRef}'}';
    return forui.FTile(
      prefix: Icon(selected ? FLucideIcons.circleDot : FLucideIcons.bookOpen),
      title: Text(material.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (match != null) ...[
            TagRow(children: [StatusTag(match.reason, tone: TagTone.accent)]),
            SizedBox(height: theme.space.xs),
          ],
          if (snippet != null && snippet.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: theme.space.xs),
              child: Text(
                snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurface,
                ),
              ),
            ),
          Text(summary),
        ],
      ),
      onPress: () => Navigator.of(context).pop(material),
    );
  }
}
