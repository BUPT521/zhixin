import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import '../app_scope.dart';
import '../application/docx_import.dart';
import '../application/material_search.dart';
import '../application/request_gate.dart';
import '../domain/models/material.dart';
import '../domain/rules/text.dart';
import 'docx_review_dialog.dart';
import 'failure_feedback.dart';
import 'goal_picker.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_menu.dart';
import 'zhixin_select.dart';
import 'zhixin_toast.dart';

/// 给一份材料补一页：先读已有页码，再打开加页对话框，保存之后由订阅重读。
///
/// 材料列表行尾的按钮与材料详情的空态都用这一个入口，两处不再各写一遍加页
/// 流程；页码已存在时不覆盖，提示到详情用「更正这一页」。
Future<void> addMaterialPage(BuildContext context, Material material) async {
  final scope = AppScope.of(context);
  final List<MaterialPage> pages;
  try {
    pages = await scope.library.material.pages(material.id);
  } catch (error, stack) {
    if (!context.mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取这份材料的页码',
      kind: 'material_pages_read',
      kept: '材料没有改动',
      next: '可以再试一次',
    );
    showToast(context, message);
    return;
  }
  if (!context.mounted) return;
  final draft = await showZhixinDialog<_PageDraft>(
    context: context,
    builder: (_) => _PageDialog(
      material: material,
      pageNumbers: {for (final page in pages) page.pageNo},
    ),
  );
  if (draft == null || !context.mounted) return;
  try {
    await scope.library.material.addPage(
      materialId: material.id,
      pageNo: draft.pageNo,
      content: draft.content,
      label: draft.label,
    );
  } on PageNumberTaken catch (error) {
    if (!context.mounted) return;
    final message = '$error。要改这一页，请打开材料详情点「更正这一页」。';
    showToast(context, message);
  } catch (error, stack) {
    if (!context.mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '保存这一页',
      kind: 'material_page_save',
      kept: '已有页面没有改动',
      next: '可以再试一次',
    );
    showToast(context, message);
  }
}

/// 记录页的材料分组：按材料查看页码，导入新的一份或补充一页。
class MaterialList extends StatefulWidget {
  const MaterialList({
    super.key,
    this.onImportedFromHeader,
    this.onQueryChanged,
  });

  /// 标题栏的导入入口在开始之前调用一次，记录页据此先切到材料页签。
  final VoidCallback? onImportedFromHeader;

  /// 查找的词变了时调用；记录页据此收起或放回页签与筛选条。
  final VoidCallback? onQueryChanged;

  @override
  State<MaterialList> createState() => MaterialListState();
}

class MaterialListState extends State<MaterialList> {
  /// 材料列表的订阅：材料、页码与目标任一被写入之后由数据层整份重读。
  ///
  /// 导入、加页、更正与从详情返回之后不再由页面重读，刷新按钮与切回材料页签
  /// 只是换一条新流（ADR-0014）。
  Stream<List<Material>>? _stream;
  bool _started = false;
  bool _importingWord = false;
  bool _importingPaste = false;

  /// 标题栏导入开始之前的回调，见 [MaterialList.onImportedFromHeader]。
  VoidCallback? get _importedFromHeader => widget.onImportedFromHeader;

  /// 读取失败时就地说明；有内容时仍显示上一次读到的列表。
  String? _notice;

