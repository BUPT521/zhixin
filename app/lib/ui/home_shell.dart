import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'discussion_page.dart';
import 'learning_page.dart';
import 'memory_page.dart';
import 'motion.dart';
import 'now_page.dart';
import 'plan_page.dart';
import 'records_page.dart';
import 'settings_page.dart';

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
  /// 当前栏与跳转请求都走 notifier：切栏只换常驻栈的下标，三栏的构造参数
  /// 不变，切栏那一帧因此不必把三栏一起重建。
  final ValueNotifier<int> _index = ValueNotifier<int>(0);
  final ValueNotifier<RecordsRequest> _recordsRequest =
      ValueNotifier<RecordsRequest>(
        const RecordsRequest(RecordsTab.learning, 0),
      );
  final ValueNotifier<int> _scheduleRequest = ValueNotifier<int>(0);

  /// 三栏页面只建一次；跳转与数据版本都通过 notifier 传，不靠重建。
  List<Widget>? _pages;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pages ??= [
      NowPage(
        key: const ValueKey('now'),
        activeTab: _index,
        tabIndex: 0,
        onOpenLearning: _openLearning,
        onOpenPlan: _openSchedule,
        onOpenRecords: () => _openRecords(RecordsTab.learning),
        onOpenMaterials: () => _openRecords(RecordsTab.materials),
        onOpenMemory: _openMemory,
        onOpenSettings: _openSettings,
      ),
      RecordsPage(
        key: const ValueKey('records'),
        activeTab: _index,
        tabIndex: 1,
        request: _recordsRequest,
        onStartQuestion: () => _open(0),
        onOpenLearning: _openLearning,
        onOpenLearningRedo: _openLearningRedo,
        onOpenDiscussion: _openDiscussion,
      ),
      PlanPage(
        key: const ValueKey('plan'),
        activeTab: _index,
        tabIndex: 2,
        request: _scheduleRequest,
        onOpenMaterials: () => _openRecords(RecordsTab.materials),
      ),
    ];
  }

  @override
  void dispose() {
    // 这些 notifier 由三栏共享，页面卸载时还会移除自己的监听，所以不在这里
    // 销毁：跟着 HomeShell 一起被回收即可。
    super.dispose();
  }

  void _open(int index) {
    if (!mounted) return;
    _index.value = index;
  }

  void _openRecords(RecordsTab tab) {
    _recordsRequest.value = RecordsRequest(
      tab,
      _recordsRequest.value.sequence + 1,
    );
    _open(1);
  }

  void _openSchedule() {
    _scheduleRequest.value++;
    _open(2);
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
    return ValueListenableBuilder<int>(
      valueListenable: _index,
      builder: (context, index, _) => forui.FScaffold(
        footer: forui.FBottomNavigationBar(
          index: index,
          onChange: _open,
          children: const [
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(
                icon: FLucideIcons.house,
                selectedIcon: FLucideIcons.house,
              ),
              label: Text('现在'),
              semanticsLabel: '现在',
            ),
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(
                icon: FLucideIcons.history,
                selectedIcon: FLucideIcons.history,
              ),
              label: Text('记录'),
              semanticsLabel: '记录',
            ),
            forui.FBottomNavigationBarItem(
              icon: _NavIcon(
                icon: FLucideIcons.calendarClock,
                selectedIcon: FLucideIcons.calendarClock,
              ),
              label: Text('安排'),
              semanticsLabel: '安排',
            ),
          ],
        ),
        // 切栏时新栏淡入并上移几个像素；三栏仍然常驻，状态不随切换重建。
        child: FadeIndexedStack(index: index, children: _pages ?? const []),
      ),
    );
  }
}

/// 底栏图标；Forui 的底栏项没有单独的选中图标参数，选中态由主色与加粗区分，
/// 这里留一个选中图标的位置，需要换图形时再用。
class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.icon, required this.selectedIcon});

  final IconData icon;
  final IconData selectedIcon;

  @override
  Widget build(BuildContext context) {
    return Icon(
      forui.FBottomNavigationBarData.of(context).selected ? selectedIcon : icon,
    );
  }
}
