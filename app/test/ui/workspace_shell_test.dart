import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/ui/learning_page.dart';
import 'package:zhixin/ui/materials_list.dart';
import 'package:zhixin/ui/now_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';
import 'package:zhixin/ui/zhixin_header.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('记录与安排的搜索入口都在页签上方，创建动作在节标题右侧', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('记录').last);
    await settle(tester);

    final recordsSearch = find.byKey(const ValueKey('records-search-entry'));
    expect(recordsSearch, findsOneWidget);
    expect(
      tester.getBottomLeft(recordsSearch).dy,
      lessThan(tester.getTopLeft(find.byType(ZhixinSegmented<RecordsTab>)).dy),
    );
    expect(find.widgetWithText(SectionLink, '贴一道题'), findsOneWidget);

    await tester.tap(find.text('安排').last);
    await settle(tester);

    final planSearch = find.byKey(const ValueKey('plan-search-entry'));
    expect(planSearch, findsOneWidget);
    expect(
      tester.getBottomLeft(planSearch).dy,
      lessThan(tester.getTopLeft(find.byType(ZhixinSegmented<int>)).dy),
    );
    expect(find.widgetWithText(SectionLink, '新建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('材料从节标题导入，菜单里选粘贴原文打开导入框', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);

    await tester.tap(find.widgetWithText(SectionLink, '导入材料'));
    await settle(tester);
    expect(find.text('粘贴原文'), findsOneWidget);
    await tester.tap(find.text('粘贴原文'));
    await settle(tester);
    expect(find.text('材料名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页入口直达材料与系统学习，切换后保留未发送的问题', (tester) async {
    await openApp(tester);
    await preview(tester, 'now-empty');
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '保留这个问题',
    );
    tester.testTextInput.hide();
    await tester.tap(find.text('从材料开始学习'));
    await settle(tester);
    // 空库时标题栏与空态各有一个导入入口。
    expect(find.text('导入材料'), findsWidgets);
    expect(tester.takeException(), isNull);
    await preview(tester, 'records-materials');
    await tester.tap(find.text('现在').last);
    await settle(tester);
    expect(find.text('保留这个问题'), findsOneWidget);
    await preview(tester, 'now-typed');
    await tester.tap(find.text('系统学习').first);
    await settle(tester);
    expect(find.text('还没有学习计划'), findsOneWidget);
    final materialButton = find.text('选择学习材料').last;
    expect(materialButton, findsOneWidget);
    await tester.ensureVisible(materialButton);
    await tester.tap(materialButton.hitTestable());
    await settle(tester);
    expect(find.text('导入材料'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('材料页签预读之后第一次打开直接是内容（减少动态效果：$reduceMotion）', (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reduceMotion);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await openApp(tester);
      const title = '待阅讲义';
      await tester.runAsync(
        () => scope!.library.material.create(
          title: title,
          kind: MaterialKind.text,
        ),
      );
      await tester.tap(find.text('记录').last);
      await settle(tester);

      final tab = find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料');
      final materials = find.byType(MaterialList);
      final skeleton = find.descendant(
        of: materials,
        matching: find.byType(ListSkeleton),
      );
      final importButton = find.widgetWithText(SectionLink, '导入材料');
      await tester.tap(tab.hitTestable());
      await tester.runAsync(() async {
        await tester.pump();
        // 等数据库读取结束，保持页签动画的测试时钟停在起点。
        await scope!.testing.gate.exclusive(() async {});
      });
      // 材料页签在底栏预读时已经建好并读完，第一次打开不再摆骨架，按钮可用。
      expect(skeleton, findsNothing);
      expect(find.text(title), findsOneWidget);
      expect(tester.widget<SectionLink>(importButton).onPressed, isNotNull);
      final headingPosition = tester.getTopLeft(importButton);
      final transition = TabTransition.maybeOf(tester.element(materials))!;
      expect(
        transition.status,
        reduceMotion ? AnimationStatus.completed : AnimationStatus.forward,
      );

      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      if (!reduceMotion) {
        await tester.pump(const Duration(milliseconds: 80));
        expect(skeleton, findsNothing);
        expect(find.text(title), findsOneWidget);
        await tester.pump(const ZhixinMotion().standard);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await tester.pump();
      expect(skeleton, findsNothing);
      expect(transition.status, AnimationStatus.completed);
      expect(find.text(title), findsOneWidget);
      expect(tester.widget<SectionLink>(importButton).onPressed, isNotNull);
      if (reduceMotion) {
        expect(tester.getTopLeft(importButton), headingPosition);
      }

      final materialsState = tester.state<MaterialListState>(materials);
      await tester.tap(find.text('学习记录'));
      await tester.pumpAndSettle();
      await tester.tap(tab.hitTestable());
      await tester.pumpAndSettle();
      expect(tester.state<MaterialListState>(materials), same(materialsState));
      expect(skeleton, findsNothing);
      expect(find.text(title), findsOneWidget);
    });
  }

  testWidgets('底栏按下时图标位置固定，选中只改颜色', (tester) async {
    await openApp(tester);
    final bar = find.byType(forui.FBottomNavigationBar);
    Finder icon(IconData data) =>
        find.descendant(of: bar, matching: find.byIcon(data));
    Color? iconColor(IconData data) => tester.widget<Icon>(icon(data)).color;

    final start = tester.getCenter(icon(FLucideIcons.house));
    final targetIcon = icon(FLucideIcons.history);
    final iconRect = tester.getRect(targetIcon);
    final next = iconRect.center;
    // 没有胶囊指示块：当前栏的图标是正文色，其余是次要文字色。
    expect(
      iconColor(FLucideIcons.house),
      isNot(iconColor(FLucideIcons.history)),
    );

    final gesture = await tester.startGesture(next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final pressedRect = tester.getRect(targetIcon);
    expect(pressedRect.size, iconRect.size);
    expect(pressedRect.center, offsetMoreOrLessEquals(next));

    await gesture.up();
    await settle(tester);
    // 切过去之后颜色互换，图标位置不动。直接点这一栏也能切，不靠滑动手势。
    await tester.tap(targetIcon);
    await settle(tester);
    expect(
      iconColor(FLucideIcons.history),
      isNot(iconColor(FLucideIcons.house)),
      reason: '切换之后这一栏换成选中色，原来那一栏回到次要文字色',
    );
    expect(
      tester.getCenter(icon(FLucideIcons.house)),
      offsetMoreOrLessEquals(start),
    );
  });
  testWidgets('页面里左右划动切换底栏，两头的栏再往外划不换', (tester) async {
    await openApp(tester);

    forui.FBottomNavigationBar bar() =>
        tester.widget<forui.FBottomNavigationBar>(
          find.byType(forui.FBottomNavigationBar),
        );

    /// 从标题栏中间横向甩一下：这里没有能横向滚动的控件，手势只会落到页面栈上。
    Future<void> swipe(double dx) async {
      final header = tester.getRect(find.byType(ZhixinHeader).first);
      await tester.flingFrom(
        Offset(header.center.dx, header.center.dy),
        Offset(dx, 0),
        1200,
      );
      await settle(tester);
    }

    expect(bar().index, 0);
    await swipe(-240);
    expect(bar().index, 1);
    expect(find.byType(RecordsPage), findsOneWidget);
    expect(find.byType(NowPage), findsNothing);

    await swipe(-240);
    expect(bar().index, 2);
    await swipe(240);
    expect(bar().index, 1);

    // 到头的栏再往外划不换栏，也不绕到最后一栏。
    await swipe(240);
    expect(bar().index, 0);
    await swipe(240);
    expect(bar().index, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏、放大文字与键盘下核心页面没有布局溢出', (tester) async {
    await openApp(tester, size: const Size(320, 700));
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('记录').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('安排').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => scope!.testing.tasks.createItem(title: '整理第三章笔记', estMinutes: 30),
    );
    await settle(tester);
    await tester.tap(find.text('整理第三章笔记').hitTestable());
    await settle(tester);
    expect(find.text('完成事项'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('完成事项').hitTestable());
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('发送问题'));
    await settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘弹出时首页只缩小一次，输入区完整显示在键盘上方', (tester) async {
    const keyboard = 364.0;
    const screenHeight = 924.0;
    await openApp(tester, size: const Size(424, screenHeight));
    await tester.tap(editableFields().first);
    await settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    // 外层的底栏骨架让出一次键盘高度之后，页面高度是屏幕减一次键盘。
    final page = tester.getRect(find.byType(NowPage));
    expect(page.height, closeTo(screenHeight - keyboard, 1));
    // 页面自己的骨架不再让一次：滚动区域是页面去掉标题栏之后的全部高度。
    final header = tester.getSize(find.byType(ZhixinHeader));
    final scroll = tester.getRect(
      find.byKey(const PageStorageKey('now-scroll')),
    );
    expect(scroll.height, closeTo(page.height - header.height, 1));
    // 输入区的发送按钮落在滚动区域之内，没有被裁掉。
    final send = tester.getRect(find.bySemanticsLabel('发送问题'));
    expect(send.bottom, lessThanOrEqualTo(scroll.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习中操作条在真机宽度与放大文字下不溢出', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '求极限 lim sin3x/2x，x 趋于 0'),
    );
    await tester.tap(find.text('记录').last);
    await settle(tester);
    final record = find.widgetWithText(forui.FTile, '求极限 lim sin3x/2x，x 趋于 0');
    expect(record, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('records-answer-filter')));
    await settle(tester);
    await tester.tap(find.text('待处理'));
    await settle(tester);
    expect(record, findsNothing);
    await tester.tap(find.byKey(const ValueKey('records-answer-filter')));
    await settle(tester);
    await tester.tap(find.text('未作答'));
    await settle(tester);
    expect(record, findsOneWidget);
    await tester.tap(find.descendant(of: record, matching: find.text('继续作答')));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('提交作答'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
