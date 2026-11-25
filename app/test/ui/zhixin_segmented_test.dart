import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';
import 'package:zhixin/ui/zhixin_select.dart';

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

  testWidgets('整条与按钮、输入框同高，按下时轨道与选中底色都不动', (tester) async {
    Future<void> pumpSelected(String value) => tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: ZhixinSegmented<String>(
                segments: const [
                  ZhixinSegment(value: '日程', label: '日程'),
                  ZhixinSegment(value: '事项', label: '事项'),
                  ZhixinSegment(value: '目标', label: '目标'),
                  ZhixinSegment(value: 'AI 的改动', label: 'AI 的改动'),
                ],
                selected: value,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await pumpSelected('日程');
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(ZhixinSegmented<String>)).height,
      ZhixinSpace.controlHeight,
    );
    final track = find.ancestor(
      of: find.text('日程'),
      matching: find.byType(ConstrainedBox),
    );
    // 选中底色画在等宽的滑块上：它的宽度与位置只在切换时按新的一项重排。
    final thumb = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is ShapeDecoration &&
          (widget.decoration as ShapeDecoration).color != null,
    );
    final before = tester.getRect(track.first);
    final thumbBefore = tester.getRect(thumb.first);

    // 按在未选中的一项上：只有这一项的内容放大，轨道高度、选中底色的位置
    // 都不变，不会出现旁边一栏闪一下再退回去。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('目标')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_scaleOf(tester, find.text('目标')), closeTo(1.06, 0.001));
    expect(tester.getRect(track.first), before);
    expect(tester.getRect(thumb.first), thumbBefore);
    expect(
      find.descendant(
        of: find.byType(ZhixinSegmented<String>),
        matching: find.byType(AnimatedAlign),
      ),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(track.first), before);
  });

  testWidgets('安排页四个页签在手机宽度下等分整行，选中底色只落在当前项', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: 342,
                child: StatefulBuilder(
                  builder: (context, setState) => ZhixinSegmented<int>(
                    segments: const [
                      ZhixinSegment(
                        value: 0,
                        label: '日程',
                        icon: FLucideIcons.calendarDays,
                      ),
                      ZhixinSegment(
                        value: 1,
                        label: '事项',
                        icon: FLucideIcons.listChecks,
                      ),
                      ZhixinSegment(
                        value: 2,
                        label: '目标',
                        icon: FLucideIcons.flag,
                      ),
                      ZhixinSegment(
                        value: 3,
                        label: 'AI',
                        icon: FLucideIcons.sparkles,
                        semanticsLabel: 'AI 的改动',
                      ),
                    ],
                    selected: selected,
                    onChanged: (value) => setState(() => selected = value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 四个页签等分整行，不退回横向滚动；每一段的宽度相同。
    expect(find.byType(SingleChildScrollView), findsNothing);
    final labels = ['日程', '事项', '目标', 'AI 的改动'];
    final widths = [
      for (final label in labels)
        tester.getSize(find.bySemanticsLabel(label)).width,
    ];
    expect(widths.toSet().length, 1, reason: '四个页签应当等宽：$widths');

    // 选中底色是一块，中心与当前项的中心对齐；切换之后跟着新的一项。
    final thumb = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is ShapeDecoration &&
          (widget.decoration as ShapeDecoration).color ==
              const Color(0xFFFFFFFF),
    );
    expect(thumb, findsOneWidget);
    expect(
      tester.getCenter(thumb).dx,
      closeTo(tester.getCenter(find.bySemanticsLabel('日程')).dx, 0.5),
    );

    await tester.tap(find.bySemanticsLabel('目标'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(thumb).dx,
      closeTo(tester.getCenter(find.bySemanticsLabel('目标')).dx, 0.5),
    );
    await tester.tap(find.bySemanticsLabel('AI 的改动'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(thumb).dx,
      closeTo(tester.getCenter(find.bySemanticsLabel('AI 的改动')).dx, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉框与输入框、按钮同高，标签与说明另占高度', (tester) async {
    Future<void> pumpField(Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Scaffold(
            body: Center(child: SizedBox(width: 320, child: child)),
          ),
        ),
      ),
    );
    final select = find.byWidgetPredicate(
      (widget) => widget is forui.FSelect<int>,
    );

    // 不带标签与说明的选择框，框本身与输入框、按钮同一档。
    await pumpField(
      forui.FSelect<int>.rich(
        control: .lifted(value: 1, onChange: (_) {}),
        format: (value) => '选项 $value',
        children: const [forui.FSelectItem<int>(value: 1, title: Text('一'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(select).height, ZhixinSpace.controlHeight);

    await pumpField(
      forui.FTextField(
        control: .managed(controller: TextEditingController()),
        hint: '搜索',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(forui.FTextField)).height,
      ZhixinSpace.controlHeight,
    );
    await pumpField(forui.FButton(onPress: () {}, child: const Text('保存')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(forui.FButton)).height,
      ZhixinSpace.controlHeight,
    );

    // 带标签与说明的选择框，两行说明文字落在框外，框本身仍是同一档。
    await pumpField(
      ZhixinSelect<int>(
        value: 1,
        label: '归属目标',
        description: '这一项放在哪个目标下面',
        options: const {1: '概率论期末'},
        onChange: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(select).height,
      greaterThan(ZhixinSpace.controlHeight),
    );
    final box = find
        .descendant(of: select, matching: find.byType(EditableText))
        .first;
    expect(
      tester
          .getSize(
            find.ancestor(of: box, matching: find.byType(InputDecorator)).first,
          )
          .height,
      ZhixinSpace.controlHeight,
    );
  });
}
