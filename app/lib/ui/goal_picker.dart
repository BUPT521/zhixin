import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../domain/models/study.dart';
import 'zhixin_sheet.dart';

/// 一次明确的归属选择；`goalId` 为空表示不归属任何目标。
class GoalChoice {
  const GoalChoice(this.goalId);

  final int? goalId;
}

/// 让用户选择这次内容的归属；列表里始终保留“不归属任何目标”。
///
/// 返回空表示没有选择、直接关掉，调用方不写入任何归属。
Future<GoalChoice?> showGoalChoice(
  BuildContext context, {
  required List<LearningGoal> goals,
  int? initialGoalId,
  String title = '选择目标',
  String note = '可选择一个目标，也可将内容单独保存在记录中。',
}) {
  return showZhixinSheet<GoalChoice>(
    context: context,
    builder: (context) {
      final theme = context.zhixin;
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(title, style: theme.text.titleMedium),
          const SizedBox(height: 4),
          Text(note, style: theme.text.bodySmall),
          const SizedBox(height: 8),
          forui.FTile(
            prefix: Icon(
              initialGoalId == null
                  ? FLucideIcons.circleDot
                  : FLucideIcons.circle,
            ),
            title: const Text('单独记录'),
            subtitle: const Text('独立问题与讨论可直接回答和继续'),
            onPress: () => Navigator.of(context).pop(const GoalChoice(null)),
          ),
          for (final goal in goals)
            forui.FTile(
              prefix: Icon(
                initialGoalId == goal.id
                    ? FLucideIcons.circleDot
                    : FLucideIcons.circle,
              ),
              title: Text(goal.title),
              subtitle: Text(
                '${goal.status.label}${goal.dueDate == null ? '' : ' · 截止 ${goal.dueDate}'}',
              ),
              enabled: goal.active,
              onPress: goal.active
                  ? () => Navigator.of(context).pop(GoalChoice(goal.id))
                  : null,
            ),
        ],
      );
    },
  );
}
