import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/material.dart';
import '../domain/models/study.dart';
import '../domain/rules/search_terms.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'live_view.dart';
import 'material_find_controller.dart';
import 'materials_list.dart';
import 'navigation.dart';
import 'study_plan_setup.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_menu.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 一份材料的详情：逐页查看、补充、纠正，并从某一页开始讨论。
///
/// 从学习步骤打开时可以只显示这一步的页码，学生先看到本次范围，再决定是否
/// 展开全部材料。Word 材料的片段与普通材料的页码统一由 [Material.position]
/// 给出，详情与引用不再一处叫“片段”、另一处叫“第几页”。
class MaterialDetailPage extends StatefulWidget {
  const MaterialDetailPage({
    super.key,
    required this.materialId,
    this.pageFrom,
    this.pageTo,
    this.stepTitle,
    this.studyPlanId,
    this.planItemId,
  });

  final String materialId;

  /// 本次学习步骤覆盖的页码；为空时显示全部页面。
  final int? pageFrom;
  final int? pageTo;
  final String? stepTitle;

  /// 从学习步骤打开时记下计划与步骤，从这里开始的讨论会绑回这一步。
  final String? studyPlanId;
  final String? planItemId;

  @override
  State<MaterialDetailPage> createState() => _MaterialDetailPageState();
}

class _MaterialDetailPageState extends State<MaterialDetailPage> {
  /// 材料行与页码两条订阅：任一表被写入之后由数据层重读（ADR-0014）。
  ///
  /// 更正一页、补充一页、撤销与改归属之后不再由页面重读；从讨论返回时保持
  /// 当前内容，不另起一次读取。
  Stream<Material?>? _materialStream;
  Stream<List<MaterialPage>>? _pagesStream;
  bool _started = false;
  bool _showAllPages = false;

  /// 两条订阅各自的读取失败说明：任一条的数据到达只清自己那一条，不抢着清。
  String? _materialNotice;
  String? _pagesNotice;

  /// 在材料内查找正文：输入框、命中的位置、当前这一处与翻页。
  ///
  /// 命中计算与序号由 [MaterialFindController] 持有，页面只给输入、订阅读到的
  /// 页面与上一处、下一处，并在命中变化之后滚到对应页。
  final TextEditingController _findField = TextEditingController();
  final MaterialFindController _find = MaterialFindController();
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _pageKeys = {};

  bool get _hasRange => widget.pageFrom != null || widget.pageTo != null;

  /// 按本次学习步骤的页码范围筛出要显示的页；页面本身仍读这份材料的全部页。
  List<MaterialPage> _visiblePages(List<MaterialPage> pages) {
    if (!_hasRange || _showAllPages) return pages;
    final from = widget.pageFrom ?? 1;
    final to = widget.pageTo ?? 1 << 30;
    return pages
        .where((page) => page.pageNo >= from && page.pageNo <= to)
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _find.onJumpRequested = _scheduleJump;
    _find.addListener(_onFindChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _subscribe();
  }

  void _subscribe() {
    final service = AppScope.of(context).library.material;
    _materialStream = service.watchMaterial(widget.materialId);
    _pagesStream = service.watchPages(widget.materialId);
  }

  @override
  void dispose() {
    _find.removeListener(_onFindChanged);
    _find.dispose();
    _findField.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFindChanged() {
    if (mounted) setState(() {});
  }

  /// 输入停下之后再在材料内找一次，免得每敲一个字都把全部页面扫一遍。
  void _onFindInput(String text) {
    setState(() {});
    _find.onInputChanged(text);
  }

  /// 生效这次查询，并把当前一处定位到第一处命中。
  void _applyFind(String text) => _find.apply(text);

  /// 清空材料内查找；查询与高亮一起撤掉，页面回到原来的样子。
  void _clearFind() {
    _findField.clear();
    _find.clear();
  }

  /// 上一处、下一处；到头之后从另一头继续，按键始终可用。
  void _stepFind(int delta) => _find.step(delta);

  /// 命中变化之后滚到当前这一处；等这一帧排完再量位置。
  void _scheduleJump() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToMatch());
  }

