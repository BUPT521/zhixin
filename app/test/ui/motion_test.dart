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
