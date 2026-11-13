import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'discussion_page.dart';
import 'learning_page.dart';
import 'memory_page.dart';
import 'now_page.dart';
import 'plan_page.dart';
import 'records_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// 底部三栏（02 第 10.1 节）：现在 / 记录 / 安排，设置留在次级入口。
///
/// 三栏常驻，不按数据版本换 key：返回详情之后由打开它的栏目自己重读数据，
/// 其他栏目的筛选、输入与滚动位置不跟着重建。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  RecordsTab _recordsTab = RecordsTab.learning;
  int _recordsRequest = 0;
  int _scheduleRequest = 0;

  void _open(int index) {
    if (!mounted) return;
    setState(() => _index = index);
  }

  void _openRecords(RecordsTab tab) {
    setState(() {
      _recordsTab = tab;
      _recordsRequest++;
      _index = 1;
    });
  }

  void _openSchedule() {
    setState(() {
      _scheduleRequest++;
      _index = 2;
    });
  }

  Future<void> _openLearning(int questionId) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
  }

  Future<void> _openLearningRedo(int questionId) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId, startRedo: true),
      ),
    );
  }

  Future<void> _openDiscussion(int conversationId) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: conversationId),
      ),
    );
  }

  void _openMemory() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const MemoryPage()));
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ValueListenableBuilder<int>(
      valueListenable: AppScope.of(context).dataVersion,
      builder: (context, dataVersion, _) => forui.FScaffold(
        footer: forui.FBottomNavigationBar(
          index: _index,
          onChange: _open,
          style: .delta(
            decoration: .value(
              BoxDecoration(
                color: theme.colors.card,
                border: Border(
                  top: BorderSide(color: theme.colors.outlineVariant),
                ),
              ),
            ),
            padding: .value(
              EdgeInsets.symmetric(
                horizontal: theme.space.page,
                vertical: theme.space.xs,
              ),
            ),
            itemStyle: .delta(spacing: theme.space.xs),
          ),
          children: const [
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(FLucideIcons.house),
              label: Text('现在'),
              semanticsLabel: '现在',
            ),
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(FLucideIcons.history),
              label: Text('记录'),
              semanticsLabel: '记录',
            ),
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(FLucideIcons.calendarClock),
              label: Text('安排'),
              semanticsLabel: '安排',
            ),
          ],
        ),
        // 切栏时新栏淡入并上移几个像素；三栏仍然常驻，状态不随切换重建。
        child: FadeIndexedStack(
          index: _index,
          children: [
            NowPage(
              key: const ValueKey('now'),
              isActive: _index == 0,
              dataVersion: dataVersion,
              onOpenLearning: _openLearning,
              onOpenPlan: _openSchedule,
              onOpenRecords: () => _openRecords(RecordsTab.learning),
              onOpenMaterials: () => _openRecords(RecordsTab.materials),
              onOpenMemory: _openMemory,
              onOpenSettings: _openSettings,
            ),
            RecordsPage(
              key: const ValueKey('records'),
              isActive: _index == 1,
              dataVersion: dataVersion,
              initialTab: _recordsTab,
              tabRequest: _recordsRequest,
              onStartQuestion: () => _open(0),
              onOpenLearning: _openLearning,
              onOpenLearningRedo: _openLearningRedo,
              onOpenDiscussion: _openDiscussion,
            ),
            PlanPage(
              key: const ValueKey('plan'),
              isActive: _index == 2,
              dataVersion: dataVersion,
              scheduleRequest: _scheduleRequest,
              onOpenMaterials: () => _openRecords(RecordsTab.materials),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final selected = forui.FBottomNavigationBarData.of(context).selected;
    return AnimatedContainer(
      duration: context.motionOf(theme.motion.fast),
      curve: theme.motion.move,
      width: 54,
      height: 30,
      decoration: BoxDecoration(
        color: selected ? theme.colors.primaryContainer : Colors.transparent,
        borderRadius: theme.radius.control,
      ),
      child: Icon(icon, size: 20),
    );
  }
}
