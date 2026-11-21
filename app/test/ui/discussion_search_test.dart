import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/rules/discussion_search.dart';
import 'package:zhixin/ui/discussion_message.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/discussion_search.dart';
import 'package:zhixin/ui/theme.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 讨论内查找：计数、上一处与下一处、高亮切换、空查询与关闭后恢复。
///
/// 消息直接用仓库写进内存库，页面按同一条记录打开；查找读的是本地库，不经过
/// 模型，因此这些用例在未配置模型时也能跑完。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'zhixin-discussion-search-',
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

  /// 轮询到条件成立：跳转、选中这类状态没有能等的控件，按同一段早晚轮询判断，
  /// 不按固定时长猜。
  Future<void> pumpUntilTrue(
    WidgetTester tester,
    bool Function() condition, {
    String description = '等待条件成立',
    int rounds = 480,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await advanceAsync(
        tester,
        scope?.testing.gate,
        const Duration(milliseconds: 20),
      );
      if (condition()) return;
    }
    fail('$description超时');
  }

  /// 轮询到目标控件出现或消失：读写都在后台排队，不能依赖 pumpAndSettle。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    bool gone = false,
    int rounds = 480,
  }) => pumpUntilTrue(
    tester,
    () => finder.evaluate().isNotEmpty != gone,
    description: gone ? '等待控件消失：$finder' : '等待界面出现：$finder',
    rounds: rounds,
  );

  /// 等后台读取收尾：等应用自己的访问队列清空，再画几帧让回填完成。
  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester, scope);
  }

  Future<void> openApp(
    WidgetTester tester, {
    Size size = const Size(390, 1400),
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

  /// 按给定角色与正文写一条讨论，返回记录编号。
  Future<String> seedConversation(
    WidgetTester tester,
    List<(MessageRole, String)> rows,
  ) async {
    return (await tester.runAsync(() async {
      final conversations = scope!.testing.conversations;
      final id = await conversations.create(title: '讨论内查找');
      for (final (role, content) in rows) {
        await conversations.append(id, role: role, content: content);
      }
      return id;
    }))!;
  }

  Future<void> openDiscussion(WidgetTester tester, String id) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('discussion-search-open')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('discussion-search-field')),
      findsOneWidget,
    );
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(
      find.byKey(const ValueKey('discussion-search-field')),
      query,
    );
    await tester.pump();
  }

  /// 当前带高亮的那一条消息；正常情况下最多一条。
  List<DiscussionMessage> highlighted(WidgetTester tester) => tester
      .widgetList<DiscussionMessage>(find.byType(DiscussionMessage))
      .where((message) => message.highlighted)
      .toList(growable: false);

  double listOffset(WidgetTester tester) {
    final list = tester.widget<ListView>(find.byType(ListView).first);
    return list.controller!.offset;
  }

  group('讨论内查找规则', () {
    ChatMessage message(String id, MessageRole role, String content) =>
        ChatMessage(
          id: id,
          conversationId: 'conv-1',
          role: role,
          content: content,
        );

    test('一条消息算一处，用户与搭子的消息参与，空查询没有命中', () {
      final messages = [
        message('1', MessageRole.user, '这里的 Apple 很甜。'),
        message('2', MessageRole.assistant, '回答里也提到 apple。'),
        message('3', MessageRole.user, '没有关键词。'),
        message('4', MessageRole.system, '系统行不参与查找。'),
      ];

      final hits = searchDiscussionMessages(messages, 'apple');
      expect(hits.map((item) => item.id), ['1', '2']);
      expect(searchDiscussionMessages(messages, '  '), isEmpty);
      expect(searchDiscussionMessages(messages, '系统行'), isEmpty);
    });
  });

  testWidgets('读取失败时就地说明并给重试，不收起查找条', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        builder: (context, child) =>
            forui.FTheme(data: zhixinForuiTheme, child: child!),
        home: Scaffold(
          body: DiscussionSearchBar(
            controller: controller,
            focusNode: focus,
            query: '苹果',
            matchCount: 0,
            matchIndex: -1,
            loading: false,
            failure: '查找没有完成；讨论与已经显示的消息没有改动。',
            onSubmitted: (_) {},
            onPrevious: () {},
            onNext: () {},
            onRetry: () => retried++,
            onClose: () {},
          ),
        ),
      ),
    );

    expect(find.text('查找没有完成；讨论与已经显示的消息没有改动。'), findsOneWidget);
    expect(find.byKey(const ValueKey('discussion-search-count')), findsNothing);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull);
  });

  testWidgets('多消息里显示命中数与当前位置，当前一条带高亮', (tester) async {
    await openApp(tester);
    final id = await seedConversation(tester, const [
      (MessageRole.user, '第一行：这里的苹果很甜。'),
      (MessageRole.assistant, '回答里也提到苹果。'),
      (MessageRole.user, '第二条消息没有关键词。'),
      (MessageRole.assistant, '再补一句，苹果是一种水果。'),
      (MessageRole.user, '第三条，苹果又出现了。'),
    ]);
    await openDiscussion(tester, id);
    await pumpUntil(
      tester,
      find.textContaining('第一行：这里的苹果很甜。', findRichText: true),
    );

    await openSearch(tester);
    await typeQuery(tester, '苹果');
    await pumpUntil(tester, find.text('1/4'));

    final hits = highlighted(tester);
    expect(hits, hasLength(1));
    expect(hits.single.message.content, '第一行：这里的苹果很甜。');
    expect(tester.takeException(), isNull);
  });

  testWidgets('上一处与下一处逐条跳转，旧的高亮随之消失', (tester) async {
    await openApp(tester);
    final id = await seedConversation(tester, const [
      (MessageRole.user, '第一行：这里的苹果很甜。'),
      (MessageRole.assistant, '回答里也提到苹果。'),
      (MessageRole.user, '第二条消息没有关键词。'),
      (MessageRole.assistant, '再补一句，苹果是一种水果。'),
      (MessageRole.user, '第三条，苹果又出现了。'),
    ]);
    await openDiscussion(tester, id);
    await pumpUntil(
      tester,
      find.textContaining('第一行：这里的苹果很甜。', findRichText: true),
    );
    await openSearch(tester);
    await typeQuery(tester, '苹果');
    await pumpUntil(tester, find.text('1/4'));

    final first = highlighted(tester).single.message;

    await tester.tap(find.byKey(const ValueKey('discussion-search-next')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2/4'), findsOneWidget);
    final second = highlighted(tester);
    expect(second, hasLength(1));
    expect(second.single.message.content, '回答里也提到苹果。');
    expect(second.single.message.id, isNot(first.id));

    await tester.tap(find.byKey(const ValueKey('discussion-search-next')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3/4'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('discussion-search-previous')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2/4'), findsOneWidget);
    expect(highlighted(tester), hasLength(1));
    expect(highlighted(tester).single.message.id, second.single.message.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空查询与没有命中分别给出说明', (tester) async {
    await openApp(tester);
    final id = await seedConversation(tester, const [
      (MessageRole.user, '第一条消息里有苹果。'),
      (MessageRole.assistant, '回答只有别的内容。'),
    ]);
    await openDiscussion(tester, id);
    await pumpUntil(
      tester,
      find.textContaining('第一条消息里有苹果。', findRichText: true),
    );

    await openSearch(tester);
    expect(find.text('输入关键词，只在本条讨论的消息里查找。'), findsOneWidget);
    expect(find.byKey(const ValueKey('discussion-search-count')), findsNothing);

    await typeQuery(tester, '不存在的词');
    await pumpUntil(tester, find.textContaining('没有找到「不存在的词」'));
    expect(find.byKey(const ValueKey('discussion-search-count')), findsNothing);
    expect(highlighted(tester), isEmpty);

    await typeQuery(tester, '');
    await pumpUntil(tester, find.text('输入关键词，只在本条讨论的消息里查找。'));
    expect(find.byKey(const ValueKey('discussion-search-count')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有翻到的更早消息也在查找范围里', (tester) async {
    await openApp(tester);
    final id = await seedConversation(tester, [
      (MessageRole.user, '最早的一条：查找用的词只在最早这一条里。'),
      for (var index = 1; index <= 51; index++)
        (
          index.isEven ? MessageRole.assistant : MessageRole.user,
          '第 $index 条消息用来占满最近一页。',
        ),
    ]);
    await openDiscussion(tester, id);
    // 第一页只给最近 50 条，最早这条还没有显示在页面上。
    await pumpUntil(
      tester,
      find.textContaining('第 51 条消息用来占满最近一页。', findRichText: true),
    );
    expect(find.textContaining('最早的一条', findRichText: true), findsNothing);

    await openSearch(tester);
    await typeQuery(tester, '最早这一条');
    await pumpUntil(tester, find.text('1/1'));
    // 目标在屏幕外时，先建出定位键再滚到它：等它进入可见区域才带高亮。
    await pumpUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is DiscussionMessage && widget.highlighted,
      ),
    );
    expect(highlighted(tester).single.message.content, contains('最早这一条'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏下打开查找条不溢出，命中照常显示', (tester) async {
    await openApp(tester, size: const Size(320, 700));
    final id = await seedConversation(tester, const [
      (MessageRole.user, '窄屏里的第一条消息，带苹果。'),
      (MessageRole.assistant, '窄屏里的回答。'),
    ]);
    await openDiscussion(tester, id);
    await pumpUntil(
      tester,
      find.textContaining('窄屏里的第一条消息，带苹果。', findRichText: true),
    );

    await openSearch(tester);
    await typeQuery(tester, '苹果');
    await pumpUntil(tester, find.text('1/1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭查找后回到原来的列表与滚动位置', (tester) async {
    await openApp(tester, size: const Size(390, 700));
    final id = await seedConversation(tester, [
      (MessageRole.user, '最上面的一条：最早这条里有查找用的词。'),
      for (var index = 1; index <= 12; index++)
        (
          index.isEven ? MessageRole.assistant : MessageRole.user,
          '第 $index 条填充消息，用来把列表撑长一点。',
        ),
      (MessageRole.user, '最下面的一条，没有关键词。'),
    ]);
    await openDiscussion(tester, id);
    await pumpUntil(
      tester,
      find.textContaining('最下面的一条，没有关键词。', findRichText: true),
    );

    final controller = tester
        .widget<ListView>(find.byType(ListView).first)
        .controller!;
    controller.jumpTo(160);
    await tester.pump(const Duration(milliseconds: 100));
    final before = listOffset(tester);
    expect(before, greaterThan(0));

    await openSearch(tester);
    await typeQuery(tester, '最早这条');
    await pumpUntil(tester, find.text('1/1'));
    // 命中在最早一条：跳转会离开原来的位置。跳转要看消息载入之后的布局，等它真
    // 的滚开，不按固定时长猜；滚开之后再走一小段，让跳转停稳。
    await pumpUntilTrue(
      tester,
      () => (listOffset(tester) - before).abs() > 0.5,
      description: '等待列表从原来的位置滚开',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(listOffset(tester), isNot(closeTo(before, 0.5)));
    expect(highlighted(tester).single.message.content, contains('最早这条'));

    await tester.tap(find.byKey(const ValueKey('discussion-search-close')));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('discussion-search-field')),
      gone: true,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(listOffset(tester), closeTo(before, 0.5));
    expect(highlighted(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