  /// 滚到当前这一处所在的页；命中页在本次范围之外时先展开全部页面。
  Future<void> _jumpToMatch() async {
    if (!mounted) return;
    final match = _find.current;
    if (match == null) return;
    if (!_showAllPages && _hasRange && !_inRange(match.pageNo)) {
      setState(() => _showAllPages = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _scrollToPage(match.pageNo);
  }

  bool _inRange(int pageNo) {
    final from = widget.pageFrom ?? 1;
    final to = widget.pageTo ?? 1 << 30;
    return pageNo >= from && pageNo <= to;
  }

  /// 滚到某一页：已经建出来的页直接精确对齐，远处的页先按页序滚过去再对齐。
  Future<void> _scrollToPage(int pageNo) async {
    final key = _pageKeys.putIfAbsent(pageNo, () => GlobalKey());
    final built = key.currentContext;
    if (built != null) {
      await Scrollable.ensureVisible(
        built,
        alignment: 0.05,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
      return;
    }
    final pages = _visiblePages(_find.pages);
    final index = pages.indexWhere((page) => page.pageNo == pageNo);
    if (index < 0 || !_scroll.hasClients) return;
    // ListView 只建可视范围附近的页：先按页序滚到大致位置，让目标页进入
    // 建树范围，再精确对到这一页。
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent * index / (pages.length + 1),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final after = key.currentContext;
    if (after != null && after.mounted) {
      await Scrollable.ensureVisible(
        after,
        alignment: 0.05,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
  }

  /// 读取失败后的重试：换两条新流，读到结果之前保留已经显示的内容。
  void _reload() {
    setState(() {
      _materialNotice = null;
      _pagesNotice = null;
      _subscribe();
    });
  }

  void _clearMaterialNotice() {
    if (_materialNotice == null) return;
    setState(() => _materialNotice = null);
  }

  void _clearPagesNotice() {
    if (_pagesNotice == null) return;
    setState(() => _pagesNotice = null);
  }

  void _reportMaterialFailure(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取这份材料',
      kind: 'material_detail_read',
      kept: '材料与页面没有改动',
      next: '可以点重试再读一次',
    );
    setState(() => _materialNotice = message);
  }

  void _reportPagesFailure(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取这份材料的页码',
      kind: 'material_pages_read',
      kept: '材料没有改动',
      next: '可以点重试再读一次',
    );
    setState(() => _pagesNotice = message);
  }

  Future<void> _startDiscussion(MaterialPage page, Material material) async {
    final scope = AppScope.of(context);
    try {
      final planId = widget.studyPlanId;
      final itemId = widget.planItemId;
      final id = planId != null && itemId != null
          ? await scope.study.systemPlan.startDiscussionAtStep(
              planId: planId,
              stepId: itemId,
              pageNo: page.pageNo,
            )
          : await scope.chat.discussion.createConversation(
              title: '《${material.title}》${material.position(page.pageNo)}',
              goalId: material.goalId,
              materialId: widget.materialId,
              pageNo: page.pageNo,
            );
      if (!mounted) return;
      await openDiscussion(context, id);
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '从这一页开始讨论',
        kind: 'material_start_discussion',
        kept: '材料与记录没有改动',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  Future<void> _correct(Material material, MaterialPage page) async {
    final scope = AppScope.of(context);
    final controller = TextEditingController(text: page.content);
    final corrected = await showZhixinAlert<String>(
      context: context,
      title: '更正${material.position(page.pageNo)}',
      cancelLabel: '取消',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('更正内容保存后，后续引用会使用新文字；重新提问可获取更新后的引用。'),
          SizedBox(height: context.zhixin.space.gap),
          forui.FTextField(
            control: .managed(controller: controller),
            minLines: 5,
            maxLines: 12,
          ),
        ],
      ),
      actions: [
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(controller.text),
          child: const Text('保存更正'),
        ),
      ],
    );
    if (corrected == null || corrected.trim().isEmpty || !mounted) return;
    try {
      final result = await scope.library.material.correctPage(
        page: page,
        corrected: corrected.trim(),
      );
      if (!mounted) return;
      if (!result.changed) {
        showToast(context, result.skippedReason ?? '这一页的内容没有变化。');
        return;
      }
      showActionToast(
        context,
        '已更正${material.position(page.pageNo)}',
        label: '撤销',
        onPressed: () => _undoCorrection(result.commitId!),
      );
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '保存这一页的更正',
        kind: 'material_page_correct',
        kept: '原文仍是修改前的内容',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  Future<void> _undoCorrection(int commitId, {BuildContext? closeSheet}) {
    return undoCommitWithFeedback(
      context,
      commitId,
      // 撤销写入之后的重读由订阅完成（ADR-0014），这里不再另起一次读取。

      onUndone: () {
        if (closeSheet != null && closeSheet.mounted) {
          Navigator.of(closeSheet).pop();
        }
      },
    );
  }

  Future<void> _showCorrections(Material material, MaterialPage page) async {
    final scope = AppScope.of(context);
    final theme = context.zhixin;
    try {
      final history = await scope.data.revisions.rowHistory(
        table: 'material_page',
        rowKey: page.id,
      );
      final active = await scope.data.revisions.activeCommits(
        history.map((commit) => commit.id),
      );
      if (!mounted) return;
      await showZhixinSheet<void>(
        context: context,
        title: '${material.position(page.pageNo)}的更正记录',
        builder: (sheetContext) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: theme.space.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (history.isEmpty)
                  Text('这一页还没有更正记录。', style: theme.text.bodyMedium)
                else
                  for (final commit in history)
                    Padding(
                      padding: EdgeInsets.only(top: theme.space.tight),
                      child: forui.FTile(
                        title: Text(
                          commit.createdAt == null
                              ? '时间未知'
                              : shortTime(commit.createdAt!),
                        ),
                        subtitle: Text(
                          active.contains(commit.id) ? '更正了这一页' : '已撤销',
                        ),
                        suffix: active.contains(commit.id)
                            ? forui.FButton(
                                variant: forui.FButtonVariant.ghost,
                                mainAxisSize: MainAxisSize.min,
                                onPress: () => _undoCorrection(
                                  commit.id,
                                  closeSheet: sheetContext,
                                ),
                                child: const Text('撤销'),
                              )
                            : null,
                      ),
                    ),
              ],
            ),
          ),
        ),
      );
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取更正记录',
        kind: 'material_corrections_read',
        kept: '材料没有改动',
        next: '可以再打开一次',
      );
      showToast(context, message);
    }
  }

  Future<void> _changeGoal(Material material) async {
    final scope = AppScope.of(context);
    final List<LearningGoal> goals;
    try {
      goals = await scope.study.plan.goals();
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取目标列表',
        kind: 'material_goals_read',
        kept: '材料的归属没有改动',
        next: '可以再试一次',
      );
      showToast(context, message);
      return;
    }
    if (!mounted) return;
    final choice = await showGoalChoice(
      context,
      goals: goals,
      initialGoalId: material.goalId,
      title: '这份材料属于哪个目标',
      note: '可选择目标，也可将材料用于独立讨论。',
    );
    if (choice == null || !mounted) return;
    try {
      final result = await scope.library.material.setGoal(
        material.id,
        choice.goalId,
      );
      if (!mounted) return;
      if (!result.changed) {
        showToast(context, result.skippedReason ?? '归属没有变化。');
        return;
      }
      showToast(context, '已改为「${_goalLabel(goals, choice.goalId)}」');
    } catch (error, stack) {
      if (!mounted) return;
      final message = describeFailure(
        context,
        error,
        stack,
        action: '调整这份材料的归属',
        kind: 'material_set_goal',
        kept: '材料的归属仍是修改前的目标',
        next: '可以再试一次',
      );
      showToast(context, message);
    }
  }

  String _goalLabel(List<LearningGoal> goals, String? goalId) {
    if (goalId == null) return goalUnassigned;
    for (final goal in goals) {
      if (goal.id == goalId) return goal.title;
    }
    return goalUnassigned;
  }

  /// 本次范围的页码；Word 材料按片段说。
  String _rangeLabel(Material material) =>
      material.position(widget.pageFrom, to: widget.pageTo);

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LiveView<Material?>(
      stream: _materialStream,
      onError: _reportMaterialFailure,
      onData: (_) => _clearMaterialNotice(),
      builder: (context, material, loading) => DetailScaffold(
        header: ZhixinHeader(
          title: Text(material?.title ?? '材料'),
          showBack: true,
          actions: [
            if (material != null) ...[
              ZhixinHeaderAction(
                icon: FLucideIcons.route,
                tooltip: '系统学习',
                onPressed: () =>
                    showStudyPlanSetup(context, material: material),
              ),
              ZhixinHeaderButton(
                label: '归属',
                onPressed: () => _changeGoal(material),
              ),
            ],
          ],
        ),
        child: loading
            ? ListView(
                padding: theme.space.pageInsets(),
                children: [
                  if (_materialNotice != null)
                    InlineNotice(message: _materialNotice!, onRetry: _reload),
                  const ListSkeleton(rows: 3),
                ],
              )
            : material == null
            ? ListView(
                padding: theme.space.pageInsets(),
                children: [
                  if (_materialNotice != null)
                    InlineNotice(message: _materialNotice!, onRetry: _reload),
                  EmptyState(
                    icon: FLucideIcons.fileText,
                    title: '未找到这份材料',
                    description: '它可能已经被删除，可以返回材料列表重新选择。',
                    action: forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => Navigator.maybePop(context),
                      child: const Text('返回'),
                    ),
                  ),
                ],
              )
            : LiveView<List<MaterialPage>>(
                stream: _pagesStream,
                onError: _reportPagesFailure,
                onData: (pages) {
                  // 命中按订阅读到的页面重算，不在排版时改状态。
                  _find.updatePages(pages);
                  _clearPagesNotice();
                },
                builder: (context, pages, pagesLoading) =>
                    _body(theme, material, pages, pagesLoading),
              ),
      ),
    );
  }

  /// 材料信息与逐页原文；首读页码时先放与页面卡片同高的骨架。
  ///
  /// 有原文时顶部多一行材料内查找：命中数量与当前是第几处固定在列表上方，
  /// 上一处、下一处滚到对应页；每页正文里的命中按页高亮，继续向下翻也能看到。
  Widget _body(
    ZhixinTheme theme,
    Material material,
    List<MaterialPage>? pages,
    bool loading,
  ) {
    final all = pages ?? const <MaterialPage>[];
    final visible = loading ? const <MaterialPage>[] : _visiblePages(all);
    // 材料信息固定在最前面，页面正文按需构建：只有滚到附近的一页才解析与排版
    // 自己的整段原文，打开几十页的材料时首帧开销与页数无关；列表外层只放一个
    // 选择区，逐页的 SelectableText 换成普通 Text，每页不再各带一套选择状态。
    final leading = <Widget>[
      if (_materialNotice != null)
        InlineNotice(message: _materialNotice!, onRetry: _reload),
      if (_pagesNotice != null)
        InlineNotice(message: _pagesNotice!, onRetry: _reload),
      TagRow(
        children: [
          StatusTag(material.kindLabel),
          _GoalTag(material: material),
          if (material.sourceRef != null)
            StatusTag(material.sourceRef!, tone: TagTone.muted),
        ],
      ),
      if (_hasRange) ...[
        SizedBox(height: theme.space.gap),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.stepTitle ?? '本次学习步骤',
                  style: theme.text.titleSmall,
                ),
                SizedBox(height: theme.space.xs),
                Text(
                  '本次范围：${_rangeLabel(material)}',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() => _showAllPages = !_showAllPages),
                  child: Text(_showAllPages ? '只看本次范围' : '查看全部页面'),
                ),
              ],
            ),
          ),
        ),
      ],
      SizedBox(height: theme.space.gap),
    ];
    final tail = loading || all.isEmpty || visible.isEmpty ? 1 : visible.length;
    return Column(
      children: [
        if (!loading && all.isNotEmpty) _findBar(theme),
        Expanded(
          child: SelectionArea(
            child: ListView.builder(
              controller: _scroll,
              padding: theme.space.pageInsets(),
              itemCount: leading.length + tail,
              itemBuilder: (context, index) {
                if (index < leading.length) return leading[index];
                if (loading) return const ListSkeleton(rows: 3);
                if (all.isEmpty) {
                  return EmptyState(
                    icon: FLucideIcons.fileText,
                    title: '这份材料还没有原文',
                    description: material.isDocx
                        ? 'Word 材料的片段随导入写入，这里不逐段添加；可以重新导入一份。'
                        : '补充这一页的原文之后，可以引用原文或从这一页开始讨论。',
                    action: material.isDocx
                        ? null
                        : forui.FButton(
                            mainAxisSize: MainAxisSize.min,
                            onPress: () => addMaterialPage(context, material),
                            prefix: const Icon(FLucideIcons.filePlus),
                            child: const Text('添加一页'),
                          ),
                  );
                }
                if (visible.isEmpty) {
                  return EmptyState(
                    icon: FLucideIcons.fileText,
                    title: '这一步的页码还没有原文',
                    description: '可以查看全部页面，或先补充这一页。',
                    action: material.isDocx
                        ? null
                        : forui.FButton(
                            variant: forui.FButtonVariant.outline,
                            mainAxisSize: MainAxisSize.min,
                            onPress: () => addMaterialPage(context, material),
                            child: const Text('添加一页'),
                          ),
                  );
                }
                return _pageCard(
                  theme,
                  material,
                  visible[index - leading.length],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 材料内查找：输入框、命中计数与上一处、下一处；没有命中时保留查询并给清除。
  Widget _findBar(ZhixinTheme theme) {
    final matches = _find.matches;
    final hasQuery = _find.hasQuery;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.page,
        theme.space.xs,
        theme.space.page,
        0,
      ),
      child: Column(
        children: [
          forui.FTextField(
            key: const ValueKey('material-find-entry'),
            control: .managed(
              controller: _findField,
              onChange: (value) => _onFindInput(value.text),
            ),
            textInputAction: TextInputAction.search,
            onSubmit: _applyFind,
            hint: '在本材料内查找正文',
            prefixBuilder: (context, style, variants) =>
                forui.FTextField.prefixIconBuilder(
                  context,
                  style,
                  variants,
                  const Icon(FLucideIcons.search, size: 16),
                ),
            suffixBuilder: (_, style, _) => _findField.text.isEmpty
                ? const SizedBox.shrink()
                : ZhixinIconButton(
                    tooltip: '清除查找',
                    onPressed: _clearFind,
                    icon: FLucideIcons.x,
                    size: forui.FButtonSizeVariant.sm,
                    style: style.clearButtonStyle,
                  ),
          ),
          if (hasQuery)
            Padding(
              padding: EdgeInsets.only(top: theme.space.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      matches.isEmpty
                          ? '没有找到「${_find.query}」'
                          : '第 ${_find.index + 1} 处 / 共 ${matches.length} 处',
                      style: theme.text.bodySmall,
                    ),
                  ),
                  if (matches.isEmpty)
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _clearFind,
                      child: const Text('清除查找'),
                    )
                  else ...[
                    ZhixinIconButton(
                      tooltip: '上一处',
                      onPressed: () => _stepFind(-1),
                      icon: FLucideIcons.chevronUp,
                      size: forui.FButtonSizeVariant.sm,
                    ),
                    ZhixinIconButton(
                      tooltip: '下一处',
                      onPressed: () => _stepFind(1),
                      icon: FLucideIcons.chevronDown,
                      size: forui.FButtonSizeVariant.sm,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _pageCard(ZhixinTheme theme, Material material, MaterialPage page) {
    final pageKey = _pageKeys.putIfAbsent(page.pageNo, () => GlobalKey());
    return Padding(
      key: pageKey,
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${material.position(page.pageNo)}'
                '${page.label == null ? '' : ' · ${page.label}'}',
                style: theme.text.labelLarge,
              ),
              SizedBox(height: theme.space.tight),
              _pageContent(theme, page),
              SizedBox(height: theme.space.sm),
              // 每页只有一个主操作；更正与记录收进菜单，卡片底部不再并排三个按钮。
              Row(
                children: [
                  forui.FButton(
                    variant: forui.FButtonVariant.outline,
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _startDiscussion(page, material),
                    child: const Text('讨论这一页'),
                  ),
                  const Spacer(),
                  moreMenu(
                    items: [
                      ZhixinMenuItem(
                        label: '更正这一页',
                        onSelected: () => _correct(material, page),
                      ),
                      ZhixinMenuItem(
                        label: '更正记录',
                        onSelected: () => _showCorrections(material, page),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一页的正文：没有查找时按原样显示，有查找时把每一处命中标出来。
  ///
  /// 正文用普通 [Text]，选中与复制交给列表外层同一个 [SelectionArea]：
  /// `SelectableText` 每页各建一套文本选择状态，一页原文很长时还要为选中
  /// 再排版一遍，逐页构建之后这部分开销可以省掉。
  Widget _pageContent(ZhixinTheme theme, MaterialPage page) {
    if (!_find.hasQuery) {
      return Text(page.content, style: theme.text.bodyMedium);
    }
    return Text.rich(
      TextSpan(children: _highlightSpans(theme, page)),
      style: theme.text.bodyMedium,
    );
  }

  /// 一页正文按命中位置切成若干段，当前这一处用留意色，其余命中用主色浅底。
  List<InlineSpan> _highlightSpans(ZhixinTheme theme, MaterialPage page) {
    final content = page.content;
    final query = _find.query;
    final positions = literalOccurrences(content, query);
    if (positions.isEmpty) return [TextSpan(text: content)];
    final current = _find.current;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final start in positions) {
      if (start > cursor) {
        spans.add(TextSpan(text: content.substring(cursor, start)));
      }
      final end = start + query.length;
      final isCurrent =
          current != null &&
          current.pageNo == page.pageNo &&
          current.start == start;
      spans.add(
        TextSpan(
          text: content.substring(start, end),
          style: TextStyle(
            backgroundColor: isCurrent
                ? theme.colors.attentionContainer
                : theme.colors.primaryContainer,
            color: isCurrent ? theme.colors.onAttentionContainer : null,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < content.length) {
      spans.add(TextSpan(text: content.substring(cursor)));
    }
    return spans;
  }
}

/// 材料当前归属的目标名：归属只存标识，目标改名之后这里跟着订阅重读。
class _GoalTag extends StatefulWidget {
  const _GoalTag({required this.material});

  final Material material;

  @override
  State<_GoalTag> createState() => _GoalTagState();
}

class _GoalTagState extends State<_GoalTag> {
  Stream<List<LearningGoal>>? _stream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stream ??= AppScope.of(context).study.plan.watchGoals();
  }

  @override
  Widget build(BuildContext context) {
    return LiveView<List<LearningGoal>>(
      stream: _stream,
      builder: (context, goals, loading) {
        final goalId = widget.material.goalId;
        if (goalId == null) {
          return const StatusTag('无归属', tone: TagTone.muted);
        }
        String? title;
        for (final goal in goals ?? const <LearningGoal>[]) {
          if (goal.id == goalId) {
            title = goal.title;
            break;
          }
        }
        return StatusTag(
          title == null ? (loading ? '目标' : '目标：已删除') : '目标：$title',
        );
      },
    );
  }
}
