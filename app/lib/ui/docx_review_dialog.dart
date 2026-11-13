import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../application/docx_import.dart';
import '../domain/models/material.dart';

Future<({String title, int? goalId})?> showDocxReview(
  BuildContext context, {
  required DocxImport document,
  required List<({int id, String title, bool active})> goals,
}) => showDialog<({String title, int? goalId})>(
  context: context,
  builder: (_) => _DocxReviewDialog(document: document, goals: goals),
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
  int _goalId = 0;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.document.sections;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('预览 Word 材料'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.document.fileName),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '材料名称'),
            ),
            if (widget.goals.isNotEmpty)
              DropdownButtonFormField<int>(
                initialValue: _goalId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '所属目标'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('无归属')),
                  for (final goal in widget.goals)
                    DropdownMenuItem(value: goal.id, child: Text(goal.title)),
                ],
                onChanged: (value) => _goalId = value ?? 0,
              ),
            const SizedBox(height: 12),
            Text('${sections.length} 个正文片段', style: theme.textTheme.labelLarge),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop((
                  title: _title.text.trim(),
                  goalId: _goalId == 0 ? null : _goalId,
                )),
          child: const Text('保存材料'),
        ),
      ],
    );
  }
}
