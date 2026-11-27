import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../domain/models/study.dart';
import '../domain/rules/text.dart';
import 'date_time_dialogs.dart';
import 'format.dart';
import 'goal_picker.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';
import 'zhixin_select.dart';

class ItemDraft {
  const ItemDraft({
    required this.title,
    this.goalId,
    this.note,
    this.dueAt,
    this.minutes,
  });

  final String title;
  final String? goalId;

  /// 一句话说明这次做什么、做到什么程度算完成。
  final String? note;
  final DateTime? dueAt;
  final int? minutes;
}

class ItemDialog extends StatefulWidget {
  const ItemDialog({super.key, required this.goals});

  final List<LearningGoal> goals;

  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _minutes = TextEditingController();
  GoalChoice _goal = GoalChoice.unassigned;
  DateTime? _due;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: const Text('新建学习事项'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          forui.FTextField(
            control: .managed(
              controller: _title,
              onChange: (_) => setState(() {}),
            ),
            label: const Text('事项名称'),
          ),
          SizedBox(height: theme.space.gap),
          ZhixinSelect<GoalChoice>(
            value: _goal,
            label: goalSelectLabel,
            options: goalChoiceOptions(widget.goals),
            onChange: (value) =>
                setState(() => _goal = value ?? GoalChoice.unassigned),
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _note),
            minLines: 1,
            maxLines: 3,
            label: const Text('说明（可选）'),
            hint: '合上笔记重做第 8 题，写清放缩依据',
          ),
          SizedBox(height: theme.space.gap),
          forui.FTextField(
            control: .managed(controller: _minutes),
            keyboardType: TextInputType.number,
            label: const Text('预计时长（分钟，可选）'),
          ),
          SizedBox(height: theme.space.gap),
          // 截止日期与新建目标用同一套写法：选中之后回显日期，旁边可以清除。
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
        cancelZhixinButton(context),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _title.text.trim().isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(
                    ItemDraft(
                      title: _title.text.trim(),
                      goalId: _goal.goalId,
                      note: nullableText(_note.text),
                      dueAt: _due,
                      minutes: int.tryParse(_minutes.text.trim()),
                    ),
                  );
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
