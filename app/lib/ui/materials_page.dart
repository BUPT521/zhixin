import 'package:file_picker/file_picker.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import 'theme.dart';

import '../app_scope.dart';
import '../application/docx_import.dart';
import '../domain/models/material.dart';
import 'discussion_page.dart';
import 'docx_review_dialog.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'study_plan_page.dart';
import 'undo_feedback.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_icon_button.dart';
import 'zhixin_select.dart';
import 'zhixin_sheet.dart';
import 'zhixin_toast.dart';

/// 记录页的材料分组：按材料查看页码，导入新的一份或补充一页。
class MaterialList extends StatefulWidget {
  const MaterialList({super.key, required this.isActive});

  final bool isActive;

  @override
  State<MaterialList> createState() => MaterialListState();
}

class MaterialListState extends State<MaterialList> {
  List<Material> _materials = const [];
  List<({int id, String title, bool active})> _goals = const [];
  bool _loading = true;
  bool _started = false;
  bool _importingWord = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    reload();
  }

  @override
  void didUpdateWidget(covariant MaterialList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) reload();
  }

  Future<void> reload() async {
    final scope = AppScope.of(context);
    try {
      final materials = await scope.materialService.list();
      final goals = await scope.tasks.goals();
      if (!mounted) return;
      setState(() {
        _materials = materials;
        _goals = [
          for (final goal in goals)
            (id: goal.id, title: goal.title, active: goal.active),
        ];
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _loading = false);
      final message = describeFailure(
        context,
        error,
        stack,
        action: '读取材料列表',
        kind: 'materials_read',
        kept: '已有的材料没有改动',
        next: '可以点刷新再试',
      );
      showToast(context, message);
    }
  }

  Future<void> _import() async {
    final scope = AppScope.of(context);
    final drafts = await showZhixinDialog<List<_MaterialDraft>>(
      context: context,
      builder: (_) => _ImportMaterialDialog(goals: _goals),
    );
    if (drafts == null || drafts.isEmpty || !mounted) return;
    try {
      final first = drafts.first;
      final id = await scope.materialService.importMaterial(
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
    final service = AppScope.of(context).materialService;
    final expectedEpoch = service.dataEpoch();
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
      final selection = await showDocxReview(
        context,
        document: document,
        goals: _goals,
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

  Future<void> _openImportedMaterial(int id) async {
    await reload();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MaterialDetailPage(materialId: id),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> _addPage(Material material) async {
    final scope = AppScope.of(context);
    final List<MaterialPage> pages;
    try {
      pages = await scope.materialService.pages(material.id);
    } catch (error, stack) {
      if (!mounted) return;
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
    if (!mounted) return;
    final draft = await showZhixinDialog<_PageDraft>(
      context: context,
      builder: (_) => _PageDialog(
        material: material,
        pageNumbers: {for (final page in pages) page.pageNo},
      ),
    );
    if (draft == null || !mounted) return;
    try {
      await scope.materialService.addPage(
        materialId: material.id,
        pageNo: draft.pageNo,
        content: draft.content,
        label: draft.label,
      );
      await reload();
    } on PageNumberTaken catch (error) {
      if (!mounted) return;
      final message = '$error。要改这一页，请打开材料详情点「更正这一页」。';
      showToast(context, message);
    } catch (error, stack) {
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    if (_loading) {
      return const Center(child: forui.FCircularProgress());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              Text('材料', style: theme.text.titleSmall),
              const Spacer(),
              forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: _importingWord ? null : _import,
                child: const Text('导入材料'),
              ),
              const SizedBox(width: 4),
              forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: _importingWord ? null : _importWord,
                child: const Text('导入 Word'),
              ),
            ],
          ),
        ),
        if (_importingWord) const LinearProgressIndicator(),
        Expanded(
          child: _materials.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      '选择 .docx 文件或粘贴原文，之后可搜索材料、引用原文或建立学习计划。',
                      textAlign: TextAlign.center,
                      style: theme.text.bodyMedium,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _materials.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final material = _materials[index];
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
                              onPressed: () => _addPage(material),
                              icon: FLucideIcons.filePlus,
                            ),
                          const Icon(FLucideIcons.chevronRight),
                        ],
                      ),
                      onPress: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                MaterialDetailPage(materialId: material.id),
                          ),
                        );
                        await reload();
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

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

  final int materialId;

  /// 本次学习步骤覆盖的页码；为空时显示全部页面。
  final int? pageFrom;
  final int? pageTo;
  final String? stepTitle;

  /// 从学习步骤打开时记下计划与步骤，从这里开始的讨论会绑回这一步。
  final int? studyPlanId;
  final int? planItemId;

  @override
  State<MaterialDetailPage> createState() => _MaterialDetailPageState();
}

