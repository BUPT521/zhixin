import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/plan_service.dart';
import '../data/revisions/revision_models.dart';
import 'copy.dart';
import 'format.dart';
import 'plan_actions.dart';
import 'workspace_widgets.dart';

/// 安排页的 AI 改动页签：搭子执行过的写入，可以逐条撤销。
class PlanOperationsTab extends StatelessWidget {
  const PlanOperationsTab({
    super.key,
    required this.week,
    required this.actions,
  });

  final PlanWeek week;
  final PlanActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return CustomScrollView(
      key: const PageStorageKey<String>('plan-tab-3'),
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
      const SectionHeading(
        first: true,
        title: aiChanges,
        subtitle: '$buddyName执行过的变更，可以逐条撤销',
      ),
      if (week.operations.isEmpty)
        const forui.FCard(
          child: EmptyState(
            icon: FLucideIcons.history,
            title: emptyChangesTitle,
            description: emptyChangesDescription,
          ),
        ),
    ];
    return [
      SliverList.builder(
        itemCount: header.length + week.operations.length,
        itemBuilder: (context, index) => index < header.length
            ? header[index]
            : _operationTile(theme, week.operations[index - header.length]),
      ),
    ];
  }

  Widget _operationTile(ZhixinTheme theme, RevisionCommit commit) {
    final createdAt = commit.createdAt;
    final changes = commit.changeCount == 1
        ? '1 项变化'
        : '${commit.changeCount} 项变化';
    return Padding(
      padding: EdgeInsets.only(top: theme.space.tight),
      child: forui.FTile(
        prefix: const LeadingIcon(FLucideIcons.sparkles),
        title: Text(commit.action),
        subtitle: Text(
          createdAt == null ? changes : '${shortTime(createdAt)}，$changes',
        ),
        suffix: forui.FButton(
          variant: forui.FButtonVariant.outline,
          size: forui.FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: () => actions.undo(commit),
          prefix: const Icon(FLucideIcons.undo2),
          child: const Text('撤销'),
        ),
      ),
    );
  }
}
