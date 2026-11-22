import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/plan_service.dart';
import '../domain/models/study.dart';
import 'plan_actions.dart';
import 'workspace_widgets.dart';
import 'zhixin_menu.dart';

/// 安排页的目标页签：进行中、已暂停与已结束的目标。
///
/// 页签只接收一周数据与写入动作，暂停与结束的确认都在 [PlanActions] 里。
class PlanGoalsTab extends StatelessWidget {
  const PlanGoalsTab({super.key, required this.week, required this.actions});

  final PlanWeek week;
  final PlanActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return CustomScrollView(
      key: const PageStorageKey<String>('plan-tab-2'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            theme.space.page,
            theme.space.xs,
            theme.space.page,
            theme.space.section,
          ),
          sliver: SliverMainAxisGroup(slivers: _slivers(theme)),
        ),
      ],
    );
  }

  List<Widget> _slivers(ZhixinTheme theme) {
    final header = <Widget>[
      SectionHeading(
        first: true,
        title: '学习目标',
        subtitle: '多个目标可以同时进行',
        action: SectionLink(
          label: '新建',
          icon: FLucideIcons.plus,
          onPressed: () => actions.addGoal(),
        ),
      ),
      if (week.goals.isEmpty)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.flag,
            title: '按需要建立目标',
            description: '持续学习的相关事项可以归入目标，独立问题单独保留。',
          ),
        ),
    ];
    return [
      SliverList.builder(
        itemCount: header.length + week.goals.length,
        itemBuilder: (context, index) => index < header.length
            ? header[index]
            : _goalTile(theme, week.goals[index - header.length]),
      ),
    ];
  }

  Widget _goalTile(ZhixinTheme theme, LearningGoal goal) {
    final paused = goal.status == LearningGoalStatus.paused;
    final scope = goal.scopeText?.trim();
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: LeadingIcon(
          FLucideIcons.flag,
          tone: goal.active
              ? TagTone.accent
              : paused
              ? TagTone.attention
              : TagTone.muted,
        ),
        title: Text(goal.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: theme.space.xs),
            TagRow(
              children: [
                StatusTag(
                  goal.status.label,
                  tone: goal.active
                      ? TagTone.accent
                      : paused
                      ? TagTone.attention
                      : TagTone.muted,
                ),
                if (goal.dueDate != null)
                  StatusTag('截止 ${goal.dueDate}', icon: FLucideIcons.calendar),
              ],
            ),
            if (scope != null && scope.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(
                  scope,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        suffix: moreMenu(
          items: [
            if (goal.active)
              ZhixinMenuItem(
                label: '暂停目标',
                onSelected: () => actions.pauseGoal(goal),
              ),
            if (paused)
              ZhixinMenuItem(
                label: '恢复目标',
                onSelected: () => actions.resumeGoal(goal),
              ),
            ZhixinMenuItem(
              label: '标记结束',
              onSelected: () => actions.closeGoal(goal),
            ),
          ],
        ),
      ),
    );
  }
}
