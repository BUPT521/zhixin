import 'package:file_picker/file_picker.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material, MaterialPage;

import '../app_scope.dart';
import '../application/docx_import.dart';
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
import 'zhixin_select.dart';
import 'zhixin_toast.dart';

/// 记录页的材料分组：按材料查看页码，导入新的一份或补充一页。
class MaterialList extends StatefulWidget {
  const MaterialList({super.key});

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
    setState(() => _stream = _createStream());
  }

  void _reportReadFailure(Object error, StackTrace stack) {
    if (!mounted) return;
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

  Future<void> _import() async {
    final scope = AppScope.of(context);
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

  Future<void> _addPage(Material material) async {
    final scope = AppScope.of(context);
    final List<MaterialPage> pages;
    try {
      pages = await scope.library.material.pages(material.id);
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
      await scope.library.material.addPage(
        materialId: material.id,
        pageNo: draft.pageNo,
        content: draft.content,
        label: draft.label,
      );
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
    return LiveView<List<Material>>(
      stream: _stream,
      onError: _reportReadFailure,
      builder: (context, materials, loading) {
        final list = materials ?? const <Material>[];
        final canImport = !loading && !_importingWord;
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
                    onPress: canImport ? _import : null,
                    child: const Text('导入材料'),
                  ),
                  const SizedBox(width: 4),
                  forui.FButton(
                    variant: forui.FButtonVariant.secondary,
                    mainAxisSize: MainAxisSize.min,
                    onPress: canImport ? _importWord : null,
                    child: const Text('导入 Word'),
                  ),
                ],
              ),
            ),
            if (_importingWord) const forui.FProgress(),
            Expanded(
              child: loading
                  ? SingleChildScrollView(
                      child: ListSkeleton(
                        rowHeight: 73,
                        padding: theme.space.pageInsets(),
                      ),
                    )
                  : list.isEmpty
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
                      padding: theme.space.pageInsets(),
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(height: context.zhixin.space.gap),
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
                                  onPressed: () => _addPage(material),
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
          SizedBox(height: context.zhixin.space.gap),
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
          SizedBox(height: context.zhixin.space.gap),
          forui.FTextField(
            control: .managed(controller: _source),
            label: const Text('出处（可选）'),
            hint: '教材第 8 章，或文件与页码说明',
          ),
          SizedBox(height: context.zhixin.space.gap),
          ZhixinSelect<GoalChoice>(
            value: _goal,
            label: goalSelectLabel,
            options: goalChoiceOptionsFrom(widget.goals),
            onChange: (value) =>
                setState(() => _goal = value ?? GoalChoice.unassigned),
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
                sourceRef: nullableText(_source.text),
                label: nullableText(_label.text),
                goalId: _goal.goalId,
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
              const SizedBox(width: 8),
              Expanded(
                child: forui.FTextField(
                  control: .managed(controller: _label),
                  label: const Text('章节或标题（可选）'),
                ),
              ),
            ],
          ),
          // 表单字段的校验就地写红字：错误属于这一页的页码，移到 InlineNotice
          // 会离开字段所在的位置，用户看不出是哪一项没通过。
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
