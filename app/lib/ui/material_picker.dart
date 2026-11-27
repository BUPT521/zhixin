import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/material_search.dart';
import '../application/request_gate.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
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
  });

  final String materialId;
  final String materialTitle;
  final int pageNo;

  String get label => '《$materialTitle》第 $pageNo 页';
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
    showToast(context, '这份材料还没有页面');
    return null;
  }
  final page = await showZhixinSheet<MaterialPage>(
    context: context,
    title: '《${material.title}》的哪一页',
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
              '第 ${pages[index].pageNo} ${material.isDocx ? '个片段' : '页'}'
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
  final RequestGate _requests = RequestGate();
  Timer? _debounce;
  MaterialSearchResults? _results;
  String _appliedQuery = '';
  bool _searching = false;
  bool _loadingMore = false;
  String? _notice;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _search(text);
    });
  }

  Future<void> _search(String text) async {
    _debounce?.cancel();
    final query = text.trim();
    final requestId = _requests.start();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _appliedQuery = '';
        _searching = false;
        _loadingMore = false;
        _notice = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _loadingMore = false;
      _notice = null;
    });
    try {
      final results = await AppScope.of(context).library.materialSearch
          .searchPage(query);
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _results = results;
        _appliedQuery = query;
        _searching = false;
      });
    } catch (error, stack) {
      if (!mounted || !_requests.isCurrent(requestId)) return;
      setState(() {
        _searching = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '查找材料',
          kind: 'material_picker_search',
          kept: '材料没有改动',
          next: '可以再查一次',
        );
      });
    }
  }

  Future<void> _loadMore() async {
    final results = _results;
    if (results == null || !results.hasMore || _loadingMore || _searching) {
      return;
    }
    final requestId = _requests.start();
    setState(() => _loadingMore = true);
    try {
      final next = await AppScope.of(context).library.materialSearch
          .searchPage(_appliedQuery, offset: results.nextOffset);
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
          action: '继续读取材料查找结果',
          kind: 'material_picker_search_page',
          kept: '已经显示的材料没有改动',
          next: '可以再点一次“加载更多结果”',
        );
      });
    }
  }

  void _clear() {
    _query.clear();
    _search('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final results = _results;
    final searching =
        _results != null || _searching || _appliedQuery.isNotEmpty;
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
        if (_searching) const forui.FProgress(),
        if (_notice != null) InlineNotice(message: _notice!),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: searching
                ? _searchRows(theme, results)
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
  List<Widget> _searchRows(ZhixinTheme theme, MaterialSearchResults? results) {
    if (results == null) {
      return [
        Padding(
          padding: EdgeInsets.symmetric(vertical: theme.space.lg),
          child: Center(child: Text('正在查找…', style: theme.text.bodySmall)),
        ),
      ];
    }
    if (results.isEmpty) {
      return [
        EmptyState(
          icon: FLucideIcons.searchX,
          title: '没有找到「${results.query}」',
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
      for (var index = 0; index < results.matches.length; index++) ...[
        if (index > 0) SizedBox(height: theme.space.sm),
        _materialTile(
          theme,
          results.matches[index].material,
          match: results.matches[index],
          selected:
              results.matches[index].material.id == widget.initialMaterialId,
        ),
      ],
      if (results.hasMore)
        LoadMoreFooter(
          label: '加载更多结果',
          loading: _loadingMore,
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
