import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/docx_import.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

import '../support/docx_fixture.dart';

/// 材料列表与材料详情改成订阅之后，页面之外的写入由数据层重读（ADR-0014）。
///
/// 这里不点右上角刷新，也不返回重进：写入发生在页面之外，界面只靠订阅更新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-materials-live-');
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

  /// 轮询到目标控件出现；读取与回填都在后台完成，不能依赖 pumpAndSettle 收尾。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 120,
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

  testWidgets('材料列表跟随订阅更新，不需要手动刷新', (tester) async {
    await openApp(tester);
    await tester.runAsync(() => scope!.library.material.create(title: '待阅讲义'));
    await openMaterialsTab(tester);
    await pumpUntil(tester, find.text('待阅讲义'));

    // 页面之外的写入：列表由订阅自己重读，不点刷新也不切页签。
    await tester.runAsync(
      () => scope!.library.material.create(title: '刚导入的讲义'),
    );
    await pumpUntil(tester, find.text('刚导入的讲义'));
    expect(find.text('待阅讲义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空材料详情给出添加一页入口，保存后就地显示这一页', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.library.material.create(title: '还没有原文的材料'),
    );
    await openMaterialsTab(tester);
    await pumpUntil(tester, find.text('还没有原文的材料'));
    await tester.tap(find.text('还没有原文的材料'));
    await pumpUntil(tester, find.text('这份材料还没有原文'));

    // 空态自带「添加一页」，详情页不再让用户去找材料列表行尾的按钮。
    await tester.tap(find.text('添加一页'));
    await pumpUntil(tester, find.byType(forui.FDialog));
    final fields = find.descendant(
      of: find.byType(forui.FDialog),
      matching: find.byType(EditableText),
    );
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(2), '从详情空态补上的第一页。');
    await tester.tap(find.text('保存'));
    await pumpUntil(tester, find.text('从详情空态补上的第一页。'));
    expect(find.text('这份材料还没有原文'), findsNothing);
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });

  testWidgets('Word 材料按片段称呼，详情不给添加一页', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final document = await DocxImport.read(
        '概率讲义.docx',
        Stream.value(docxFixture()),
      );
      await scope!.library.material.importDocx(
        document: document,
        title: '概率讲义',
        expectedEpoch: scope!.library.material.dataEpoch,
      );
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, find.text('概率讲义'));
    expect(find.textContaining('个片段'), findsOneWidget);

    await tester.tap(find.text('概率讲义'));
    // Word 材料的页在详情里也叫片段，与列表、引用一致。
    await pumpUntil(tester, find.textContaining('第 1 个片段'));
    expect(find.text('添加一页'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });

  testWidgets('材料详情在补充与更正之后自动重读', (tester) async {
    await openApp(tester);
    final materialId = await tester.runAsync(() async {
      final id = await scope!.library.material.create(
        title: '导数讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: id,
        pageNo: 1,
        content: '导数描述函数在一点附近的变化率。',
      );
      return id;
    });
    await openMaterialsTab(tester);
    await pumpUntil(tester, find.text('导数讲义'));
    await tester.tap(find.text('导数讲义'));
    await pumpUntil(tester, find.text('导数描述函数在一点附近的变化率。'));

    // 从页面之外补一页，详情按订阅读到新页。
    await tester.runAsync(
      () => scope!.library.material.addPage(
        materialId: materialId!,
        pageNo: 2,
        content: '补充的第二页原文。',
      ),
    );
    await pumpUntil(tester, find.text('补充的第二页原文。'));

    // 更正第 1 页，页面不返回重进就能看到更正后的原文。
    await tester.runAsync(() async {
      final page = await scope!.library.material.page(materialId!, 1);
      await scope!.library.material.correctPage(
        page: page!,
        corrected: '更正后的第一页原文。',
      );
    });
    await pumpUntil(tester, find.text('更正后的第一页原文。'));
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });
}
