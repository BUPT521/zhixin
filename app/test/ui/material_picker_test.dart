import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ui/home_shell.dart';
import 'package:zhixin/ui/material_picker.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 材料选择器：按标题、来源与页标签过滤候选，没有命中时给空态与清除，
/// 选中之后的返回值与原来一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'zhixin-material-picker-',
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

  Future<void> pumpUntilGone(
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
      if (finder.evaluate().isEmpty) return;
    }
    fail('等待界面移除超时：$finder');
  }

  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester, scope);
  }

  testWidgets('材料选择器按标题与页标签过滤，没有命中时给空态与清除', (tester) async {
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

    final probability = await tester.runAsync(() async {
      final id = await scope!.testing.materials.create(title: '概率论讲义');
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 1,
        content: '条件概率的定义与乘法公式。',
      );
      return id;
    });
    await tester.runAsync(() async {
      final id = await scope!.testing.materials.create(title: '线性代数讲义');
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 2,
        content: '矩阵的秩按行阶梯形里的非零行计数。',
        label: '秩与行阶梯',
      );
    });

    // 选择器从讨论页打开；这里直接从应用内的上下文调起，验证同一条返回路径。
    final context = tester.element(find.byType(HomeShell));
    MaterialSelection? selection;
    await tester.runAsync(() async {
      unawaited(showMaterialPicker(context).then((value) => selection = value));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await pumpUntil(tester, find.text('这次依据哪份材料'));
    expect(find.text('概率论讲义'), findsOneWidget);
    expect(find.text('线性代数讲义'), findsOneWidget);

    final pickerField = find.descendant(
      of: find.byKey(const ValueKey('material-picker-search')),
      matching: find.byType(EditableText),
    );

    // 标题过滤：另一份材料从候选里消失。
    await tester.enterText(pickerField, '概率');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.text('标题命中'));
    await pumpUntilGone(tester, find.text('线性代数讲义'));
    expect(find.text('概率论讲义'), findsOneWidget);

    // 页标签过滤：命中原因写明第几页的标签。
    await tester.enterText(pickerField, '秩与行阶梯');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.text('第 2 页的标签命中'));
    await pumpUntilGone(tester, find.text('概率论讲义'));
    expect(find.text('线性代数讲义'), findsOneWidget);

    // 没有命中时保留查询，并给出清除；清除之后回到全部候选。
    await tester.enterText(pickerField, '不存在的材料');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.text('没有找到「不存在的材料」'));
    expect(find.text('清除查询'), findsOneWidget);
    await tester.tap(find.text('清除查询'));
    await pumpUntil(tester, find.text('概率论讲义'));
    expect(find.text('线性代数讲义'), findsOneWidget);
    expect(find.text('没有找到「不存在的材料」'), findsNothing);
    expect(tester.widget<EditableText>(pickerField).controller.text, isEmpty);

    // 选中材料之后仍走原来的页码选择，返回值不变。
    await tester.tap(find.text('概率论讲义'));
    await pumpUntil(tester, find.text('《概率论讲义》的哪一页'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('第 1 页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(selection, isNotNull);
    expect(selection!.materialId, probability);
    expect(selection!.pageNo, 1);
    expect(selection!.label, '《概率论讲义》第 1 页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('材料查找失败之后只留说明，不再挂着“正在查找…”', (tester) async {
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

    await tester.runAsync(() async {
      final id = await scope!.testing.materials.create(title: '概率论讲义');
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 1,
        content: '条件概率的定义与乘法公式。',
      );
    });

    final context = tester.element(find.byType(HomeShell));
    await tester.runAsync(() async {
      unawaited(showMaterialPicker(context));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await pumpUntil(tester, find.text('这次依据哪份材料'));

    final pickerField = find.descendant(
      of: find.byKey(const ValueKey('material-picker-search')),
      matching: find.byType(EditableText),
    );
    // 首查失败：说明上方已经写明原因，结果区不再留一句永远不结束的读取中。
    scope!.testing.failNextMaterialSearch();
    await tester.enterText(pickerField, '概率');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.textContaining('查找材料没有完成'));
    expect(find.text('正在查找…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选好材料之后读取页码失败会给出提示，选择结果为 null', (tester) async {
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

    await tester.runAsync(() async {
      final id = await scope!.testing.materials.create(title: '概率论讲义');
      await scope!.testing.materials.addPage(
        materialId: id,
        pageNo: 1,
        content: '条件概率的定义与乘法公式。',
      );
    });

    final context = tester.element(find.byType(HomeShell));
    MaterialSelection? selection;
    await tester.runAsync(() async {
      unawaited(showMaterialPicker(context).then((value) => selection = value));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await pumpUntil(tester, find.text('这次依据哪份材料'));
    expect(find.text('概率论讲义'), findsOneWidget);

    // 选好材料之后再读页码：注入一次失败，提示要出现，异常不留给框架。
    scope!.testing.failNextMaterialPagesRead();
    await tester.tap(find.text('概率论讲义'));
    await pumpUntil(tester, find.textContaining('读取这份材料的页码没有完成'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(selection, isNull);
    expect(tester.takeException(), isNull);
  });
}
