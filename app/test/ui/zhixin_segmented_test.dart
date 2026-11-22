import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

/// 这一项当前画到的放大倍数。
double _scaleOf(WidgetTester tester, Finder finder) => tester
    .widget<ScaleTransition>(
      find.ancestor(of: finder, matching: find.byType(ScaleTransition)).first,
    )
    .scale
    .value;

void main() {
  testWidgets('按下未选中的页签时放大，选中的一项按下不放大', (tester) async {
    var selected = '学习记录';
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Center(
                child: ZhixinSegmented<String>(
                  segments: const [
                    ZhixinSegment(value: '学习记录', label: '学习记录'),
                    ZhixinSegment(value: '材料', label: '材料'),
                  ],
                  selected: selected,
                  onChanged: (value) => setState(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 按在未选中的一项上时放大，抬起之后完成切换。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('材料')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_scaleOf(tester, find.text('材料')), closeTo(1.06, 0.001));
    expect(_scaleOf(tester, find.text('学习记录')), 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, '材料');

    // 切换之后，选中的一项再按不放大：它再按一次没有动作。
    final pressed = await tester.startGesture(
      tester.getCenter(find.text('材料')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_scaleOf(tester, find.text('材料')), 1);
    await pressed.up();
    await tester.pumpAndSettle();

    // 另一项仍然可以按下放大，并切换回去。
    final back = await tester.startGesture(tester.getCenter(find.text('学习记录')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_scaleOf(tester, find.text('学习记录')), closeTo(1.06, 0.001));
    await back.up();
    await tester.pumpAndSettle();
    expect(selected, '学习记录');
  });

  testWidgets('放大文字时键盘能滚动到并切换分段，读屏能识别选中项', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const firstLabel = '独立完成';
    const lastLabel = '用了应用外帮助';
    var selected = firstLabel;
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: StatefulBuilder(
                  builder: (context, setState) => ZhixinSegmented<String>(
                    segments: const [
                      ZhixinSegment(value: firstLabel, label: firstLabel),
                      ZhixinSegment(value: '未说明', label: '未说明'),
                      ZhixinSegment(value: lastLabel, label: lastLabel),
                    ],
                    selected: selected,
                    onChanged: (value) {
                      changes.add(value);
                      setState(() => selected = value);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final first = find.bySemanticsLabel(firstLabel);
    final last = find.bySemanticsLabel(lastLabel);
    expect(
      tester.getSemantics(first),
      isSemantics(
        label: firstLabel,
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);

    final scroll = find.byType(SingleChildScrollView);
    final lastButton = find.ancestor(
      of: find.text(lastLabel),
      matching: find.byType(forui.FFocusedOutline),
    );
    expect(
      tester.getRect(lastButton).right,
      greaterThan(tester.getRect(scroll).right),
    );
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(
      tester.getRect(lastButton).right,
      lessThanOrEqualTo(tester.getRect(scroll).right),
    );
    expect(tester.widget<forui.FFocusedOutline>(lastButton).focused, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changes, [lastLabel]);
    expect(
      tester.getSemantics(last),
      isSemantics(label: lastLabel, isSelected: true, isFocused: true),
    );
    expect(tester.takeException(), isNull);
  });
}
