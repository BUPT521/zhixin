import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'date_time_dialogs.dart';
import 'format.dart';
import 'zhixin_dialog.dart';

/// 新建目标的一次输入。
class GoalDraft {
  const GoalDraft({required this.title, this.scope, this.dueDate});

  final String title;
  final String? scope;
  final DateTime? dueDate;
}

/// 创建目标时不改变其他目标的状态。
Future<GoalDraft?> showGoalDialog(BuildContext context) {
  return showZhixinDialog<GoalDraft>(
    context: context,
    builder: (_) => const _GoalDialog(),
  );
}

class _GoalDialog extends StatefulWidget {
  const _GoalDialog();

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  final _title = TextEditingController();
  final _scope = TextEditingController();
  DateTime? _due;

  @override
  void dispose() {
    _title.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ZhixinDialogLayout(
      title: const Text('新建学习目标'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(controller: _title),
            label: const Text('目标名称'),
            hint: '周五前完成极限章节作业',
          ),
          const SizedBox(height: 8),
          forui.FTextField(
            control: .managed(controller: _scope),
            label: const Text('相关材料范围（可选）'),
            hint: '教材第 8 章',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () async {
                  final now = AppScope.of(context).timePolicy.now;
                  final picked = await showZhixinDatePicker(
                    context: context,
                    initialDate: _due ?? now,
                    firstDate: now,
                    lastDate: DateTime(now.year + 10, now.month, now.day),
                  );
                  if (context.mounted && picked != null) {
                    setState(() => _due = picked);
                  }
                },
                child: Text(_due == null ? '选择截止日期（可选）' : dateText(_due)),
              ),
              if (_due != null)
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() => _due = null),
                  child: const Text('清除日期'),
                ),
            ],
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
            Navigator.of(context).pop(
              GoalDraft(
                title: title,
                scope: _scope.text.trim().isEmpty ? null : _scope.text.trim(),
                dueDate: _due,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
