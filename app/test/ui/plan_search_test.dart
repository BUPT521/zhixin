import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/paged_result.dart';
import 'package:zhixin/application/plan_search.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/ui/materials_page.dart';
import 'package:zhixin/ui/plan_search_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 安排查找：关键词、目标、状态与日期筛选，结果点开回到对应内容，分页能翻到
/// 最早一条，快速改条件只显示最后一次结果（docs/02 第 3.14 节、V10）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-plan-search-');
    await disableTelemetryForTests(directory.path);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  tearDown(() async {
    await closeAppScope(scope, directory);
    scope = null;
  });

  /// 轮询到目标控件出现；查找读取在后台完成，不能依赖 pumpAndSettle 收尾。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 320,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await advanceAsync(
        tester,
        scope?.testing.gate,
        const Duration(milliseconds: 20),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 等首页与安排页的读取收尾：等应用自己的访问队列清空，再画几帧让回填完成。
  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester, scope);
  }

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await settle(tester);
  }

  /// 切到安排栏，再点页签上方的那条搜索入口。
  Future<void> openPlanSearch(WidgetTester tester) async {
    await tester.tap(find.text('安排').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('plan-search-entry')));
    await pumpUntil(tester, find.byType(PlanSearchPage));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder keywordField() => find
      .descendant(
        of: find.byType(PlanSearchPage),
        matching: find.byType(EditableText),
      )
      .first;

  Future<void> searchKeyword(WidgetTester tester, String text) async {
    await tester.enterText(keywordField(), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
  }

  /// 点开一个筛选菜单并选一项；菜单项文字与按钮文字不同，取最后一条命中。
  Future<void> chooseFilter(
    WidgetTester tester,
    Finder trigger,
    String optionLabel,
  ) async {
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.text(optionLabel).last);
    await settle(tester);
  }

  /// 滚到列表底部找到“加载更多结果”，再点一次；列表按需构建，只能滚过去。
  Future<void> loadMore(WidgetTester tester) async {
    for (
      var round = 0;
      round < 20 && find.text('加载更多结果').evaluate().isEmpty;
      round++
    ) {
      await tester.dragFrom(const Offset(195, 700), const Offset(0, -400));
      await settle(tester);
    }
    expect(find.text('加载更多结果'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多结果'));
    await settle(tester);
    await tester.tap(find.text('加载更多结果'));
    await settle(tester);
  }

  /// 滚动直到目标文字进入视口。
  Future<void> scrollTo(WidgetTester tester, String text) async {
    for (var round = 0; round < 20; round++) {
      if (find.text(text).evaluate().isNotEmpty) return;
      await tester.dragFrom(const Offset(195, 700), const Offset(0, -400));
      await settle(tester);
    }
    fail('滚动之后仍未找到：$text');
  }

  testWidgets('关键词命中事项标题与说明，点开结果打开事项详情', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.tasks.createItem(
        title: '矩阵求迹练习',
        note: '先写出主对角元素再相加',
      );
      await scope!.testing.tasks.createItem(
        title: '程序设计练习',
        note: '矩阵转置时只交换行列',
      );
      await scope!.testing.tasks.createItem(title: '无关的事项');
    });

    await openPlanSearch(tester);
    // 空查询先给入口提示，不发起查找。
    expect(find.textContaining('按标题、说明、目标、状态或截止日期'), findsOneWidget);

    await searchKeyword(tester, '矩阵');
    await pumpUntil(tester, find.text('矩阵求迹练习'));
    expect(find.text('程序设计练习'), findsOneWidget);
    expect(find.text('无关的事项'), findsNothing);

    // 没有命中时保留筛选并给清除入口；清除之后回到入口提示。
    await searchKeyword(tester, '完全没有出现过的词');
    await pumpUntil(tester, find.text('没有找到符合条件的内容'));
    expect(find.textContaining('关键词「完全没有出现过的词」'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await settle(tester);
    expect(find.textContaining('按标题、说明、目标、状态或截止日期'), findsOneWidget);

    // 点开一条结果：普通事项打开事项详情面板。
    await searchKeyword(tester, '矩阵求迹');
    await pumpUntil(tester, find.text('矩阵求迹练习'));
    await tester.tap(find.text('矩阵求迹练习'));
    await pumpUntil(tester, find.text('完成事项'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划步骤按继续位置规则打开这一步的学习内容', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '微积分讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '导数描述函数在一点附近的变化率。',
      );
      await scope!.testing.studyPlans.createWithDrafts(
        title: '导数计划',
        materialId: material,
        pageFrom: 1,
        pageTo: 1,
        drafts: const [StudyStepDraft(title: '阅读导数定义', pageFrom: 1, pageTo: 1)],
      );
    });

    await openPlanSearch(tester);
    await searchKeyword(tester, '导数定义');
    await pumpUntil(tester, find.text('阅读导数定义'));
    await tester.tap(find.text('阅读导数定义'));
    await pumpUntil(tester, find.byType(MaterialDetailPage));
    expect(tester.takeException(), isNull);
  });

  testWidgets('目标与状态筛选只留下符合条件的事项', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final goalA = await scope!.testing.tasks.createGoal(title: '概率论期末');
      final goalB = await scope!.testing.tasks.createGoal(title: '线性代数作业');
      await scope!.testing.tasks.createItem(title: '目标甲的练习', goalId: goalA);
      await scope!.testing.tasks.createItem(title: '目标乙的练习', goalId: goalB);
      final done = await scope!.testing.tasks.createItem(title: '已经做完的事项');
      await scope!.study.plan.setStatus(done, PlanItemStatus.done);
    });

    await openPlanSearch(tester);
    // 没有关键词时筛选本身就能发起查找。
    await chooseFilter(tester, find.text('目标：全部'), '目标：概率论期末');
    await pumpUntil(tester, find.text('目标甲的练习'));
    expect(find.text('目标乙的练习'), findsNothing);

    await chooseFilter(tester, find.text('目标：概率论期末'), '全部目标');
    await chooseFilter(tester, find.text('状态：全部'), '已完成');
    await pumpUntil(tester, find.text('已经做完的事项'));
    expect(find.text('目标甲的练习'), findsNothing);
    expect(find.text('目标乙的练习'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期筛选按事项截止时间', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 12);
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.tasks.createItem(title: '今天截止的事项', dueAt: today);
      await scope!.testing.tasks.createItem(title: '明天截止的事项', dueAt: tomorrow);
    });

    await openPlanSearch(tester);
    // 日期按钮的文字随选中日期变化，统一按图标找到它。
    final dateFilter = find.byIcon(FLucideIcons.calendarDays);
    await chooseFilter(tester, dateFilter, '今天');
    await pumpUntil(tester, find.text('今天截止的事项'));
    expect(find.text('明天截止的事项'), findsNothing);

    await chooseFilter(tester, dateFilter, '明天');
    await pumpUntil(tester, find.text('明天截止的事项'));
    expect(find.text('今天截止的事项'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同类命中超过四十条时能继续加载并翻到最早一条', (tester) async {
    final now = DateTime.now();
    await openApp(tester);
    await tester.runAsync(() async {
      for (var index = 1; index <= 45; index++) {
        await scope!.testing.tasks.createItem(
          title: '分页事项 ${index.toString().padLeft(2, '0')}',
          dueAt: DateTime(now.year, now.month, now.day + index, 12),
        );
      }
    });

    await openPlanSearch(tester);
    await searchKeyword(tester, '分页事项');
    await pumpUntil(tester, find.text('分页事项 45'));
    // 第一页按时间从晚到早，最早的一条要翻到最后一页。
    expect(find.text('分页事项 01'), findsNothing);

    await loadMore(tester);
    await loadMore(tester);
    await scrollTo(tester, '分页事项 01');
    expect(find.text('分页事项 01'), findsOneWidget);
    // 最后一页读完，不再有继续读取的入口。
    expect(find.text('加载更多结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速改关键词只显示最后一次请求的结果', (tester) async {
    // 注入一份可控制完成顺序的读法：先发起的请求晚回来，页面不能因此回退。
    final pending = <String, Completer<PagedResult<PlanSearchHit>>>{};
    Future<PagedResult<PlanSearchHit>> fakeSearch(
      PlanSearchQuery query, {
      int offset = 0,
    }) {
      final completer = Completer<PagedResult<PlanSearchHit>>();
      pending[query.keyword] = completer;
      return completer.future;
    }

    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final themeMode = ThemeModeController();
    addTearDown(themeMode.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          title: '知新',
          debugShowCheckedModeBanner: false,
          theme: zhixinTheme,
          darkTheme: zhixinDarkTheme,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            forui.FLocalizations.delegate,
          ],
          builder: (context, child) => forui.FTheme(
            data: Theme.brightnessOf(context) == Brightness.light
                ? zhixinForuiTheme
                : zhixinDarkForuiTheme,
            child: forui.FToaster(
              child: AppScope(
                themeAccent: ThemeAccentController(),
                themeMode: themeMode,
                child: child!,
              ),
            ),
          ),
          home: PlanSearchPage(search: fakeSearch),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await tester.pump();

    await tester.enterText(keywordField(), '甲');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.enterText(keywordField(), '乙');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(pending.keys, containsAll(['甲', '乙']));

    // 后发起的请求先回来，页面显示乙的结果。
    pending['乙']!.complete(
      PagedResult(
        items: [PlanSearchHit.item(PlanItem(id: 'b', title: '乙的结果'))],
        nextOffset: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('乙的结果'), findsOneWidget);

    // 早发起的请求晚回来，不再覆盖已经显示的最后一次结果。
    pending['甲']!.complete(
      PagedResult(
        items: [PlanSearchHit.item(PlanItem(id: 'a', title: '甲的结果'))],
        nextOffset: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('乙的结果'), findsOneWidget);
    expect(find.text('甲的结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
