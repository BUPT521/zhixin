import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../application/docx_import.dart';
import '../domain/models/material.dart';
import 'goal_picker.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';
import 'zhixin_select.dart';

/// 导入 .docx 前的确认：名称、归属目标与片段预览。
///
/// 整框与 [ZhixinDialogLayout] 共用标题、正文与按钮排法，名称与归属用 Forui
/// 控件，归属选择与材料、事项用的是同一个 [goalChoiceOptionsFrom]。
Future<({String title, int? goalId})?> showDocxReview(
  BuildContext context, {
  required DocxImport document,
  required List<({int id, String title, bool active})> goals,
}) => showZhixinDialog<({String title, int? goalId})>(
  context: context,
  builder: (context) => _DocxReviewDialog(document: document, goals: goals),
);

class _DocxReviewDialog extends StatefulWidget {
  const _DocxReviewDialog({required this.document, required this.goals});

  final DocxImport document;
  final List<({int id, String title, bool active})> goals;

  @override
  State<_DocxReviewDialog> createState() => _DocxReviewDialogState();
}

class _DocxReviewDialogState extends State<_DocxReviewDialog> {
  late final _title = TextEditingController(
    text: p.basenameWithoutExtension(widget.document.fileName),
  );
  GoalChoice _goal = GoalChoice.unassigned;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.document.sections;
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: const Text('预览 Word 材料'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.document.fileName),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(
              controller: _title,
              onChange: (_) => setState(() {}),
            ),
            label: const Text('材料名称'),
          ),
          if (widget.goals.isNotEmpty) ...[
            SizedBox(height: theme.space.gap),
            ZhixinSelect<GoalChoice>(
              value: _goal,
              label: goalSelectLabel,
              options: goalChoiceOptionsFrom(widget.goals),
              onChange: (value) =>
                  setState(() => _goal = value ?? GoalChoice.unassigned),
            ),
          ],
          SizedBox(height: theme.space.gap),
          Text('${sections.length} 个正文片段', style: theme.text.labelLarge),
          SizedBox(
            height: 180,
            child: ListView.builder(
              primary: false,
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return ExpansionTile(
                  key: PageStorageKey(section.pageNo),
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '${materialPosition(section.pageNo, isDocx: true)}'
                    '${section.label == null ? '' : ' · ${section.label}'}',
                  ),
                  children: [
                    SelectableText(
                      section.content,
                      key: const PageStorageKey('word-preview-text'),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      actions: [
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _title.text.trim().isEmpty
              ? null
              : () =>
                    Navigator.of(context)
                        .pop((title: _title.text.trim(), goalId: _goal.goalId)),
          child: const Text('保存材料'),
        ),
      ],
    );
  }
}
