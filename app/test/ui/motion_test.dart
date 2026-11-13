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

  testWidgets('切栏淡入不重建其他栏目的状态', (tester) async {
    Widget stack(int index) => _host(
      FadeIndexedStack(
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
      FadeIndexedStack(
        index: index,
        children: const [Text('第一栏'), Text('第二栏')],
      ),
    );

    await tester.pumpWidget(stack(0));
    expect(_tickerEnabled(tester, '第一栏'), isTrue);
    expect(_tickerEnabled(tester, '第二栏'), isFalse);

    await tester.pumpWidget(stack(1));
    await tester.pumpAndSettle();
    expect(_tickerEnabled(tester, '第一栏'), isFalse);
    expect(_tickerEnabled(tester, '第二栏'), isTrue);
  });

  testWidgets('切栏播完停在完全不透明，减少动态效果时直接到终态', (tester) async {
    Widget stack(int index, {bool reduce = false}) => _host(
      FadeIndexedStack(
        index: index,
        children: const [Text('第一栏'), Text('第二栏')],
      ),
      reduce: reduce,
    );

    await tester.pumpWidget(stack(0, reduce: true));
    await tester.pumpWidget(stack(1, reduce: true));
    await tester.pump();
    expect(_opacityOf(tester, find.text('第二栏')), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('切栏动画结束之后才回填内容', (tester) async {
    final settledAt = <AnimationStatus?>[];
    Widget stack(int index) => _host(
      FadeIndexedStack(
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
