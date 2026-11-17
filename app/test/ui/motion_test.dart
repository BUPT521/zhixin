import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/motion.dart';

Widget _host(Widget child, {bool reduce = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Scaffold(body: child),
  ),
);

double _opacityOf(WidgetTester tester, Finder finder) => tester
    .widget<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

/// 一条内容所在那一栏的 TickerMode；非当前栏应当为假。
bool _tickerEnabled(WidgetTester tester, String text) => tester
    .widget<TickerMode>(
      find
          .ancestor(
            of: find.text(text, skipOffstage: false),
            matching: find.byType(TickerMode, skipOffstage: false),
          )
          .first,
    )
    .enabled;

/// 一栏相对原位的水平位移；切栏途中用它判断滑入方向。
double _dxOf(WidgetTester tester, String text) => tester
    .widget<Transform>(
      find
          .ancestor(
            of: find.text(text, skipOffstage: false),
            matching: find.byType(Transform, skipOffstage: false),
          )
          .first,
    )
    .transform
    .getTranslation()
    .x;

/// 一栏是否参与当前显示；没参与切换的栏目仍在树上，只是不布局、不绘制，
/// 控件查找也看不到它。
bool _shown(WidgetTester tester, String text) =>
    find.text(text).evaluate().isNotEmpty;

