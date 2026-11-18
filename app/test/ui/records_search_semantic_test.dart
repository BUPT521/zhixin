import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/rules/embedding.dart';
import 'package:zhixin/ui/records_search_page.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

/// 查找页的“按意思找”：本地结果先出，语义完成后按融合顺序刷新；失败、空索引
/// 与只有语义命中的情况各自给出应有的状态，而不是混成一个空态。
const _spec = EmbeddingModelSpec(id: 'ui-test-embed', dim: 4, provider: 'test');

/// 这些用例走应用根创建的真实 zvec 索引，没有本机 C 库时刷新必然失败；
/// 没有设置库路径时整组跳过，CI 与本机按同一套环境变量运行。
final _skipWithoutZvec =
    (Platform.environment['ZVEC_LIBRARY_PATH'] ?? '').isNotEmpty
    ? null
    : '未设置 ZVEC_LIBRARY_PATH，跳过真实 zvec 的界面用例';

class _FailingClient extends EmbeddingClient {
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
  if (_skipWithoutZvec != null) stdout.writeln(_skipWithoutZvec);
  late Directory directory;
  AppScopeState? scope;

  setUpAll(() {});

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-search-meaning-');
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

  /// 等查找页自己出现的内容：列表后面还压着记录页，按文字找会先命中记录页的
  /// 预览，等于没等到本次查找的结果。
  Future<void> pumpUntilInSearchPage(WidgetTester tester, Finder finder) =>
      pumpUntil(
        tester,
        find.descendant(of: find.byType(RecordsSearchPage), matching: finder),
      );

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.text('记录').last);
    // 切栏是整幅滑入，动画在换栏之后的下一帧才开始；先起一帧再把时间推过
    // 时长，记录栏才回到原位置，可以点它的搜索入口。
    await tester.pump();
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
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      final meaning = await scope!.testing.conversations.create(title: '线性无关');
      await scope!.testing.conversations.append(
        meaning,
        role: MessageRole.user,
        content: '线性无关的行向量个数',
      );
      scope!.library.searchIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            '线性无关的行向量个数': [0.98, 0.1, 0, 0],
          },
        ),
      );
      final refresh = await scope!.library.searchIndex.refresh();
      expect(refresh.failed, 0);
    });

    await openSearch(tester);
    await search(tester, '矩阵');
    await pumpUntilInSearchPage(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('按意思'));
    await pumpUntil(tester, find.textContaining('线性无关的行向量个数'));
    expect(find.textContaining('矩阵的秩怎么求'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  }, skip: _skipWithoutZvec != null);

  testWidgets('语义失败只在列表上方加一行提示', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      scope!.library.searchIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
          },
        ),
      );
      expect((await scope!.library.searchIndex.refresh()).failed, 0);
      scope!.library.searchIndex.configure(client: _FailingClient());
    });

    await openSearch(tester);
    await search(tester, '矩阵');
    await pumpUntilInSearchPage(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('检索索引没有完成，下面是原文与关键词结果'));
    expect(find.text('按意思'), findsNothing);
    expect(find.textContaining('矩阵的秩怎么求'), findsWidgets);
    expect(tester.takeException(), isNull);
    await drain(tester);
  }, skip: _skipWithoutZvec != null);

  testWidgets('语义索引为空时说明还没有内容，而不是没有找到', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      scope!.library.searchIndex.configure(
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
    await pumpUntilInSearchPage(tester, find.textContaining('矩阵的秩怎么求'));

    await tester.tap(find.text('按意思找'));
    await pumpUntil(tester, find.text('检索索引还没有内容，可以在设置里更新'));
    expect(find.text('没有找到意思相近的记录'), findsNothing);
    expect(find.textContaining('矩阵的秩怎么求'), findsWidgets);
    expect(tester.takeException(), isNull);
    await drain(tester);
  }, skip: _skipWithoutZvec != null);

  testWidgets('只有语义命中时不显示空态', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      final meaning = await scope!.testing.conversations.create(title: '面积与缩放');
      await scope!.testing.conversations.append(
        meaning,
        role: MessageRole.user,
        content: 'det(A) 的几何意义是面积缩放',
      );
      scope!.library.searchIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '行列式': [1, 0, 0, 0],
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            'det(A) 的几何意义是面积缩放': [0.98, 0.1, 0, 0],
          },
        ),
      );
      expect((await scope!.library.searchIndex.refresh()).failed, 0);
    });

    await openSearch(tester);
    await search(tester, '行列式');
    // 索引接入普通查找之后，关键词没有字面命中的记录也会由语义一路返回，
    // 页面不显示空态；“按意思”标签照常标出这条候选来自语义。
    await pumpUntilInSearchPage(
      tester,
      find.textContaining('det(A) 的几何意义是面积缩放'),
    );
    expect(find.text('按意思'), findsWidgets);
    expect(find.textContaining('没有找到「行列式」'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  }, skip: _skipWithoutZvec != null);

  testWidgets('普通写入之后下一次刷新只补新来源，不整份重建', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      scope!.library.searchIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            '线性无关的行向量个数': [0.98, 0.1, 0, 0],
          },
        ),
      );
      expect((await scope!.library.searchIndex.refresh()).embedded, 1);

      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '线性无关的行向量个数',
      );
      final next = await scope!.library.searchIndex.refresh();
      expect(next.embedded, 1);
      expect(next.skipped, 1);
      // 等安静期的后台刷新跑完，收尾时没有仍在运行的索引操作。
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await drain(tester);
  }, skip: _skipWithoutZvec != null);

  testWidgets('来源表写入之后按安静期补进索引', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final local = await scope!.testing.conversations.create(title: '矩阵讨论');
      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '矩阵的秩怎么求',
      );
      scope!.library.searchIndex.configure(
        client: FixedEmbeddingClient(
          spec: _spec,
          vectors: {
            '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
            '线性无关的行向量个数': [0.98, 0.1, 0, 0],
          },
        ),
      );
      expect((await scope!.library.searchIndex.refresh()).embedded, 1);

      await scope!.testing.conversations.append(
        local,
        role: MessageRole.user,
        content: '线性无关的行向量个数',
      );
      // 不手动刷新：等安静期之后的后台刷新把新来源写进索引。
      await Future<void>.delayed(const Duration(seconds: 5));
      final stats = await scope!.library.searchIndex.stats();
      expect(stats.entries, 2);
      expect(stats.lastRefresh?.embedded, 1);
    });
    await drain(tester);
  }, skip: _skipWithoutZvec != null);
}
