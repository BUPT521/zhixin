import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/active_report_service.dart';
import '../application/prefetch_service.dart';
import '../application/update_check_service.dart';
import 'copy.dart';
import 'mine_page.dart';
import 'navigation.dart';
import 'now_page.dart';
import 'plan_page.dart';
import 'records_page.dart';
import 'telemetry_notice.dart';
import 'theme.dart';
import 'update_notice.dart';

/// 底部四栏（02 第 2.1 节）：现在 / 记录 / 安排 / 我的；账号、设置与其余次级
/// 入口都收在“我的”里。
///
/// 四栏常驻，不按数据版本换 key：返回详情之后由打开它的栏目自己重读数据，
/// 其他栏目的筛选、输入与滚动位置不跟着重建。点底栏切栏，也可以在页面区域
/// 左右划动切到相邻的一栏；划到两头的栏再往外划不换栏。
///
/// 首页先读；首读完成之后（最迟 [preloadDelay]）放行其余三栏在后台订阅，第一次
/// 切过去直接是内容，不再在切栏动画里看一段骨架。放行之前就切过去的栏当场读。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// 首页首读完成之前最多等这么久；读取失败或变慢时由这个时限放行其余三栏。
const Duration preloadDelay = Duration(milliseconds: 600);

/// 切到某一栏之后等这么久再预读它的二级界面：先让切栏动画走完，再读下一层。
const Duration secondaryPrefetchDelay = Duration(milliseconds: 320);

class _HomeShellState extends State<HomeShell> {
  /// 当前栏与跳转请求都走 notifier：切栏只换常驻栈的下标，各栏的构造参数
  /// 不变，切栏那一帧因此不必把各栏一起重建。
  final ValueNotifier<int> _index = ValueNotifier<int>(0);
  final ValueNotifier<RecordsRequest> _recordsRequest =
      ValueNotifier<RecordsRequest>(
        const RecordsRequest(RecordsTab.learning, 0),
      );
  final ValueNotifier<int> _scheduleRequest = ValueNotifier<int>(0);

  /// 其余三栏能否在后台预读；首页首读完成或到 [preloadDelay] 时置真，之后不再变。
  final ValueNotifier<bool> _preload = ValueNotifier<bool>(false);
  Timer? _preloadTimer;

  /// 二级界面的预读；每次切栏排一次，切走时取消还没到点的那一次。
  Timer? _secondaryPrefetchTimer;
  int _secondaryPrefetchSequence = 0;

  /// 各栏页面只建一次；跳转与数据版本都通过 notifier 传，不靠重建。
  List<Widget>? _pages;

  /// 首次说明与更新检查只安排一次，didChangeDependencies 会因主题、语言等变化被多次调用。
  bool _startupChecksScheduled = false;

  @override
  void initState() {
    super.initState();
    _index.addListener(_onIndexChanged);
    // 首页从启动起就是当前栏：首帧之后预读它的二级界面，用户点进记忆时直接有内容。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleSecondaryPrefetch(_areaOf(0));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_startupChecksScheduled) {
      _startupChecksScheduled = true;
      final services = AppScope.of(context).accountServices;
      final report = services.activeReport;
      final updates = services.updates;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_runStartupChecks(report, updates));
        _preloadTimer = Timer(preloadDelay, _releasePreload);
      });
    }
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
        onFirstRead: _releasePreload,
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
        preload: _preload,
      ),
      PlanPage(
        key: const ValueKey('plan'),
        activeTab: _index,
        tabIndex: 2,
        request: _scheduleRequest,
        onOpenMaterials: () => _openRecords(RecordsTab.materials),
        preload: _preload,
      ),
      MinePage(
        key: const ValueKey('mine'),
        activeTab: _index,
        tabIndex: 3,
        preload: _preload,
      ),
    ];
  }

  @override
  void dispose() {
    _index.removeListener(_onIndexChanged);
    _preloadTimer?.cancel();
    _secondaryPrefetchTimer?.cancel();
    // 这些 notifier 由各栏共享，页面卸载时还会移除自己的监听，所以不在这里
    // 销毁：跟着 HomeShell 一起被回收即可。
    super.dispose();
  }

  /// 切栏（包括首次切到某一栏）之后预读这一栏的二级界面。
  void _onIndexChanged() => _scheduleSecondaryPrefetch(_areaOf(_index.value));

  /// 首页首读完成（或到 [preloadDelay]）时放行其余三栏预读，只放行一次。
  void _releasePreload() {
    if (!mounted || _preload.value) return;
    _preloadTimer?.cancel();
    _preloadTimer = null;
    _preload.value = true;
  }

  /// 预读排在切栏动画之后；连续切栏时只保留最后一次，不为中间一闪而过的栏读数据。
  void _scheduleSecondaryPrefetch(PrefetchArea area) {
    final sequence = ++_secondaryPrefetchSequence;
    _secondaryPrefetchTimer?.cancel();
    _secondaryPrefetchTimer = Timer(secondaryPrefetchDelay, () {
      if (!mounted || sequence != _secondaryPrefetchSequence) return;
      AppScope.of(context).prefetch.enter(area);
    });
  }

  static PrefetchArea _areaOf(int index) => switch (index) {
    0 => PrefetchArea.now,
    1 => PrefetchArea.records,
    2 => PrefetchArea.plan,
    _ => PrefetchArea.mine,
  };

  /// 首次说明与更新检查都放在启动后的空闲时机。
  ///
  /// 先等首次说明关掉再检查更新，两个弹窗不会叠在一起。本次启动只检查一次；
  /// 网络与校验失败静默，原因由服务写进本机诊断。
  Future<void> _runStartupChecks(
    ActiveReportService report,
    UpdateCheckService updates,
  ) async {
    await showTelemetryNoticeIfNeeded(context, report);
    if (!mounted) return;
    await showStartupUpdateCheck(context, updates);
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

  Future<void> _openLearning(String questionId) async {
    if (!mounted) return;
    await openLearning(context, questionId);
  }

  Future<void> _openLearningRedo(String questionId) async {
    if (!mounted) return;
    await openLearningRedo(context, questionId);
  }

  Future<void> _openDiscussion(String conversationId) async {
    if (!mounted) return;
    await openDiscussion(context, conversationId);
  }

  Future<void> _openMemory() => openMemory(context);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _index,
      builder: (context, index, _) => forui.FScaffold(
        footer: _BottomBar(index: index, onChange: _open),
        // 换栏时新栏从切换方向滑入、旧栏向相反方向滑出；各栏仍然常驻，
        // 状态不随切换重建。左右划动切到相邻的一栏，指哪一栏就交给 [_open]。
        child: TabSlideStack(
          index: index,
          onSwipe: _open,
          children: _pages ?? const [],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChange});

  static const _items = [
    (FLucideIcons.house, tabNow),
    (FLucideIcons.history, tabRecords),
    (FLucideIcons.calendarClock, tabPlan),
    (FLucideIcons.circleUserRound, tabMine),
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
                            color: theme.colors.primarySoft,
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
                    // 字重与未选中/选中的文字色都在主题里配好，这里只保留间距与按下动效。
                    spacing: theme.space.xs,
                    tappableStyle: const .delta(
                      motion: .delta(
                        bounceTween: forui.FTappableMotion.noBounceTween,
                      ),
                    ),
                  ),
                ),
                children: [
                  for (final (i, (icon, label)) in _items.indexed)
                    forui.FBottomNavigationBarItem(
                      icon: SizedBox(
                        height: _iconHeight,
                        child: Icon(
                          icon,
                          size: 20,
                          color: i == index
                              ? theme.colors.onSurface
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
