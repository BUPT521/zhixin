import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../domain/models/study_plan.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 从首页查看全部系统学习计划与进度。
class StudyPlanListPage extends StatefulWidget {
  const StudyPlanListPage({super.key, required this.onOpenMaterials});

  final VoidCallback onOpenMaterials;

  @override
  State<StudyPlanListPage> createState() => _StudyPlanListPageState();
}

class _StudyPlanListPageState extends State<StudyPlanListPage> {
  Stream<List<StudyPlan>>? _plans;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _plans ??= AppScope.of(context).study.systemPlan.watchList();
  }

  void _retry() => setState(() {
    _error = null;
    _plans = AppScope.of(context).study.systemPlan.watchList();
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return TabScaffold(
      header: const ZhixinHeader(title: Text('系统学习'), showBack: true),
      child: LiveView<List<StudyPlan>>(
        stream: _plans,
        onData: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onError: (error, stack) {
          final message = describeFailure(
            context,
            error,
            stack,
            action: '读取系统学习计划',
            kind: 'study_plan_list_read',
          );
          setState(() => _error = message);
        },
        builder: (context, plans, loading) {
          if (plans == null && _error == null && loading) {
            return ListSkeleton(rows: 3, padding: theme.space.pageInsets());
          }
          return PageWidth(
            child: ListView(
              padding: theme.space.pageInsets(),
              children: [
                if (_error case final message?)
                  InlineNotice(message: message, onRetry: _retry),
                if (plans?.isEmpty ?? false)
                  EmptyState(
                    icon: FLucideIcons.route,
                    title: '还没有学习计划',
                    description: '从材料的指定页开始，按步骤保存学习进度。',
                    action: forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: () {
                        Navigator.of(context).pop();
                        widget.onOpenMaterials();
                      },
                      child: const Text('选择学习材料'),
                    ),
                  ),
                for (final plan in plans ?? const <StudyPlan>[])
                  Padding(
                    padding: EdgeInsets.only(bottom: theme.space.sm),
                    child: forui.FTile(
                      prefix: const LeadingIcon(FLucideIcons.route),
                      title: Text(plan.title),
                      subtitle: Text(
                        [
                          plan.statusLabel,
                          plan.progressLabel,
                          if (plan.nextStepTitle case final step?
                              when plan.open)
                            '下一步：$step',
                        ].join(' · '),
                      ),
                      onPress: () => openStudyPlan(context, plan.id),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