class _MaterialDetailPageState extends State<MaterialDetailPage> {
  Material? _material;
  List<MaterialPage> _pages = const [];
  bool _loading = true;
  bool _started = false;
  bool _showAllPages = false;

  bool get _hasRange => widget.pageFrom != null || widget.pageTo != null;

  List<MaterialPage> get _visiblePages {
    if (!_hasRange || _showAllPages) return _pages;
    final from = widget.pageFrom ?? 1;
    final to = widget.pageTo ?? 1 << 30;
    return _pages
        .where((page) => page.pageNo >= from && page.pageNo <= to)
        .toList(growable: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final material = await scope.materialService.byId(widget.materialId);
      final pages = await scope.materialService.pages(widget.materialId);
      if (!mounted) return;
      setState(() {
        _material = material;
        _pages = pages;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _loading = false);
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
  }

  Future<void> _startDiscussion(MaterialPage page) async {
    final scope = AppScope.of(context);
    try {
      final material = _material;
      final planId = widget.studyPlanId;
      final itemId = widget.planItemId;
      final id = planId != null && itemId != null
          ? await scope.studyPlanService.startDiscussionAtStep(
              planId: planId,
              stepId: itemId,
              pageNo: page.pageNo,
            )
          : await scope.discussionService.createConversation(
              title: '《${material?.title ?? '材料'}》第 ${page.pageNo} 页',
              goalId: material?.goalId,
              materialId: widget.materialId,
              pageNo: page.pageNo,
            );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DiscussionPage(conversationId: id),
        ),
      );
      await _load();
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('更正内容保存后，后续引用会使用新文字；重新提问可获取更新后的引用。'),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: controller),
            minLines: 5,
            maxLines: 12,
          ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
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
      final commitId = await scope.materialService.correctPage(
        page: page,
        corrected: corrected.trim(),
      );
      await _load();
      if (!mounted) return;
      if (commitId == null) {
        showToast(context, '这一页的内容没有变化。');
        return;
      }
      showActionToast(
        context,
        '已更正第 $pageNo 页',
        label: '撤销',
        onPressed: () => _undoCorrection(commitId),
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
      reload: _load,
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
      final history = await scope.revisions.rowHistory(
        table: 'material_page',
        rowKey: '${page.id}',
      );
      final active = await scope.revisions.activeCommits(
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
                const SizedBox(height: 8),
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

  Future<void> _changeGoal() async {
    final material = _material;
    if (material == null) return;
    final scope = AppScope.of(context);
    final goals = await scope.tasks.goals();
    if (!mounted) return;
    final choice = await showGoalChoice(
      context,
      goals: goals,
      initialGoalId: material.goalId,
      title: '这份材料属于哪个目标',
      note: '可选择目标，也可将材料用于独立讨论。',
    );
    if (choice == null || !mounted) return;
    await scope.materialService.setGoal(material.id, choice.goalId);
    await _load();
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
    final material = _material;
    if (_loading) {
      return const forui.FScaffold(
        child: Center(child: forui.FCircularProgress()),
      );
    }
    if (material == null) {
      return forui.FScaffold(
        header: const ZhixinHeader(title: Text('材料'), showBack: true),
        child: const Center(child: Text('未找到这份材料')),
      );
    }
    return forui.FScaffold(
      header: ZhixinHeader(
        title: Text(material.title),
        showBack: true,
        actions: [
          ZhixinHeaderAction(
            icon: FLucideIcons.route,
            tooltip: '系统学习',
            onPressed: () => showStudyPlanSetup(context, material: material),
          ),
          ZhixinHeaderButton(label: '归属', onPressed: _changeGoal),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            '${material.kindLabel}'
            '${material.sourceRef == null ? '' : ' · ${material.sourceRef}'}',
            style: theme.text.bodySmall,
          ),
          if (_hasRange) ...[
            const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          if (_pages.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('这份材料还没有页面。选择“添加一页”以补充原文。'),
            )
          else if (_visiblePages.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '这一步的页码还没有保存原文。可以查看全部页面，或先补充这一页。',
                style: theme.text.bodyMedium,
              ),
            ),
          for (final page in _visiblePages) _pageCard(theme, page),
        ],
      ),
    );
  }

  Widget _pageCard(ZhixinTheme theme, MaterialPage page) {
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
                    onPress: () => _startDiscussion(page),
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
  final String kind;
  final int pageNo;
  final String content;
  final String? sourceRef;
  final String? label;
  final int? goalId;
}

class _PageDraft {
  const _PageDraft({required this.pageNo, required this.content, this.label});

  final int pageNo;
  final String content;
  final String? label;
}

/// 导入一份材料：标题、类型、出处与第一页；也可以先只建材料。
class _ImportMaterialDialog extends StatefulWidget {
  const _ImportMaterialDialog({required this.goals});

  final List<({int id, String title, bool active})> goals;

  @override
  State<_ImportMaterialDialog> createState() => _ImportMaterialDialogState();
}

class _ImportMaterialDialogState extends State<_ImportMaterialDialog> {
  final _title = TextEditingController();
  final _source = TextEditingController();
  final _pageNo = TextEditingController(text: '1');
  final _label = TextEditingController();
  final _content = TextEditingController();
  String _kind = 'slides';
  int _goalId = 0;

  @override
  void dispose() {
    _title.dispose();
    _source.dispose();
    _pageNo.dispose();
    _label.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ZhixinDialogLayout(
      title: const Text('导入材料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: _title),
            label: const Text('材料名称'),
            hint: '概率论第 12 讲课件',
          ),
          const SizedBox(height: 8),
          ZhixinSelect<String>(
            value: _kind,
            label: '类型',
            options: const {
              'slides': '课件',
              'book': '教材',
              'text': '文字材料',
              'other': '其他',
            },
            onChange: (value) => setState(() => _kind = value ?? 'slides'),
          ),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: _source),
            label: const Text('出处（可选）'),
            hint: '教材第 8 章，或文件与页码说明',
          ),
          const SizedBox(height: 8),
          ZhixinSelect<int>(
            value: _goalId,
            label: '目标（可选）',
            options: {
              0: '单独记录',
              for (final goal in widget.goals)
                if (goal.active) goal.id: goal.title,
            },
            onChange: (value) => setState(() => _goalId = value ?? 0),
          ),
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
              const SizedBox(width: 8),
              Expanded(
                child: forui.FTextField(
                  control: .managed(controller: _label),
                  label: const Text('章节或标题（可选）'),
                ),
              ),
            ],
          ),
          forui.FTextField(
            control: .managed(controller: _content),
            minLines: 4,
            maxLines: 10,
            label: const Text('页面原文'),
            hint: '先添加当前问题涉及的页面，再逐步补充其他内容。',
          ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            final pageNo = int.tryParse(_pageNo.text.trim()) ?? 1;
            final content = _content.text.trim();
            if (content.isEmpty) {
              showToast(context, '粘贴本页原文，或保存材料后在详情页添加。');
              return;
            }
            Navigator.of(context).pop([
              _MaterialDraft(
                title: title,
                kind: _kind,
                pageNo: pageNo <= 0 ? 1 : pageNo,
                content: content,
                sourceRef: _source.text.trim().isEmpty
                    ? null
                    : _source.text.trim(),
                label: _label.text.trim().isEmpty ? null : _label.text.trim(),
                goalId: _goalId == 0 ? null : _goalId,
              ),
            ]);
          },
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
    if (content.isEmpty) return;
    final pageNo = int.tryParse(_pageNo.text.trim()) ?? 0;
    if (pageNo <= 0) return;
    if (widget.pageNumbers.contains(pageNo)) {
      setState(() {
        _pageNoError = '第 $pageNo 页已有原文。要改这一页，请取消后到材料详情点「更正这一页」。';
      });
      return;
    }
    Navigator.of(context).pop(
      _PageDraft(
        pageNo: pageNo,
        content: content,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
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
              const SizedBox(width: 8),
              Expanded(
                child: forui.FTextField(
                  control: .managed(controller: _label),
                  label: const Text('章节或标题（可选）'),
                ),
              ),
            ],
          ),
          if (_pageNoError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _pageNoError!,
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.error,
                  ),
                ),
              ),
            ),
          forui.FTextField(
            control: .managed(controller: _content),
            minLines: 4,
            maxLines: 10,
            label: const Text('页面原文'),
          ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