void main() {
  testWidgets('内容换掉时淡入，播完停在完全不透明', (tester) async {
    await tester.pumpWidget(
      _host(const FadeIn(trigger: 0, playOnInit: false, child: Text('甲'))),
    );
    expect(_opacityOf(tester, find.text('甲')), 1);

    await tester.pumpWidget(
      _host(const FadeIn(trigger: 1, playOnInit: false, child: Text('乙'))),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(_opacityOf(tester, find.text('乙')), lessThan(1));

    await tester.pumpAndSettle();
    expect(_opacityOf(tester, find.text('乙')), 1);
  });

  testWidgets('系统要求减少动态效果时直接到终态', (tester) async {
    await tester.pumpWidget(
      _host(const FadeIn(child: Text('甲')), reduce: true),
    );
    await tester.pump();
    expect(_opacityOf(tester, find.text('甲')), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('淡入的内容在重绘边界里，位移不重画整块内容', (tester) async {
    await tester.pumpWidget(_host(const FadeIn(child: Text('甲'))));
    expect(
      find.descendant(
        of: find.byType(FadeIn),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('收起之后内容移出树，再展开重新出现', (tester) async {
    Widget reveal(bool visible) =>
        _host(ExpandReveal(visible: visible, child: const Text('已完成')));

    await tester.pumpWidget(reveal(true));
    expect(find.text('已完成'), findsOneWidget);

    await tester.pumpWidget(reveal(false));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('已完成'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('已完成'), findsNothing);

    await tester.pumpWidget(reveal(true));
    await tester.pumpAndSettle();
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('展开用 FadeTransition 与 SizeTransition 推进，不再逐帧重画内容', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const ExpandReveal(visible: false, child: Text('已完成'))),
    );
    await tester.pumpWidget(
      _host(const ExpandReveal(visible: true, child: Text('已完成'))),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final content = find.text('已完成');
    expect(
      find.ancestor(of: content, matching: find.byType(FadeTransition)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: content, matching: find.byType(SizeTransition)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: content, matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      find.ancestor(of: content, matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
  });

  testWidgets('减少动态效果时展开直接到终态', (tester) async {
    await tester.pumpWidget(
      _host(
        const ExpandReveal(visible: false, child: Text('已完成')),
        reduce: true,
      ),
    );
    await tester.pumpWidget(
      _host(
        const ExpandReveal(visible: true, child: Text('已完成')),
        reduce: true,
      ),
    );
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('展开列表按视口构建，收起后移除，减少动态效果时直接展开', (tester) async {
    final built = <int>{};
    Widget reveal(bool visible, {bool reduce = false}) => _host(
      CustomScrollView(
        slivers: [
          ExpandReveal.sliver(
            visible: visible,
            child: SliverList.builder(
              itemCount: 100,
              itemBuilder: (context, index) {
                built.add(index);
                return SizedBox(height: 80, child: Text('事项 $index'));
              },
            ),
          ),
        ],
      ),
      reduce: reduce,
    );

    await tester.pumpWidget(reveal(false));
    expect(built, isEmpty);
    await tester.pumpWidget(reveal(true));
    await tester.pump(const Duration(milliseconds: 70));
    final fade = find.byType(SliverFadeTransition);
    expect(
      tester.widget<SliverFadeTransition>(fade).opacity.value,
      lessThan(1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 1);
    expect(built, contains(0));
    expect(built, isNot(contains(99)));

    await tester.pumpWidget(reveal(false));
    await tester.pumpAndSettle();
    expect(find.text('事项 0'), findsNothing);

    await tester.pumpWidget(reveal(true, reduce: true));
    expect(tester.widget<SliverFadeTransition>(fade).opacity.value, 1);
  });

  testWidgets('切栏从切换方向滑入，旧栏反向滑出，播完回到原位', (tester) async {
    Widget stack(int index) => _host(
      TabSlideStack(
        index: index,
        children: const [Text('第一栏'), Text('第二栏'), Text('第三栏')],
      ),
    );

    await tester.pumpWidget(stack(0));
    await tester.pumpAndSettle();
    expect(_dxOf(tester, '第一栏'), 0);
    expect(_shown(tester, '第一栏'), isTrue);
    expect(_shown(tester, '第二栏'), isFalse);

    // 切到更靠右的一栏：新栏从右侧进来，旧栏向左出去，两幅栏首尾相接。
    await tester.pumpWidget(stack(1));
    await tester.pump(const Duration(milliseconds: 80));
    final entering = _dxOf(tester, '第二栏');
    final leaving = _dxOf(tester, '第一栏');
    expect(entering, greaterThan(0));
    expect(leaving, lessThan(0));
    expect(entering - leaving, closeTo(800, 0.5));
    // 滑出的那一栏还画在屏上，但已经不是当前页：控件查找只看得到新栏。
    expect(_shown(tester, '第二栏'), isTrue);
    expect(_shown(tester, '第一栏'), isFalse);

    await tester.pumpAndSettle();
    expect(_dxOf(tester, '第二栏'), 0);
    expect(_shown(tester, '第二栏'), isTrue);
    expect(_shown(tester, '第一栏'), isFalse);

    // 切回左边：方向反过来。
    await tester.pumpWidget(stack(0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_dxOf(tester, '第一栏'), lessThan(0));
    expect(_dxOf(tester, '第二栏'), greaterThan(0));
    await tester.pumpAndSettle();
    expect(_dxOf(tester, '第一栏'), 0);
    expect(_shown(tester, '第二栏'), isFalse);
  });

  testWidgets('切栏滑入不重建其他栏目的状态', (tester) async {
    Widget stack(int index) => _host(
      TabSlideStack(
        index: index,
        children: const [
          _Counter(key: ValueKey('a')),
          Text('第二栏'),
        ],
      ),
    );

    await tester.pumpWidget(stack(0));
    await tester.tap(find.text('0'));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    await tester.pumpWidget(stack(1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(stack(0));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('切栏时非当前栏停掉动画，当前栏照常推进', (tester) async {
    Widget stack(int index) => _host(
      TabSlideStack(index: index, children: const [Text('第一栏'), Text('第二栏')]),
    );

    await tester.pumpWidget(stack(0));
    expect(_tickerEnabled(tester, '第一栏'), isTrue);
    expect(_tickerEnabled(tester, '第二栏'), isFalse);

    await tester.pumpWidget(stack(1));
    await tester.pumpAndSettle();
    expect(_tickerEnabled(tester, '第一栏'), isFalse);
    expect(_tickerEnabled(tester, '第二栏'), isTrue);
  });

  testWidgets('切栏播完回到原位，减少动态效果时直接到终态', (tester) async {
    Widget stack(int index, {bool reduce = false}) => _host(
      TabSlideStack(index: index, children: const [Text('第一栏'), Text('第二栏')]),
      reduce: reduce,
    );

    await tester.pumpWidget(stack(0, reduce: true));
    await tester.pumpWidget(stack(1, reduce: true));
    await tester.pump();
    expect(_dxOf(tester, '第二栏'), 0);
    expect(_shown(tester, '第二栏'), isTrue);
    expect(_shown(tester, '第一栏'), isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('换周这类换内容按次序左右滑动，旧内容播完撤下', (tester) async {
    Widget swap(int order, String text) =>
        _host(SlideSwap(identity: text, order: order, child: Text(text)));

    await tester.pumpWidget(swap(0, '上一周'));
    expect(find.text('上一周'), findsOneWidget);

    // 往后换：新内容从右侧进来，旧内容同时向左出去，两块都在树上。
    await tester.pumpWidget(swap(1, '这一周'));
    await tester.pump(const Duration(milliseconds: 80));
    final entering = _dxOf(tester, '这一周');
    final leaving = _dxOf(tester, '上一周');
    expect(entering, greaterThan(0));
    expect(leaving, lessThan(0));
    expect(entering - leaving, closeTo(800, 0.5));
    // 旧内容还画着，但已经不是当前页：控件查找只看得到新内容。
    expect(_shown(tester, '上一周'), isFalse);

    await tester.pumpAndSettle();
    expect(_dxOf(tester, '这一周'), 0);
    expect(find.text('上一周', skipOffstage: false), findsNothing);

    // 往前换：方向反过来。
    await tester.pumpWidget(swap(0, '再上一周'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_dxOf(tester, '再上一周'), lessThan(0));
    await tester.pumpAndSettle();
    expect(_dxOf(tester, '再上一周'), 0);
  });

  testWidgets('换内容减少动态效果时直接到终态', (tester) async {
    Widget swap(String text) => _host(
      SlideSwap(identity: text, order: text.length, child: Text(text)),
      reduce: true,
    );

    await tester.pumpWidget(swap('旧的'));
    await tester.pumpWidget(swap('新的'));
    await tester.pump();
    expect(_dxOf(tester, '新的'), 0);
    expect(_shown(tester, '新的'), isTrue);
    expect(find.text('旧的', skipOffstage: false), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('路由过渡推进时淡入右推，播完停在终态，减少动态效果时直接到终态', (tester) async {
    await tester.pumpWidget(_host(const _TransitionHarness()));
    await tester.pump(const Duration(milliseconds: 100));
    final during = _opacityOf(tester, find.text('新页'));
    expect(during, greaterThan(0));
    expect(during, lessThan(1));
    expect(
      find.ancestor(of: find.text('新页'), matching: find.byType(Transform)),
      findsWidgets,
    );

    await tester.pumpAndSettle();
    expect(_opacityOf(tester, find.text('新页')), 1);

    await tester.pumpWidget(_host(const _TransitionHarness(), reduce: true));
    await tester.pump();
    // 直接到终态：不再套淡入，也不推入。
    expect(_opacityOf(tester, find.text('新页')), 1);
    expect(
      find.ancestor(of: find.text('新页'), matching: find.byType(Transform)),
      findsNothing,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('切栏动画结束之后才回填内容', (tester) async {
    final settledAt = <AnimationStatus?>[];
    Widget stack(int index) => _host(
      TabSlideStack(
        index: index,
        children: [
          const SizedBox.shrink(),
          _SettleProbe(running: index == 1, onSettled: settledAt.add),
        ],
      ),
    );

    await tester.pumpWidget(stack(0));
    await tester.pumpAndSettle();
    expect(settledAt, isEmpty);

    await tester.pumpWidget(stack(1));
    await tester.pump(const Duration(milliseconds: 80));
    // 动画还在走时不回填。
    expect(settledAt, isEmpty);

    await tester.pumpAndSettle();
    expect(settledAt, [AnimationStatus.completed]);
  });
}

/// 在当前栏动画走完之后才拿到结果的探针：切到这一栏时发起一次“读取”。
class _SettleProbe extends StatefulWidget {
  const _SettleProbe({required this.running, required this.onSettled});

  final bool running;
  final void Function(AnimationStatus?) onSettled;

  @override
  State<_SettleProbe> createState() => _SettleProbeState();
}

class _SettleProbeState extends State<_SettleProbe> {
  @override
  void didUpdateWidget(covariant _SettleProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running || !widget.running) return;
    final context = this.context;
    context.afterTransition().then((_) {
      if (!mounted) return;
      widget.onSettled(TabTransition.maybeOf(context)?.status);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 直接驱动页面路由过渡构建器的探针：动画时长与真实过渡一致。
class _TransitionHarness extends StatefulWidget {
  const _TransitionHarness();

  @override
  State<_TransitionHarness> createState() => _TransitionHarnessState();
}

class _TransitionHarnessState extends State<_TransitionHarness>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const ZhixinMotion().emphasized,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ZhixinPageTransitionsBuilder().buildTransitions(
        MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
        context,
        _controller,
        kAlwaysDismissedAnimation,
        const Text('新页'),
      );
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _count++),
    child: Text('$_count'),
  );
}
