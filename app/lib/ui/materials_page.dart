import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/material.dart';
import '../domain/models/study.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'live_view.dart';
import 'materials_list.dart';
import 'navigation.dart';
import 'study_plan_setup.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
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
  /// 材料行与页码各一条订阅：任一表被写入之后由数据层重读（ADR-0014）。
  ///
  /// 更正一页、补充一页、撤销与改归属之后不再由页面重读；从讨论返回时保持
  /// 当前内容，不另起一次读取。
  Stream<Material?>? _materialStream;
  Stream<List<MaterialPage>>? _pagesStream;
  bool _started = false;
  bool _showAllPages = false;

  /// 读取失败时就地说明；已经显示的材料与页面保持上一份。
  String? _notice;

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

  /// 读取失败后的重试：换两条新流，读到结果之前保留已经显示的内容。
  void _reload() {
    setState(() {
      _notice = null;
      _subscribe();
    });
  }

  void _clearNotice() {
    if (_notice == null) return;
    setState(() => _notice = null);
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
    setState(() => _notice = message);
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
    setState(() => _notice = message);
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
                    forui.FTile(
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
      onData: (_) => _clearNotice(),
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
                  if (_notice != null)
                    InlineNotice(message: _notice!, onRetry: _reload),
                  const ListSkeleton(rows: 3),
                ],
              )
            : material == null
            ? ListView(
                padding: theme.space.pageInsets(),
                children: [
                  if (_notice != null)
                    InlineNotice(message: _notice!, onRetry: _reload),
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
                onData: (_) => _clearNotice(),
                builder: (context, pages, pagesLoading) =>
                    _body(theme, material, pages, pagesLoading),
              ),
      ),
    );
  }

  /// 材料信息与逐页原文；首读页码时先放与页面卡片同高的骨架。
  Widget _body(
    ZhixinTheme theme,
    Material material,
    List<MaterialPage>? pages,
    bool loading,
  ) {
    final all = pages ?? const <MaterialPage>[];
    final visible = loading ? const <MaterialPage>[] : _visiblePages(all);
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        if (_notice != null) InlineNotice(message: _notice!, onRetry: _reload),
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
                    onPress: () =>
                        setState(() => _showAllPages = !_showAllPages),
                    child: Text(_showAllPages ? '只看本次范围' : '查看全部页面'),
                  ),
                ],
              ),
            ),
          ),
        ],
        SizedBox(height: theme.space.gap),
        if (loading)
          const ListSkeleton(rows: 3)
        else if (all.isEmpty)
          EmptyState(
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
          )
        else if (visible.isEmpty)
          EmptyState(
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
          )
        else
          for (final page in visible) _pageCard(theme, material, page),
      ],
    );
  }

  Widget _pageCard(ZhixinTheme theme, Material material, MaterialPage page) {
    return Padding(
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
              SelectableText(page.content, style: theme.text.bodyMedium),
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
