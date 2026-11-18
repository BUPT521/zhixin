import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/ui/memory_page.dart';
import 'package:zhixin/ui/memory_search_page.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

/// 记忆查找：按正文、类别、适用范围与状态筛选，结果带着来源与有效期，
/// 并沿用记忆页的修改、删除与过期恢复入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-memory-search-');
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

  /// 推进到所有读取、回填与过渡动画结束。
  Future<void> settle(WidgetTester tester) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<T> seed<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    await settle(tester);
    return result as T;
  }

  Future<void> openApp(
    WidgetTester tester, {
    Size size = const Size(390, 1600),
  }) async {
    tester.view.physicalSize = size;
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

  /// 从记忆页标题栏的查找入口进入，顺带核对入口本身。
  Future<void> openSearch(WidgetTester tester) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(MaterialPageRoute<void>(builder: (_) => const MemoryPage()));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.search));
    await settle(tester);
    expect(find.byType(MemorySearchPage), findsOneWidget);
  }

  Finder searchField() => find.descendant(
    of: find.byKey(const ValueKey('memory-search-field')),
    matching: find.byType(EditableText),
  );

  /// 打开一枚筛选下拉并点中一个选项；选项浮层走路由动画，之后还要等重查。
  ///
  /// FSelect 的触发器是只读输入框；结果卡片上也有类别与范围文字，选项要取
  /// 菜单里可命中的那一枚。
  Future<void> selectOption(WidgetTester tester, Key key, String option) async {
    await tester.tap(
      find
          .descendant(
            of: find.byKey(key),
            matching: find.byType(forui.FTextField),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final optionItem = find.ancestor(
      of: find.text(option),
      matching: find.byWidgetPredicate((widget) => widget is forui.FSelectItem),
    );
    await tester.tap(optionItem.last);
    await settle(tester);
  }

  Finder tileOf(String content) => find.widgetWithText(forui.FTile, content);

  Future<void> openTileMenu(WidgetTester tester, String content) async {
    await tester.tap(
      find.descendant(
        of: tileOf(content),
        matching: find.byIcon(FLucideIcons.ellipsis),
      ),
    );
    await settle(tester);
  }

  testWidgets('默认列出有效与已过期，结果带来源、有效期与编辑入口', (tester) async {
    await openApp(tester);

    final goalId = await seed(
      tester,
      () => scope!.testing.tasks.createGoal(title: '概率论期末'),
    );
    final materialId = await seed(
      tester,
      () => scope!.testing.materials.create(title: '线性代数讲义'),
    );
    await seed(tester, () async {
      final memories = scope!.testing.memories;
      await memories.create(
        kind: MemoryKind.preference,
        content: '先给提示，再看完整解答',
        validUntil: DateTime(2030, 1, 1),
      );
      await memories.create(
        kind: MemoryKind.difficulty,
        content: '容易漏加主对角元素',
        scope: memoryGoalScope(goalId),
        sourceKind: MemorySourceKind.attempt,
        sourceId: 'attempt-0001',
      );
      await memories.create(
        kind: MemoryKind.progress,
        content: '第 8 题独立完成',
        scope: memoryMaterialScope(materialId),
        sourceKind: MemorySourceKind.session,
        sourceId: 'session-0001',
      );
      await memories.create(
        kind: MemoryKind.difficulty,
        content: '过期的困难记忆',
        validUntil: DateTime(2020, 1, 1),
      );
    });

    await openSearch(tester);

    // 空查询仍按默认范围列出条目，并说明当前显示的是哪部分记忆。
    expect(find.textContaining('没有输入关键词，先列出有效与已过期的记忆'), findsOneWidget);
    expect(find.text('先给提示，再看完整解答'), findsOneWidget);
    expect(find.text('过期的困难记忆'), findsOneWidget);

    // 类别、来源与来源对象、有效期与状态都写在结果里。
    expect(find.text('偏好'), findsOneWidget);
    expect(find.text('来源：你说的'), findsWidgets);
    expect(
      find.textContaining('来源：来自一次作答 · 作答记录 attempt-0001'),
      findsOneWidget,
    );
    expect(
      find.textContaining('来源：来自一次学习 · 学习场次 session-0001'),
      findsOneWidget,
    );
    expect(find.textContaining('有效期：有效至 2030-01-01'), findsOneWidget);
    expect(find.textContaining('目标：概率论期末'), findsOneWidget);
    expect(find.text('已过期'), findsOneWidget);

    // 修改入口沿用记忆页的弹窗；取消之后结果不动。
    await openTileMenu(tester, '先给提示，再看完整解答');
    expect(find.text('修改'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await settle(tester);
    expect(find.text('修改记忆'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('先给提示，再看完整解答'), findsOneWidget);

    // 过期条目可以主动查看并恢复，恢复入口打开现有的日期选择。
    await openTileMenu(tester, '过期的困难记忆');
    expect(find.text('恢复（延长有效期）'), findsOneWidget);
    await tester.tap(find.text('恢复（延长有效期）'));
    await settle(tester);
    expect(find.text('选择日期'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('按正文、类别与适用范围筛选，结果只保留命中的记忆', (tester) async {
    await openApp(tester);

    final goalId = await seed(
      tester,
      () => scope!.testing.tasks.createGoal(title: '概率论期末'),
    );
    final materialId = await seed(
      tester,
      () => scope!.testing.materials.create(title: '线性代数讲义'),
    );
    await seed(tester, () async {
      final memories = scope!.testing.memories;
      await memories.create(kind: MemoryKind.preference, content: '全局偏好：先看例题');
      await memories.create(
        kind: MemoryKind.difficulty,
        content: '目标困难：漏主对角',
        scope: memoryGoalScope(goalId),
      );
      await memories.create(
        kind: MemoryKind.progress,
        content: '材料进展：独立完成第 8 题',
        scope: memoryMaterialScope(materialId),
      );
      await memories.create(
        kind: MemoryKind.difficulty,
        content: '材料困难：把秩算错',
        scope: memoryMaterialScope(materialId),
      );
    });

    await openSearch(tester);

    // 正文关键词。
    await tester.enterText(searchField(), '主对角');
    await settle(tester);
    expect(find.text('目标困难：漏主对角'), findsOneWidget);
    expect(find.text('全局偏好：先看例题'), findsNothing);
    expect(find.text('材料困难：把秩算错'), findsNothing);

    await tester.enterText(searchField(), '');
    await settle(tester);

    // 类别。
    await selectOption(tester, const ValueKey('memory-search-kind'), '困难');
    expect(find.text('目标困难：漏主对角'), findsOneWidget);
    expect(find.text('材料困难：把秩算错'), findsOneWidget);
    expect(find.text('全局偏好：先看例题'), findsNothing);
    expect(find.text('材料进展：独立完成第 8 题'), findsNothing);

    // 适用范围叠加在类别上。
    await selectOption(
      tester,
      const ValueKey('memory-search-scope'),
      '目标：概率论期末',
    );
    expect(find.text('目标困难：漏主对角'), findsOneWidget);
    expect(find.text('材料困难：把秩算错'), findsNothing);

    // 换材料范围，两个材料内的记忆重新出现。
    await selectOption(
      tester,
      const ValueKey('memory-search-scope'),
      '材料：线性代数讲义',
    );
    expect(find.text('材料困难：把秩算错'), findsOneWidget);
    expect(find.text('目标困难：漏主对角'), findsNothing);

    // 清除类别之后，材料范围里的进展也一起出现。
    await selectOption(tester, const ValueKey('memory-search-kind'), '全部类别');
    expect(find.text('材料进展：独立完成第 8 题'), findsOneWidget);
    expect(find.text('材料困难：把秩算错'), findsOneWidget);
    expect(find.text('全局偏好：先看例题'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('筛到已删除只给提示，追溯入口指向数据版本且没有恢复', (tester) async {
    await openApp(tester);

    final deletedId = await seed(tester, () async {
      final memories = scope!.testing.memories;
      await memories.create(kind: MemoryKind.preference, content: '仍在使用的记忆');
      final id = await memories.create(
        kind: MemoryKind.preference,
        content: '已经删掉的记忆',
      );
      await memories.delete(id);
      return id;
    });
    expect(deletedId, isNotEmpty);

    await openSearch(tester);
    await selectOption(tester, const ValueKey('memory-search-status'), '已删除');

    expect(find.text('已删除的记忆不在这里重新列出'), findsOneWidget);
    expect(find.textContaining('数据版本'), findsWidgets);
    expect(find.text('打开数据版本'), findsOneWidget);
    expect(find.text('已经删掉的记忆'), findsNothing);
    expect(find.text('恢复（延长有效期）'), findsNothing);

    // 改回有效与已过期之后回到默认结果。
    await tester.tap(find.text('改回有效与已过期'));
    await settle(tester);
    expect(find.textContaining('没有输入关键词，先列出有效与已过期的记忆'), findsOneWidget);
    expect(find.text('仍在使用的记忆'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('超过 40 条命中时可以一直翻到最早一条', (tester) async {
    await openApp(tester, size: const Size(390, 1400));

    await seed(tester, () async {
      final memories = scope!.testing.memories;
      for (var index = 1; index <= 45; index++) {
        await memories.create(
          kind: MemoryKind.preference,
          content: '翻页记忆 ${index.toString().padLeft(2, '0')}',
        );
      }
    });

    await openSearch(tester);
    await tester.enterText(searchField(), '翻页记忆');
    await settle(tester);

    expect(find.text('翻页记忆 45'), findsOneWidget);
    expect(find.text('翻页记忆 01'), findsNothing);

    final scrollable = find
        .descendant(
          of: find.byType(MemorySearchPage),
          matching: find.byType(Scrollable),
        )
        .last;
    // 一页 20 条，45 条命中要再取两页；页脚在视口下方时才被列表建出来。
    for (var page = 0; page < 2; page++) {
      await tester.scrollUntilVisible(
        find.text('加载更多结果'),
        300,
        scrollable: scrollable,
      );
      await settle(tester);
      await tester.tap(find.text('加载更多结果'));
      await settle(tester);
    }

    await tester.scrollUntilVisible(
      find.text('翻页记忆 01'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('翻页记忆 01'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('已经到最后一条'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('已经到最后一条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速改条件时只显示最后一次查询的结果', (tester) async {
    await openApp(tester);

    await seed(tester, () async {
      final memories = scope!.testing.memories;
      await memories.create(kind: MemoryKind.preference, content: '旧条件命中的记忆');
      await memories.create(kind: MemoryKind.preference, content: '新条件命中的记忆');
    });

    await openSearch(tester);

    // 两次输入之间只推一帧，让第一次搜索还可能在路上；最终只留下第二次结果。
    await tester.enterText(searchField(), '旧条件');
    await tester.pump();
    await tester.enterText(searchField(), '新条件');
    await settle(tester);

    expect(find.text('新条件命中的记忆'), findsOneWidget);
    expect(find.text('旧条件命中的记忆'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