  /// 材料查找：输入框、最后一次查询与已经取回的命中。
  ///
  /// 查找是本地查询，不调用模型；查询或筛选变化后只显示最后一次请求的结果，
  /// 旧请求晚到就按编号丢弃（与记录页查找同一套 [RequestGate]）。
  final TextEditingController _searchField = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final RequestGate _requests = RequestGate();
  Timer? _searchDebounce;
  MaterialSearchResults? _results;
  String _appliedQuery = '';
  bool _searching = false;
  bool _loadingMore = false;
  String? _searchNotice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 没显示的页签不提前读取；等这一栏第一次建出来再订阅。
    if (_started) return;
    _started = true;
    _stream = _createStream();
  }

  Stream<List<Material>> _createStream() =>
      AppScope.of(context).library.material.watchList();

  /// 重新订阅材料列表；记录页的刷新按钮与切回材料页签都走这里。
  ///
  /// 方法名与原来一致，记录页仍按 `reload()` 调用，实现改成换一条新流。
  void reload() {
    if (!mounted) return;
    setState(() {
      _notice = null;
      _stream = _createStream();
    });
  }

  /// 收起源自材料的查找：清空查询词回到材料列表，记录页据此把页签放回来。
  ///
  /// 记录页在材料正在查找时收起页签与筛选条，换成另一个页签、随时想回到材料
  /// 列表时都走这里；查找框的清除按钮与“清除查询”只清词，不换页签。
  void exitSearch() => _clearSearch();

  void _reportReadFailure(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取材料列表',
      kind: 'materials_read',
      kept: '已有的材料没有改动',
      next: '可以点重试再读一次',
    );
    setState(() => _notice = message);
  }

  void _clearNotice() {
    if (_notice == null) return;
    setState(() => _notice = null);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchField.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 输入停下之后再查一次，免得每敲一个字都读一遍库。
  void _onQueryChanged(String text) {
    _searchDebounce?.cancel();
    // 清除按钮跟着输入框里的字出现，不等这一次查找返回；记录页也据此收起页签。
    setState(() {});
    onQueryChanged?.call();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _search(text);
    });
  }

  /// 查询或筛选变化后只显示最后一次请求的结果：旧请求晚到时就地丢弃。
  Future<void> _search(String text) async {
    _searchDebounce?.cancel();
    final query = text.trim();
    final requestId = _requests.start();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _appliedQuery = '';
        _searching = false;
        _loadingMore = false;
        _searchNotice = null;
      });
      onQueryChanged?.call();
      return;
    }
    setState(() {
      _searching = true;
      _loadingMore = false;
      _searchNotice = null;
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
        _searchNotice = describeFailure(
          context,
          error,
          stack,
          action: '查找材料',
          kind: 'material_search',
          kept: '已经显示的材料没有改动',
          next: '可以再查一次',
        );
      });
    }
  }

  /// 继续向后取一页命中；排序与去重已经在前一页完成，这里只追加。
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
        _searchNotice = describeFailure(
          context,
          error,
          stack,
          action: '继续读取材料查找结果',
          kind: 'material_search_page',
          kept: '已经显示的结果没有改动',
          next: '可以再点一次“加载更多结果”',
        );
      });
    }
  }

  /// 清空查询，回到原来的材料列表。
  void _clearSearch() {
    _searchField.clear();
    _search('');
  }

  /// 查询词一变就告诉记录页：有词时记录页收起页签，把整块让给查找结果。
  VoidCallback? get onQueryChanged => widget.onQueryChanged;

  /// 记录页顶上那条搜索框在材料页签上的写法：就地输入与过滤，不再另开一页；
  /// 切换页签时记录页把焦点交给它，键盘跟着切过去。
  ///
  /// 学习记录与材料共用记录页的同一个搜索框，材料页里不再放第二条。
  Widget searchField() {
    return forui.FTextField(
      key: const ValueKey('materials-search-entry'),
      focusNode: _searchFocus,
      control: .managed(
        controller: _searchField,
        onChange: (value) => _onQueryChanged(value.text),
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
      suffixBuilder: (_, style, _) => _searchField.text.isEmpty
          ? const SizedBox.shrink()
          : ZhixinIconButton(
              tooltip: '清除查询',
              onPressed: _clearSearch,
              icon: FLucideIcons.x,
              size: forui.FButtonSizeVariant.sm,
              style: style.clearButtonStyle,
            ),
    );
  }

  /// 搜索框里已经应用的查询词；记录页用它在切换页签之后重新写回搜索框。
  String get appliedQuery => _appliedQuery;

  /// 是否正在查找：有查询词或还在取结果时记录页收起页签，结束查找再放回。
  bool get isSearching =>
      _searching ||
      _appliedQuery.isNotEmpty ||
      _searchField.text.trim().isNotEmpty;

  /// 搜索框的焦点：记录页在材料页签上点搜索入口时把键盘切到这里。
  FocusNode get searchFocus => _searchFocus;

  /// 打开导入对话框之前读一次目标列表；归属选项只在打开对话框时用得到。
  Future<List<({String id, String title, bool active})>?> _loadGoals() async {
    try {
      final goals = await AppScope.of(context).study.plan.goals();
      return [
        for (final goal in goals)
          (id: goal.id, title: goal.title, active: goal.active),
      ];
    } catch (error, stack) {
      if (!mounted) return null;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取目标列表',
        kind: 'materials_goals',
        kept: '材料没有改动',
        next: '可以再试一次',
      );
      showToast(context, message);
      return null;
    }
  }

  /// 从记录页标题栏发起的导入：先切到材料页签，再按材料页自己的流程导入。
  ///
  /// 标题栏上的入口与列表、空态里的入口走同一套流程，导入成功之后打开新的一份。
  Future<void> importFromHeader({required bool word}) async {
    _importedFromHeader?.call();
    // 等这一帧把材料列表建出来，读取目标之类的调用才拿得到页面上下文。
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    if (word) {
      await _importWord();
    } else {
      await _import();
    }
  }

  Future<void> _import() async {
    setState(() => _importingPaste = true);
    try {
      await _importPaste(AppScope.of(context));
    } finally {
      if (mounted) setState(() => _importingPaste = false);
    }
  }

  Future<void> _importPaste(AppScopeState scope) async {
    final goals = await _loadGoals();
    if (goals == null || !mounted) return;
    final drafts = await showZhixinDialog<List<_MaterialDraft>>(
      context: context,
      builder: (_) => _ImportMaterialDialog(goals: goals),
    );
    if (drafts == null || drafts.isEmpty || !mounted) return;
    try {
      final first = drafts.first;
      final id = await scope.library.material.importMaterial(
        title: first.title,
        kind: first.kind,
        sourceRef: first.sourceRef,
        goalId: first.goalId,
        pages: [
          for (final draft in drafts)
            (pageNo: draft.pageNo, content: draft.content, label: draft.label),
        ],
      );
      await _openImportedMaterial(id);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '导入材料',
        kind: 'materials_import',
        kept: '材料没有写入',
        next: '可以检查内容后重试',
      );
      showToast(context, message);
    }
  }

  Future<void> _importWord() async {
    final scope = AppScope.of(context);
    final service = scope.library.material;
    final expectedEpoch = service.dataEpoch;
    setState(() => _importingWord = true);
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择 Word 文件',
        type: FileType.custom,
        allowedExtensions: const ['docx'],
      );
      if (file == null || !mounted) return;
      final document = await DocxImport.read(
        file.name,
        file.readAsByteStream(),
      );
      if (!mounted) return;
      final goals = await _loadGoals();
      if (goals == null || !mounted) return;
      final selection = await showDocxReview(
        context,
        document: document,
        goals: goals,
      );
      if (selection == null || !mounted) return;
      final id = await service.importDocx(
        document: document,
        title: selection.title,
        goalId: selection.goalId,
        expectedEpoch: expectedEpoch,
      );
      await _openImportedMaterial(id);
    } catch (error, stack) {
      if (!mounted) return;
      final message = error is FormatException
          ? error.message
          : describeFailure(
              context,
              error,
              stack,
              action: '导入 Word 材料',
              kind: 'docx_import',
              kept: '已有材料未受影响',
              next: '可以重新选择文件后再试',
            );
      showToast(context, message);
    } finally {
      if (mounted) setState(() => _importingWord = false);
    }
  }

  /// 打开刚导入的材料；列表由订阅刷新，返回之后不再重读。
  Future<void> _openImportedMaterial(String id) async {
    if (!mounted) return;
    await openMaterial(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LiveView<List<Material>>(
      stream: _stream,
      onError: _reportReadFailure,
      onData: (_) => _clearNotice(),
      builder: (context, materials, loading) {
        final list = materials ?? const <Material>[];
        final canImport = !loading && !_importingWord && !_importingPaste;
        final showResults =
            _results != null || _searching || _appliedQuery.isNotEmpty;
        return Column(
          children: [
            if (_importingWord || _importingPaste) const forui.FProgress(),
            if (_searching) const forui.FProgress(),
            if (_notice != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: theme.space.page),
                child: InlineNotice(message: _notice!, onRetry: reload),
              ),
            if (_searchNotice != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: theme.space.page),
                child: InlineNotice(
                  message: _searchNotice!,
                  onRetry: () => _search(
                    _appliedQuery.isEmpty ? _searchField.text : _appliedQuery,
                  ),
                ),
              ),
            Expanded(
              child: showResults
                  ? _searchArea(theme)
                  : loading
                  ? SingleChildScrollView(
                      child: ListSkeleton(
                        rowHeight: 73,
                        padding: theme.space.pageInsets(),
                      ),
                    )
                  : list.isEmpty
                  ? SingleChildScrollView(
                      child: EmptyState(
                        icon: FLucideIcons.bookOpenText,
                        title: '还没有材料',
                        description: '粘贴原文或选择 .docx 文件，之后可以搜索材料、引用原文或建立学习计划。',
                        action: MaterialImportButton(
                          enabled: canImport,
                          onPaste: _import,
                          onWord: _importWord,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: theme.space.pageInsets(),
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(height: theme.space.gap),
                      itemBuilder: (context, index) {
                        final material = list[index];
                        return forui.FTile(
                          title: Text(material.title),
                          subtitle: Text(
                            '${material.kindLabel}'
                            '${material.sourceRef == null ? '' : ' · ${material.sourceRef}'}'
                            ' · ${material.pageCount} ${material.isDocx ? '个片段' : '页'}',
                          ),
                          suffix: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!material.isDocx)
                                ZhixinIconButton(
                                  tooltip: '添加一页',
                                  onPressed: () =>
                                      addMaterialPage(context, material),
                                  icon: FLucideIcons.filePlus,
                                ),
                              const Icon(FLucideIcons.chevronRight),
                            ],
                          ),
                          onPress: () => openMaterial(context, material.id),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 查找结果：命中的材料按列表顺序排列，写清命中原因与片段，底部继续加载。
  Widget _searchArea(ZhixinTheme theme) {
    final results = _results;
    if (results == null) {
      return SingleChildScrollView(
        child: ListSkeleton(rowHeight: 73, padding: theme.space.pageInsets()),
      );
    }
    if (results.isEmpty) {
      return SingleChildScrollView(
        child: EmptyState(
          icon: FLucideIcons.searchX,
          title: '没有找到「${results.query}」',
          description: '可以换一个标题、来源、页标签或正文片段再试。',
          action: forui.FButton(
            variant: forui.FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: _clearSearch,
            child: const Text('清除查询'),
          ),
        ),
      );
    }
    final showEnd =
        !results.hasMore &&
        results.matches.length >= MaterialSearchService.pageSize;
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        for (final match in results.matches) _searchResultTile(theme, match),
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

  /// 一条查找命中；页内命中打开详情时直接落到那一页。
  Widget _searchResultTile(ZhixinTheme theme, MaterialMatch match) {
    final material = match.material;
    final snippet = match.snippet;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.bookOpen, tone: TagTone.muted),
        title: Text(
          material.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TagRow(
              children: [
                StatusTag(match.reason, tone: TagTone.accent),
                if (material.sourceRef != null)
                  StatusTag(material.sourceRef!, tone: TagTone.muted),
              ],
            ),
            SizedBox(height: theme.space.xs),
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
            Text(
              '${material.kindLabel} · ${material.pageCount} '
              '${material.isDocx ? '个片段' : '页'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        suffix: const Icon(FLucideIcons.chevronRight),
        onPress: () => openMaterial(
          context,
          material.id,
          pageFrom: match.pageNo,
          pageTo: match.pageNo,
          stepTitle: match.pageNo == null ? null : '查找命中的原文',
        ),
      ),
    );
  }
}

/// 材料的导入入口：一个按钮，菜单里选粘贴原文还是导入 Word 文件。
///
/// 记录页把它放在标题栏右侧，与“贴一道题”同一种写法：次要按钮、`sm` 尺寸、
/// 图标在前；空库时这个入口在空态里也出现一次。
class MaterialImportButton extends StatelessWidget {
  const MaterialImportButton({
    required this.enabled,
    required this.onPaste,
    required this.onWord,
    this.label = '导入材料',
    this.visible = true,
    super.key,
  });

  final bool enabled;
  final VoidCallback onPaste;
  final VoidCallback onWord;

  /// 按钮上的文字。
  final String label;

  /// 是否画出来；占位量宽时传 false，只按这句文字占一个位置。
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: false,
      child: ZhixinMenu(
        semanticsLabel: '导入材料',
        items: [
          ZhixinMenuItem(label: '粘贴原文', onSelected: onPaste),
          ZhixinMenuItem(label: '从 Word 导入', onSelected: onWord),
        ],
        triggerBuilder: (context, controller) => forui.FButton(
          variant: forui.FButtonVariant.secondary,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: enabled && visible ? controller.toggle : null,
          prefix: const Icon(FLucideIcons.upload),
          child: Text(label),
        ),
      ),
    );
  }
}

class _MaterialDraft {
  const _MaterialDraft({
    required this.title,
    required this.kind,
    required this.pageNo,
    required this.content,
    this.sourceRef,
    this.label,
    this.goalId,
  });

  final String title;
  final MaterialKind kind;
  final int pageNo;
  final String content;
  final String? sourceRef;
  final String? label;
  final String? goalId;
}

class _PageDraft {
  const _PageDraft({required this.pageNo, required this.content, this.label});

  final int pageNo;
  final String content;
  final String? label;
}

/// 表单字段的错误就地写红字：错误属于这一项，移到别处用户看不出哪项没通过。
Widget _fieldError(ZhixinTheme theme, String message) {
  return Padding(
    padding: EdgeInsets.only(top: theme.space.xs),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        message,
        style: theme.text.bodySmall.copyWith(color: theme.colors.error),
      ),
    ),
  );
}

/// 导入一份材料：标题、类型、出处与第一页；也可以先只建材料。
class _ImportMaterialDialog extends StatefulWidget {
  const _ImportMaterialDialog({required this.goals});

  final List<({String id, String title, bool active})> goals;

  @override
  State<_ImportMaterialDialog> createState() => _ImportMaterialDialogState();
}

class _ImportMaterialDialogState extends State<_ImportMaterialDialog> {
  final _title = TextEditingController();
  final _source = TextEditingController();
  final _pageNo = TextEditingController(text: '1');
  final _label = TextEditingController();
  final _content = TextEditingController();
  MaterialKind _kind = MaterialKind.slides;
  GoalChoice _goal = GoalChoice.unassigned;
  String? _titleError;
  String? _contentError;

  @override
  void dispose() {
    _title.dispose();
    _source.dispose();
    _pageNo.dispose();
    _label.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final content = _content.text.trim();
    setState(() {
      _titleError = title.isEmpty ? '填一个材料名称再保存。' : null;
      _contentError = content.isEmpty ? '粘贴至少一页原文后保存。' : null;
    });
    if (_titleError != null || _contentError != null) return;
    final pageNo = int.tryParse(_pageNo.text.trim()) ?? 1;
    Navigator.of(context).pop([
      _MaterialDraft(
        title: title,
        kind: _kind,
        pageNo: pageNo <= 0 ? 1 : pageNo,
        content: content,
        sourceRef: nullableText(_source.text),
        label: nullableText(_label.text),
        goalId: _goal.goalId,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: const Text('导入材料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(
              controller: _title,
              onChange: (_) {
                if (_titleError != null) setState(() => _titleError = null);
              },
            ),
            label: const Text('材料名称'),
            hint: '概率论第 12 讲课件',
          ),
          if (_titleError != null) _fieldError(theme, _titleError!),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<MaterialKind>(
            value: _kind,
            label: '类型',
            options: {
              for (final kind in MaterialKind.values)
                if (kind != MaterialKind.unknown) kind: kind.label,
            },
            onChange: (value) =>
                setState(() => _kind = value ?? MaterialKind.slides),
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _source),
            label: const Text('出处（可选）'),
            hint: '教材第 8 章，或文件与页码说明',
          ),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<GoalChoice>(
            value: _goal,
            label: goalSelectLabel,
            options: goalChoiceOptionsFrom(widget.goals),
            onChange: (value) =>
                setState(() => _goal = value ?? GoalChoice.unassigned),
          ),
          SizedBox(height: theme.space.gap),
          Row(
            children: [
              SizedBox(
                width: 80,
                child: forui.FTextField(
                  control: .managed(controller: _pageNo),
                  keyboardType: TextInputType.number,
                  label: const Text('页码'),
                ),
              ),
              SizedBox(width: theme.space.sm),
              Expanded(
                child: forui.FTextField(
                  control: .managed(controller: _label),
                  label: const Text('章节或标题（可选）'),
                ),
              ),
            ],
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
            minLines: 4,
            maxLines: 10,
            label: const Text('页面原文'),
            hint: '先粘贴当前问题涉及的那一页，其他内容再逐步补充。',
          ),
          if (_contentError != null) _fieldError(theme, _contentError!),
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

class _PageDialog extends StatefulWidget {
  const _PageDialog({required this.material, required this.pageNumbers});

  final Material material;

  /// 这份材料已有的页码；添加时遇到它们就停在这里，不改写原文。
  final Set<int> pageNumbers;

  @override
  State<_PageDialog> createState() => _PageDialogState();
}

class _PageDialogState extends State<_PageDialog> {
  final _pageNo = TextEditingController();
  final _label = TextEditingController();
  final _content = TextEditingController();
  String? _pageNoError;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _pageNo.text = '${widget.material.pageCount + 1}';
  }

  @override
  void dispose() {
    _pageNo.dispose();
    _label.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final content = _content.text.trim();
    final pageNo = int.tryParse(_pageNo.text.trim()) ?? 0;
    setState(() {
      _contentError = content.isEmpty ? '粘贴这一页的原文再保存。' : null;
      if (pageNo <= 0) {
        _pageNoError = '页码从 1 开始。';
      } else if (widget.pageNumbers.contains(pageNo)) {
        _pageNoError = '第 $pageNo 页已有原文。要改这一页，请取消后到材料详情点「更正这一页」。';
      } else {
        _pageNoError = null;
      }
    });
    if (_pageNoError != null || _contentError != null) return;
    Navigator.of(context).pop(
      _PageDraft(
        pageNo: pageNo,
        content: content,
        label: nullableText(_label.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: Text('给《${widget.material.title}》加一页'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 80,
                child: forui.FTextField(
                  control: .managed(
                    controller: _pageNo,
                    onChange: (_) {
                      if (_pageNoError != null) {
                        setState(() => _pageNoError = null);
                      }
                    },
                  ),
                  keyboardType: TextInputType.number,
                  label: const Text('页码'),
                ),
              ),
              SizedBox(width: theme.space.sm),
              Expanded(
                child: forui.FTextField(
                  control: .managed(controller: _label),
                  label: const Text('章节或标题（可选）'),
                ),
              ),
            ],
          ),
          // 页码错误属于这一项，就写在字段下方，不挪到 InlineNotice。
          if (_pageNoError != null) _fieldError(theme, _pageNoError!),
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
            minLines: 4,
            maxLines: 10,
            label: const Text('页面原文'),
          ),
          if (_contentError != null) _fieldError(theme, _contentError!),
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
