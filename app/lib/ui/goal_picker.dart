import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../domain/models/study.dart';
import 'zhixin_sheet.dart';

/// 没有归属时的统一写法；00 与 02 文档都写“无归属”，界面不再写“单独记录”。
const goalUnassigned = '无归属';

/// 表单里选择归属时的标签；选项本身见 [goalChoiceOptions]。
const goalSelectLabel = '目标（可选）';

/// 一次明确的归属选择；`goalId` 为空表示不归属任何目标。
///
/// 选择器、下拉与提交都用这一个容器，页面不再各自用 0 当哨兵。
class GoalChoice {
  const GoalChoice(this.goalId);

  /// 不归属任何目标。
  static const unassigned = GoalChoice(null);

  final String? goalId;

  @override
  bool operator ==(Object other) =>
      other is GoalChoice && other.goalId == goalId;

  @override
  int get hashCode => goalId.hashCode;
}

/// 一个归属选择器的选项：未归属在前，随后是目标。
Map<GoalChoice, String> goalChoiceOptions(Iterable<LearningGoal> goals) => {
  GoalChoice.unassigned: goalUnassigned,
  for (final goal in goals) GoalChoice(goal.id): goal.title,
};

/// 材料导入等处只缓存目标的编号、名称与是否有效，选项只列仍然有效的目标。
Map<GoalChoice, String> goalChoiceOptionsFrom(
  Iterable<({String id, String title, bool active})> goals,
) => {
  GoalChoice.unassigned: goalUnassigned,
  for (final goal in goals)
    if (goal.active) GoalChoice(goal.id): goal.title,
};

/// 让用户选择这次内容的归属；列表里始终保留“不归属任何目标”。
///
/// 返回空表示没有选择、直接关掉，调用方不写入任何归属。
Future<GoalChoice?> showGoalChoice(
  BuildContext context, {
  required List<LearningGoal> goals,
  String? initialGoalId,
  String title = '选择目标',
  String note = '可选择一个目标，也可将内容单独保存在记录中。',
}) {
  return showZhixinSheet<GoalChoice>(
    context: context,
    title: title,
    builder: (context) {
      final theme = context.zhixin;
      return ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          Text(note, style: theme.text.bodySmall),
          SizedBox(height: theme.space.gap),
          forui.FTile(
            prefix: Icon(
              initialGoalId == null
                  ? FLucideIcons.circleDot
                  : FLucideIcons.circle,
            ),
            title: const Text(goalUnassigned),
            subtitle: const Text('独立问题与讨论可直接回答和继续'),
            onPress: () => Navigator.of(context).pop(GoalChoice.unassigned),
          ),
          for (var index = 0; index < goals.length; index++) ...[
            // 上面固定有一张“不归属任何目标”，每个目标都在它或前一个目标之后。
            SizedBox(height: theme.space.sm),
            forui.FTile(
              prefix: Icon(
                initialGoalId == goals[index].id
                    ? FLucideIcons.circleDot
                    : FLucideIcons.circle,
              ),
              title: Text(goals[index].title),
              subtitle: Text(
                '${goals[index].status.label}${goals[index].dueDate == null ? '' : ' · 截止 ${goals[index].dueDate}'}',
              ),
              enabled: goals[index].active,
              onPress: goals[index].active
                  ? () => Navigator.of(context).pop(GoalChoice(goals[index].id))
                  : null,
            ),
          ],
        ],
      );
    },
  );
}
