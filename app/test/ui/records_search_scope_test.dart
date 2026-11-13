import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ui/records_search_page.dart';

/// 记录页的查找范围选择器：切换全部、目标与材料之后，结果随范围收窄并在
/// 页面上写明当前范围，不需要再按一次搜索。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-search-scope-');
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
    await scope?.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

  /// 轮询到目标控件出现；查找与列表读取都在后台完成，不能依赖
  /// pumpAndSettle 收尾。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 80,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 轮询到目标控件消失；范围切换后旧结果要等本次查找结束才会被替换。
  Future<void> pumpUntilGone(
    WidgetTester tester,
    Finder finder, {
    int rounds = 80,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isEmpty) return;
    }
    fail('等待界面移除超时：$finder');
  }

  /// 等首页读取收尾：数据库访问在应用根里排队，读还没结束时直接写库会一直
  /// 等独占权限；写种子又必须在界面之外运行，所以先把界面上的读取放完。
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (round < 6) continue;
      if (find.byType(forui.FCircularProgress).evaluate().isEmpty) break;
    }
    // 指示器消失之后仍可能有收尾的读取，多跑几帧让它们把共享权限还回来。
    for (var round = 0; round < 6; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
  }

  testWidgets('范围选择器把查找结果限制在选定的目标或材料里', (tester) async {
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

    // 两个目标各一条讨论与一份材料，同一个词在两个范围里都能命中。
    await tester.runAsync(() async {
      final goalA = await scope!.tasks.createGoal(title: '概率论期末');
      final goalB = await scope!.tasks.createGoal(title: '线性代数作业');
      final discussionA = await scope!.conversations.create(
        title: '条件概率讨论',
        goalId: goalA,
      );
      await scope!.conversations.append(
        discussionA,
        role: 'user',
        content: '条件概率这一章的方法有哪些',
      );
      final discussionB = await scope!.conversations.create(
        title: '矩阵的秩',
        goalId: goalB,
      );
      await scope!.conversations.append(
        discussionB,
        role: 'user',
        content: '矩阵的秩的方法是什么',
      );
      final materialA = await scope!.materials.create(
        title: '概率论讲义',
        goalId: goalA,
      );
      await scope!.materials.addPage(
        materialId: materialA,
        pageNo: 1,
        content: '条件概率的方法：先写出样本空间与事件。',
      );
      final materialB = await scope!.materials.create(
        title: '线性代数讲义',
        goalId: goalB,
      );
      await scope!.materials.addPage(
        materialId: materialB,
        pageNo: 2,
        content: '矩阵秩的方法：化为行阶梯形再数非零行。',
      );
    });

    await tester.tap(find.text('记录').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('records-search-entry')));
    await pumpUntil(tester, find.text('搜索记录'));

    final searchField = find.descendant(
      of: find.byType(RecordsSearchPage),
      matching: find.byType(EditableText),
    );
    await tester.enterText(searchField, '方法');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('《概率论讲义》第 1 页'));
    await pumpUntil(tester, find.text('《线性代数讲义》第 2 页'));

    bool isSelected(String label) => tester
        .widget<forui.FTile>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(forui.FTile),
          ),
        )
        .selected;

    // 菜单按当前的目标与材料生成，默认落在全部记录。
    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('本机全部记录'), findsOneWidget);
    expect(find.text('目标：概率论期末'), findsOneWidget);
    expect(find.text('目标：线性代数作业'), findsOneWidget);
    expect(find.text('材料：概率论讲义'), findsOneWidget);
    expect(find.text('材料：线性代数讲义'), findsOneWidget);
    expect(isSelected('本机全部记录'), isTrue);

    // 返回先关闭菜单，保留当前页面和查询。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('本机全部记录'), findsNothing);
    expect(find.text('搜索记录'), findsOneWidget);
    expect(find.text('《线性代数讲义》第 2 页'), findsOneWidget);
    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();

    // 选目标之后不再按搜索，结果由页面自己重查并去掉另一个目标的内容。
    await tester.tap(find.text('目标：线性代数作业'));
    await pumpUntil(tester, find.textContaining('查找范围：目标：线性代数作业'));
    await pumpUntilGone(tester, find.text('《概率论讲义》第 1 页'));
    expect(find.text('《线性代数讲义》第 2 页'), findsOneWidget);

    // 选材料之后只看这份材料的页，讨论不在材料范围里。
    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(isSelected('目标：线性代数作业'), isTrue);
    await tester.tap(find.text('材料：概率论讲义'));
    await pumpUntil(tester, find.textContaining('查找范围：材料：概率论讲义'));
    await pumpUntilGone(tester, find.text('《线性代数讲义》第 2 页'));
    expect(find.text('《概率论讲义》第 1 页'), findsOneWidget);

    // 回到全部记录，两个目标的内容重新出现。
    await tester.tap(find.byIcon(FLucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(isSelected('材料：概率论讲义'), isTrue);
    await tester.tap(find.text('本机全部记录'));
    await pumpUntil(tester, find.textContaining('查找范围：本机全部记录'));
    await pumpUntil(tester, find.text('《线性代数讲义》第 2 页'));
    expect(find.text('《概率论讲义》第 1 页'), findsOneWidget);

    // 从材料命中带入下一次回答，通知条出现；清除后消失。
    final materialTile = find.widgetWithText(forui.FTile, '《概率论讲义》第 1 页');
    await tester.tap(
      find.descendant(
        of: materialTile,
        matching: find.byIcon(FLucideIcons.listPlus),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已加入 1 条来源'), findsOneWidget);
    await tester.tap(find.widgetWithText(forui.FButton, '清除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已加入'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查找结果可以继续加载更多结果', (tester) async {
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

    // 二十一独立记录，第一页放二十条，最后一条要靠“加载更多结果”取回。
    await tester.runAsync(() async {
      for (var index = 1; index <= 21; index++) {
        final id = await scope!.conversations.create(title: '分页题 $index');
        await scope!.conversations.append(
          id,
          role: 'user',
          content: '分页关键词 $index',
        );
      }
    });

    await tester.tap(find.text('记录').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('records-search-entry')));
    await pumpUntil(tester, find.text('搜索记录'));

    final searchField = find.descendant(
      of: find.byType(RecordsSearchPage),
      matching: find.byType(EditableText),
    );
    await tester.enterText(searchField, '分页关键词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.textContaining('分页题'));
    await settle(tester);
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
    await pumpUntil(tester, find.text('已经到最后一条'));
    expect(find.text('加载更多结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
