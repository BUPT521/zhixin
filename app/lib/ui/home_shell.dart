import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

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
    if (!mounted || _index.value == index) return;
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
        footer: _BottomBar(index: index, onChange: _open),
        // 切栏时新栏淡入并上移几个像素；三栏仍然常驻，状态不随切换重建。
        child: FadeIndexedStack(index: index, children: _pages ?? const []),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChange});

  static const _items = [
    (FLucideIcons.house, '现在'),
    (FLucideIcons.history, '记录'),
    (FLucideIcons.calendarClock, '安排'),
  ];
  static const _itemPadding = 5.0;
  static const _iconHeight = 30.0;

  final int index;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final barPadding = EdgeInsets.symmetric(
      horizontal: theme.space.page,
      vertical: theme.space.xs,
    );
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colors.card,
          border: Border(top: BorderSide(color: theme.colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            children: [
              Positioned(
                top: barPadding.top + _itemPadding,
                left: barPadding.left,
                right: barPadding.right,
                height: _iconHeight,
                child: IgnorePointer(
                  child: AnimatedAlign(
                    duration: context.motionOf(theme.motion.standard),
                    curve: theme.motion.move,
                    alignment: AlignmentDirectional(
                      -1 + 2 * index / (_items.length - 1),
                      0,
                    ),
                    child: FractionallySizedBox(
                      widthFactor: 1 / _items.length,
                      child: Center(
                        child: Container(
                          width: 58,
                          height: _iconHeight,
                          decoration: ShapeDecoration(
                            color: theme.colors.primaryContainer,
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              forui.FBottomNavigationBar(
                index: index,
                onChange: onChange,
                style: .delta(
                  decoration: const .value(BoxDecoration()),
                  padding: .value(barPadding),
                  itemStyle: .delta(
                    padding: const .value(EdgeInsets.all(_itemPadding)),
                    spacing: theme.space.xs,
                    tappableStyle: const .delta(
                      motion: .delta(
                        bounceTween: forui.FTappableMotion.noBounceTween,
                      ),
                    ),
                    textStyle: .delta([
                      .all(
                        .delta(
                          color: theme.colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      .exact({.selected}, .delta(color: theme.colors.primary)),
                    ]),
                  ),
                ),
                children: [
                  for (final (i, (icon, label)) in _items.indexed)
                    forui.FBottomNavigationBarItem(
                      icon: SizedBox(
                        height: _iconHeight,
                        child: Icon(
                          icon,
                          size: 21,
                          color: i == index
                              ? theme.colors.onPrimaryContainer
                              : theme.colors.onSurfaceVariant,
                        ),
                      ),
                      label: Text(label),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
