import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'study_plan_setup.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 一份材料的详情：逐页查看、补充、纠正，并从某一页开始讨论。
///
/// 从学习步骤打开时可以只显示这一步的页码，学生先看到本次范围，再决定是否
/// 展开全部材料。
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
    final service = AppScope.of(context).library.material;
    _materialStream = service.watchMaterial(widget.materialId);
    _pagesStream = service.watchPages(widget.materialId);
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
      next: '可以返回再打开',
    );
    showToast(context, message);
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
      next: '可以返回再打开',
    );
    showToast(context, message);
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
              title: '《${material.title}》第 ${page.pageNo} 页',
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

  Future<void> _correct(MaterialPage page) async {
    final scope = AppScope.of(context);
    final controller = TextEditingController(text: page.content);
    final corrected = await showZhixinAlert<String>(
      context: context,
      title: '更正第 ${page.pageNo} 页',
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
    final pageNo = page.pageNo;
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
        '已更正第 $pageNo 页',
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

  Future<void> _showCorrections(MaterialPage page) async {
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
        builder: (sheetContext) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('第 ${page.pageNo} 页的更正记录', style: theme.text.titleMedium),
                SizedBox(height: context.zhixin.space.gap),
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
    final goals = await scope.study.plan.goals();
    if (!mounted) return;
    final choice = await showGoalChoice(
      context,
      goals: goals,
      initialGoalId: material.goalId,
      title: '这份材料属于哪个目标',
      note: '可选择目标，也可将材料用于独立讨论。',
    );
    if (choice == null || !mounted) return;
    await scope.library.material.setGoal(material.id, choice.goalId);
  }

  String _rangeLabel() {
    final from = widget.pageFrom;
    final to = widget.pageTo;
    if (from == null) return '第 $to 页';
    if (to == null || to == from) return '第 $from 页';
    return '第 $from–$to 页';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LiveView<Material?>(
      stream: _materialStream,
      onError: _reportMaterialFailure,
      builder: (context, material, loading) {
        if (loading) return const DetailScaffold(child: PageLoading());
        if (material == null) {
          return const DetailScaffold(
            header: ZhixinHeader(title: Text('材料'), showBack: true),
            child: Center(child: Text('未找到这份材料')),
          );
        }
        return DetailScaffold(
          header: ZhixinHeader(
            title: Text(material.title),
            showBack: true,
            actions: [
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
          ),
          child: LiveView<List<MaterialPage>>(
            stream: _pagesStream,
            onError: _reportPagesFailure,
            builder: (context, pages, pagesLoading) =>
                _body(theme, material, pages, pagesLoading),
          ),
        );
      },
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
        Text(
          '${material.kindLabel}'
          '${material.sourceRef == null ? '' : ' · ${material.sourceRef}'}',
          style: theme.text.bodySmall,
        ),
        if (_hasRange) ...[
          SizedBox(height: context.zhixin.space.gap),
          forui.FCard(
            style: .delta(
              decoration: .shapeDelta(color: theme.colors.secondaryContainer),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.stepTitle ?? '本次学习步骤',
                    style: theme.text.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '本次范围：${_rangeLabel()}'
                    '${_showAllPages ? ' · 正在查看全部页面' : ''}',
                    style: theme.text.bodySmall,
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
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
        SizedBox(height: context.zhixin.space.gap),
        if (loading)
          const ListSkeleton(rows: 3)
        else if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('这份材料还没有页面。选择“添加一页”以补充原文。'),
          )
        else if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '这一步的页码还没有保存原文。可以查看全部页面，或先补充这一页。',
              style: theme.text.bodyMedium,
            ),
          )
        else
          for (final page in visible) _pageCard(theme, page, material),
      ],
    );
  }

  Widget _pageCard(ZhixinTheme theme, MaterialPage page, Material material) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: forui.FCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '第 ${page.pageNo} 页${page.label == null ? '' : ' · ${page.label}'}',
                style: theme.text.labelLarge,
              ),
              const SizedBox(height: 6),
              SelectableText(page.content, style: theme.text.bodyMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _startDiscussion(page, material),
                    child: const Text('从这里开始讨论'),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _correct(page),
                    child: const Text('更正这一页'),
                  ),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _showCorrections(page),
                    child: const Text('更正记录'),
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
