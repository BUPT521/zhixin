import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ui/materials_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 材料列表与材料详情的查找入口（02 第 3.14 节）。
///
/// 列表按标题、来源与页标签过滤，命中多于一页时继续加载，能翻到最早一条；
/// 材料详情在本材料内搜索正文，显示第几处与共几处并滚到对应页。查找全部在
/// 本机完成，不调用模型。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'zhixin-material-search-',
    );
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

  /// 轮询到目标控件出现；读取与回填都在后台完成，不能依赖 pumpAndSettle。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 480,
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

  /// 一次轻量的等待：让一次读取、一次重读或一次滚动收尾。
  Future<void> flush(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
  }

  /// 等首页读取收尾：数据库访问在应用根里排队，读还没结束时直接写库会一直
  /// 等独占权限；写种子又必须在界面之外运行，所以先把界面上的读取放完。
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

  /// 进入记录页的材料页签；材料列表在第一次切到这一栏时建出来。
  Future<void> openMaterialsTab(WidgetTester tester) async {
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
  }

  Finder searchField() => find.descendant(
    of: find.byKey(const ValueKey('materials-search-entry')),
    matching: find.byType(EditableText),
  );

  /// 一直往下拖，直到 [finder] 出现在可视范围里。
  Future<void> dragUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 12,
  }) async {
    for (var round = 0; round < rounds; round++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.dragFrom(const Offset(195, 1150), const Offset(0, -500));
      await flush(tester);
    }
  }

  testWidgets('材料列表按标题查找，命中多页时能翻到最早一条', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      for (var index = 1; index <= 45; index++) {
        await scope!.testing.materials.create(
          title: '分页材料 ${index.toString().padLeft(2, '0')}',
        );
      }
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, searchField());

    await tester.enterText(searchField(), '分页材料');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.textContaining('标题命中'));
    await settle(tester);

    // 第一页只有最近的二十条，最早的一条要翻到最后才出现。
    expect(find.text('分页材料 45'), findsOneWidget);
    expect(find.text('分页材料 01'), findsNothing);

    // 两页“加载更多结果”把 45 条全部取回。
    for (var page = 0; page < 2; page++) {
      await dragUntil(tester, find.text('加载更多结果'));
      expect(find.text('加载更多结果'), findsOneWidget);
      await tester.ensureVisible(find.text('加载更多结果'));
      await flush(tester);
      await tester.tap(find.text('加载更多结果'));
      await settle(tester);
    }

    await dragUntil(tester, find.text('已经到最后一条'));
    expect(find.text('已经到最后一条'), findsOneWidget);
    await dragUntil(tester, find.text('分页材料 01'));
    expect(find.text('分页材料 01'), findsOneWidget);

    // 打开最早的一条再返回：查询与结果都还在，列表不重置。
    await tester.tap(find.text('分页材料 01'));
    await pumpUntil(tester, find.byType(MaterialDetailPage));
    await pumpUntil(tester, find.text('这份材料还没有原文'));
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(tester.widget<EditableText>(searchField()).controller.text, '分页材料');
    // 滚动位置也留着：返回时仍停在最早的一条，而不是跳回第一页。
    await pumpUntil(tester, find.text('分页材料 01'));
    expect(find.text('分页材料 01'), findsOneWidget);
    expect(find.text('已经到最后一条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有命中时保留查询并给出清除，清除后回到原来的列表', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.materials.create(title: '概率论讲义');
      await scope!.testing.materials.create(title: '线性代数讲义');
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, searchField());

    await tester.enterText(searchField(), '不存在的材料');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('没有找到「不存在的材料」'));
    expect(find.text('清除查询'), findsOneWidget);
    // 空查询的入口提示在标题之前就写在输入框里，这里只验证清除恢复列表。
    expect(find.text('概率论讲义'), findsNothing);

    await tester.tap(find.text('清除查询'));
    await pumpUntil(tester, find.text('概率论讲义'));
    expect(find.text('线性代数讲义'), findsOneWidget);
    expect(find.text('没有找到「不存在的材料」'), findsNothing);
    expect(tester.widget<EditableText>(searchField()).controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询变化后只显示最后一次请求的结果', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.materials.create(title: '概率论讲义');
      await scope!.testing.materials.create(title: '线性代数讲义');
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, searchField());

    // 快速换一次查询：先输入一半，再立刻搜另一个词，只留后一次的结果。
    await tester.enterText(searchField(), '概率');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.enterText(searchField(), '线性代数');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('线性代数讲义'));
    await settle(tester);
    expect(find.text('概率论讲义'), findsNothing);
    expect(find.text('线性代数讲义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('材料详情可以在本材料内搜索正文并上一处、下一处定位', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final id = await scope!.testing.materials.create(title: '导数讲义');
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 1,
        content: '导数的定义是函数在一点附近的变化率。导数可以看作切线斜率。',
      );
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 2,
        content: '求导法则：常数的导数为零。',
      );
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 3,
        content: '导数的几何意义是切线斜率。',
      );
      return id;
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, find.text('导数讲义'));
    await tester.tap(find.text('导数讲义'));
    await pumpUntil(tester, find.textContaining('导数的定义'));

    final findField = find.descendant(
      of: find.byKey(const ValueKey('material-find-entry')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(findField, '导数');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('第 1 处 / 共 4 处'));

    // 命中处有可见的高亮：正文按命中位置切成带底色的片段。
    final highlighted = tester
        .widgetList<Text>(find.byType(Text))
        .expand(
          (widget) =>
              (widget.textSpan as TextSpan?)?.children ?? const <InlineSpan>[],
        )
        .where((span) => span.style?.backgroundColor != null);
    expect(highlighted, isNotEmpty);

    // 下一处把当前序号向前推，并滚到对应的页。
    await tester.tap(find.byIcon(FLucideIcons.chevronDown));
    await settle(tester);
    expect(find.text('第 2 处 / 共 4 处'), findsOneWidget);
    await tester.tap(find.byIcon(FLucideIcons.chevronDown));
    await settle(tester);
    expect(find.text('第 3 处 / 共 4 处'), findsOneWidget);
    await tester.tap(find.byIcon(FLucideIcons.chevronDown));
    await settle(tester);
    expect(find.text('第 4 处 / 共 4 处'), findsOneWidget);
    // 第 4 处在第 3 页，跳页之后这一页的原文在屏幕内。
    final pageThree = find.text('第 3 页');
    expect(pageThree, findsOneWidget);
    final top = tester.getTopLeft(pageThree).dy;
    expect(top, greaterThan(0));
    expect(top, lessThan(1400));

    // 上一处回到第 3 处，仍在第 3 页。
    await tester.tap(find.byIcon(FLucideIcons.chevronUp));
    await settle(tester);
    expect(find.text('第 3 处 / 共 4 处'), findsOneWidget);

    // 搜不到时保留查询并给清除，清除之后正文回到不带高亮的原样。
    await tester.enterText(findField, '不存在的词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('没有找到「不存在的词」'));
    expect(find.text('清除查找'), findsOneWidget);
    await tester.tap(find.text('清除查找'));
    await settle(tester);
    expect(find.textContaining('共 4 处'), findsNothing);
    // 清除查找之后正文回到不带高亮的原样，选中交给列表外层的同一个选择区。
    expect(find.byType(SelectionArea), findsWidgets);
    final plain = tester
        .widgetList<Text>(find.byType(Text))
        .expand(
          (widget) =>
              (widget.textSpan as TextSpan?)?.children ?? const <InlineSpan>[],
        )
        .where((span) => span.style?.backgroundColor != null);
    expect(plain, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
