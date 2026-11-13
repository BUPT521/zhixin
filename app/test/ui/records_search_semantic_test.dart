import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/domain/rules/embedding.dart';
import 'package:zhixin/ui/records_search_page.dart';

/// 查找页的“按意思找”：本地结果先出，语义完成后按融合顺序刷新；失败、空索引
/// 与只有语义命中的情况各自给出应有的状态，而不是混成一个空态。
const _spec = EmbeddingModelSpec(id: 'ui-test-embed', dim: 4, provider: 'test');

class _FailingClient implements EmbeddingClient {
  @override
  EmbeddingModelSpec get spec => _spec;

  @override
  Future<List<double>> embed(String text) async {
    throw const EmbeddingUnavailable('测试里的嵌入服务不可用');
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-search-meaning-');
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
    scope?.library.semanticIndex.close();
    await scope?.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

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

  /// 等首页读取收尾：数据库访问在应用根里排队，种子写入要在界面之外运行。
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (round < 6) continue;
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    for (var round = 0; round < 6; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
  }

  /// 等页面在后台发起的读取结束，再进入 teardown 关库；关库要等所有共享读
  /// 释放，测试结束时仍在排队的读取会让它一直等下去。
  Future<void> drain(WidgetTester tester) async {
    for (var round = 0; round < 10; round++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
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

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.text('记录').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('records-search-entry')));
    await pumpUntil(tester, find.text('搜索记录'));
  }

  Future<void> search(WidgetTester tester, String query) async {
    final field = find.descendant(
      of: find.byType(RecordsSearchPage),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
  }

  testWidgets('本地结果先出，语义完成后加“按意思”标签', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.conversations.create(title: '矩阵讨论');
      await scope!.conversations.append(
        local,
        role: 'user',
        content: '矩阵的秩怎么求',
      );
      final meaning = await scope!.conversations.create(title: '线性无关');
      await scope!.conversations.append(
        meaning,
        role: 'user',
        content: '线性无关的行向量个数',
      );
      scope!.library.semanticIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            '线性无关的行向量个数': [0.98, 0.1, 0, 0],
          },
        ),
      );
      final refresh = await scope!.library.semanticIndex.refresh();
      expect(refresh.failed, 0);
    });

    await openSearch(tester);
    await search(tester, '矩阵');
    await pumpUntil(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('按意思'));
    await pumpUntil(tester, find.textContaining('线性无关的行向量个数'));
    expect(find.textContaining('矩阵的秩怎么求'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('语义失败只在列表上方加一行提示', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.conversations.create(title: '矩阵讨论');
      await scope!.conversations.append(
        local,
        role: 'user',
        content: '矩阵的秩怎么求',
      );
      scope!.library.semanticIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
          },
        ),
      );
      expect((await scope!.library.semanticIndex.refresh()).failed, 0);
      scope!.library.semanticIndex.configure(client: _FailingClient());
    });

    await openSearch(tester);
    await search(tester, '矩阵');
    await pumpUntil(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('按意思的部分没有完成，下面是原文与关键词结果'));
    expect(find.text('按意思'), findsNothing);
    expect(find.textContaining('矩阵的秩怎么求'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('语义索引为空时说明还没有内容，而不是没有找到', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.conversations.create(title: '矩阵讨论');
      await scope!.conversations.append(
        local,
        role: 'user',
        content: '矩阵的秩怎么求',
      );
      scope!.library.semanticIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵': [1, 0, 0, 0],
          },
        ),
      );
    });

    await openSearch(tester);
    await search(tester, '矩阵');
    await pumpUntil(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('语义索引还没有内容，可以在设置里更新'));
    expect(find.text('没有找到意思相近的记录'), findsNothing);
    expect(find.textContaining('矩阵的秩怎么求'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('只有语义命中时不显示空态', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.conversations.create(title: '矩阵讨论');
      await scope!.conversations.append(
        local,
        role: 'user',
        content: '矩阵的秩怎么求',
      );
      final meaning = await scope!.conversations.create(title: '面积与缩放');
      await scope!.conversations.append(
        meaning,
        role: 'user',
        content: 'det(A) 的几何意义是面积缩放',
      );
      scope!.library.semanticIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '行列式': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            'det(A) 的几何意义是面积缩放': [0.98, 0.1, 0, 0],
          },
        ),
      );
      expect((await scope!.library.semanticIndex.refresh()).failed, 0);
    });

    await openSearch(tester);
    await search(tester, '行列式');
    await pumpUntil(tester, find.textContaining('没有找到「行列式」'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('按意思'));
    await pumpUntil(tester, find.textContaining('det(A) 的几何意义是面积缩放'));
    expect(find.textContaining('没有找到「行列式」'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });
}
