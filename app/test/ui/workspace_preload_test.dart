import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/account_page.dart';
import 'package:zhixin/ui/copy.dart';
import 'package:zhixin/ui/materials_list.dart';
import 'package:zhixin/ui/mine_page.dart';
import 'package:zhixin/ui/plan_goals_tab.dart';
import 'package:zhixin/ui/plan_items_tab.dart';
import 'package:zhixin/ui/plan_operations_tab.dart';
import 'package:zhixin/ui/plan_schedule_tab.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('首页读完之后其余三栏已在后台预读，第一次切过去没有骨架', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '预读之后直接看到的题目'),
    );
    await settle(tester);

    // 切栏的第一帧就是内容：记录、安排与“我的”都不再在滑入时摆一段骨架。
    await tester.tap(find.text('记录').last);
    await tester.pump();
    expect(find.byType(ListSkeleton), findsNothing);
    expect(find.widgetWithText(forui.FTile, '预读之后直接看到的题目'), findsOneWidget);
    await settle(tester);

    for (final tab in ['安排', '我的']) {
      await tester.tap(find.text(tab).last);
      await tester.pump();
      expect(find.byType(ListSkeleton), findsNothing, reason: tab);
      await settle(tester);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('预读放行后材料页签一并建好，切过去直接是内容', (tester) async {
    await openApp(tester);

    // 学习记录与材料两个页签在预读放行时一起建起来，材料列表已在后台订阅。
    expect(find.byType(MaterialList, skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text(recordsTabMaterials));
    await tester.pump();
    expect(find.byType(ListSkeleton), findsNothing);
    expect(find.byType(MaterialList), findsOneWidget);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预读放行后安排的四个页签都已建好', (tester) async {
    await openApp(tester);

    for (final view in <Type>[
      PlanScheduleTab,
      PlanItemsTab,
      PlanGoalsTab,
      PlanOperationsTab,
    ]) {
      expect(
        find.byType(view, skipOffstage: false),
        findsOneWidget,
        reason: '$view',
      );
    }

    await tester.tap(find.text('安排').last);
    await tester.pump();
    expect(find.byType(ListSkeleton), findsNothing);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进入我的之后设置页首屏已经预读，打开不再出现骨架', (tester) async {
    await openApp(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text(tabMine),
      ),
    );
    // 预读在切栏动画之后开始，这里等到它读完。
    await settle(tester);

    final entry = find.descendant(
      of: find.byType(MinePage),
      matching: find.widgetWithText(forui.FTile, '设置'),
    );
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find
          .descendant(
            of: find.byType(MinePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(ListSkeleton), findsNothing);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进入我的之后账号页首屏已经预读，打开不再出现骨架', (tester) async {
    await openApp(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text(tabMine),
      ),
    );
    // 预读在切栏动画之后开始，这里等到它读完。
    await settle(tester);

    final signIn = find.text('登录或注册');
    expect(signIn, findsOneWidget);
    await tester.tap(signIn);
    await tester.pump();
    await tester.pump();

    expect(find.byType(AccountPage), findsOneWidget);
    expect(find.byType(ListSkeleton), findsNothing);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进入安排之后容量面板已经算好，打开不再出现骨架', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('安排').last);
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await tester.pump();
    await tester.pump();

    expect(find.text('这周还能做什么'), findsOneWidget);
    expect(find.byType(ListSkeleton), findsNothing);
    expect(find.textContaining('本周剩余'), findsOneWidget);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切栏再回来保留筛选与已读记录，不再回到骨架', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '切栏之后还要看到的题目'),
    );
    await tester.tap(find.text('记录').last);
    await settle(tester);
    final record = find.widgetWithText(forui.FTile, '切栏之后还要看到的题目');
    expect(record, findsOneWidget);

    // 在记录里选一个筛选，再去别的栏目转一圈。
    await tester.tap(find.byKey(const ValueKey('records-answer-filter')));
    await settle(tester);
    await tester.tap(find.text('未作答'));
    await settle(tester);
    expect(record, findsOneWidget);

    await tester.tap(find.text('现在').last);
    await settle(tester);
    await tester.tap(find.text('记录').last);
    await tester.pump();

    // 切回来第一帧还是原来的记录与筛选：没有重新回到骨架，也没有丢检索条件。
    expect(find.byType(ListSkeleton), findsNothing);
    expect(record, findsOneWidget);
    expect(find.text('未作答'), findsOneWidget);
    await settle(tester);
    expect(record, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统为深色时生产装配的应用跟随深色主题', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await openApp(tester);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp).first);
    expect(app.theme, same(zhixinTheme));
    expect(app.darkTheme, same(zhixinDarkTheme));
    expect(app.themeMode, ThemeMode.system);

    final context = tester.element(
      find.byType(forui.FBottomNavigationBar).first,
    );
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      zhixinDarkTheme.scaffoldBackgroundColor,
    );
    expect(tester.takeException(), isNull);
    await preview(tester, 'now-dark');
  });

  testWidgets('设置页可以把外观固定为深色或浅色', (tester) async {
    await openApp(tester);
    await openMineEntry(tester, '设置');
    await tester.scrollUntilVisible(
      selectField<ThemeMode>('深浅色'),
      260,
      scrollable: settingsScrollable(),
    );
    await tester.ensureVisible(selectField<ThemeMode>('深浅色'));
    await tester.pumpAndSettle();
    expect(select<ThemeMode>('深浅色'), findsOneWidget);

    await tester.tap(selectField<ThemeMode>('深浅色'));
    await settle(tester);
    await tester.tap(find.text('深色').last);
    await settle(tester);
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.dark,
    );

    await tester.ensureVisible(selectField<ThemeMode>('深浅色'));
    await tester.pumpAndSettle();
    await tester.tap(selectField<ThemeMode>('深浅色'));
    await settle(tester);
    await tester.tap(find.text('浅色').last);
    await settle(tester);
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.light,
    );
    expect(tester.takeException(), isNull);
  });
}
