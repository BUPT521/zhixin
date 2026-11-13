import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/platform/data_package_export.dart';
import 'package:zhixin/ui/data_version_page.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/format.dart';
import 'package:zhixin/ui/learning_page.dart';
import 'package:zhixin/ui/materials_page.dart';
import 'package:zhixin/ui/now_page.dart';
import 'package:zhixin/ui/plan_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/study_plan_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';
import 'package:zhixin/ui/zhixin_chip.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

Finder _editableFields() => find.byWidgetPredicate(
  (widget) => widget is EditableText && !widget.readOnly,
);

/// FSelect.rich 返回的是私有子类，按类型取不到，只能按祖先判断。
Finder _select<T>(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is forui.FSelect<T>),
);

Finder _selectField<T>(String label) =>
    find.descendant(of: _select<T>(label), matching: find.byType(EditableText));

/// 设置页自身的滚动区域。下拉框和输入框内部也有 Scrollable，
/// 直接取 Scrollable 会拿到输入框里面那个横向的。
Finder _settingsScrollable() => find
    .descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 进入应用之后才回答的模型替身：用例在恢复数据之后才让它返回，
/// 用来走“等待回答期间发生了恢复”的页面路径。
class _DelayedHelpAi implements BuddyAi {
  final Completer<void> entered = Completer<void>();
  final Completer<void> resume = Completer<void>();

  @override
  Future<LlmConfig?> config() async => null;

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await resume.future;
    return const BuddyReply(text: '恢复之后才回来的提示');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;
  final previewKey = GlobalKey();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-ui-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final fontPath = Platform.environment['ZHIXIN_PREVIEW_FONT'];
    if (fontPath != null) {
      final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
      for (final family in ['Roboto', 'Ahem']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  tearDown(() async {
    await scope?.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

  /// FToast 的自动收起靠定时器；在测试里推进到它收起，避免用例结束时留下未触发的计时器。
  Future<void> clearToasts(WidgetTester tester) async {
    if (find.byType(forui.FToaster).evaluate().isEmpty) return;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    for (var i = 0; i < 40; i++) {
      // 发送按钮生成中只显示停止图标，不再有转圈，按停止按钮判断仍在请求。
      final busy =
          find.byType(forui.FCircularProgress).evaluate().isNotEmpty ||
          find.byIcon(FLucideIcons.square).evaluate().isNotEmpty;
      if (!busy) break;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await clearToasts(tester);
    expect(find.byType(forui.FCircularProgress), findsNothing);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<void> openApp(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    BuddyAi? ai,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: ZhixinApp(ai: ai),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await settle(tester);
  }

  testWidgets('生产装配的仓库受数据库独占访问协调', (tester) async {
    await openApp(tester);

    await tester.runAsync(() async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final lock = scope!.gate.exclusive(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var writeFinished = false;
      final write = scope!.tasks
          .createGoal(title: '恢复期间的新目标')
          .then((_) => writeFinished = true);
      await Future<void>.delayed(Duration.zero);
      expect(writeFinished, isFalse);

      release.complete();
      await lock;
      await write;
      expect(writeFinished, isTrue);
    });
  });

  testWidgets('手动导出只向平台传临时文件路径，恢复后仓库可以继续读写', (tester) async {
    await openApp(tester);

    await tester.runAsync(() async {
      final beforeId = await scope!.tasks.createGoal(title: '恢复前保留目标');
      final settings = scope!.settings.edit;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.zhixin.app/data_package');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final exported = File('${directory.path}/export.zip');
      late File temporary;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'save');
        final arguments = call.arguments as Map;
        expect(arguments.keys, unorderedEquals(['path', 'fileName']));
        expect(arguments['fileName'], settings.exportFileName());
        temporary = File(arguments['path'] as String);
        await temporary.copy(exported.path);
        return 'content://test/export.zip';
      });
      final uri = await saveDataPackage(
        fileName: settings.exportFileName(),
        writePackage: scope!.backupRepository,
      );
      expect(uri, 'content://test/export.zip');
      expect(await temporary.parent.exists(), isFalse);

      await settings.restoreBytes(await exported.readAsBytes());

      expect((await scope!.tasks.goalById(beforeId))?.title, '恢复前保留目标');
      final points = await scope!.data.restorePoints.list();
      expect(points, hasLength(1));
      expect(await File(points.single.path).exists(), isTrue);
      expect(points.single.head, await scope!.currentHead());
      final afterId = await scope!.tasks.createGoal(title: '恢复后新增目标');
      expect((await scope!.tasks.goalById(afterId))?.title, '恢复后新增目标');

      // 恢复点用同一条整库恢复流程，可以真正回到保存时的数据。
      await scope!.restore(await File(points.single.path).readAsBytes());
      expect(await scope!.tasks.goalById(afterId), isNull);
      expect((await scope!.tasks.goalById(beforeId))?.title, '恢复前保留目标');
    });
  });

  Future<void> preview(WidgetTester tester, String name) async {
    final target = Platform.environment['ZHIXIN_UI_PREVIEW_DIR'];
    if (target == null) return;
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(target).create(recursive: true);
      await File('$target/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('首页入口直达材料与系统学习，切换后保留未发送的问题', (tester) async {
    await openApp(tester);
    await preview(tester, 'now-empty');
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '保留这个问题',
    );
    tester.testTextInput.hide();
    await tester.tap(find.text('从材料开始学习'));
    await settle(tester);
    expect(find.text('导入材料'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await preview(tester, 'records-materials');
    await tester.tap(find.text('现在').last);
    await settle(tester);
    expect(find.text('保留这个问题'), findsOneWidget);
    await tester.tap(find.text('系统学习').first);
    await settle(tester);
    final planList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(planList, const Offset(0, -1200));
    await settle(tester);
    final materialButton = find.text('选择学习材料').last;
    expect(materialButton, findsOneWidget);
    await tester.ensureVisible(materialButton);
    await tester.tap(materialButton.hitTestable());
    await settle(tester);
    expect(find.text('导入材料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底栏按下时图标位置固定，选中胶囊连续滑动', (tester) async {
    await openApp(tester);
    final bar = find.byType(forui.FBottomNavigationBar);
    Finder icon(IconData data) =>
        find.descendant(of: bar, matching: find.byIcon(data));
    final pill = find.ancestor(of: bar, matching: find.byType(Stack)).first;
    final indicator = find.descendant(
      of: pill,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is ShapeDecoration &&
            (widget.decoration as ShapeDecoration).shape is StadiumBorder,
      ),
    );
    final start = tester.getCenter(icon(FLucideIcons.house));
    final targetIcon = icon(FLucideIcons.history);
    final iconRect = tester.getRect(targetIcon);
    final next = iconRect.center;
    expect(tester.getCenter(indicator), offsetMoreOrLessEquals(start));

    final gesture = await tester.startGesture(next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final pressedRect = tester.getRect(targetIcon);
    expect(pressedRect.size, iconRect.size);
    expect(pressedRect.center, offsetMoreOrLessEquals(next));
    expect(tester.getCenter(indicator), offsetMoreOrLessEquals(start));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getCenter(indicator).dx, inExclusiveRange(start.dx, next.dx));
    expect(tester.getCenter(indicator).dy, moreOrLessEquals(start.dy));
    await settle(tester);
    expect(tester.getCenter(indicator), offsetMoreOrLessEquals(next));
  });

  testWidgets('从记录打开讨论再返回，筛选与首页输入都不重置', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final goal = await scope!.tasks.createGoal(title: '概率练习');
      final conversation = await scope!.conversations.create(
        title: '待结束的讨论',
        goalId: goal,
      );
      await scope!.conversations.append(
        conversation,
        role: 'user',
        content: '从记录里打开这条讨论',
      );
      await scope!.conversations.append(
        conversation,
        role: 'assistant',
        content: '返回之后记录仍然刷新',
      );
    });
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '保留这个问题',
    );
    tester.testTextInput.hide();
    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text('记录'),
      ),
    );
    await settle(tester);

    // 先按目标筛选，返回后用它判断记录页有没有被换掉重建。
    ZhixinChip goalChip() => tester.widget<ZhixinChip>(
      find.ancestor(of: find.text('概率练习'), matching: find.byType(ZhixinChip)),
    );
    await tester.tap(find.text('概率练习'));
    await settle(tester);
    expect(goalChip().selected, isTrue);

    await tester.tap(find.text('待结束的讨论'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    await tester.tap(find.text('结束讨论'));
    await settle(tester);
    expect(find.text('已结束'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(RecordsPage), findsOneWidget);
    // 内容刷新：记录状态已经改过；界面状态保留：目标筛选还在原处。
    expect(
      find.descendant(of: find.byType(RecordsPage), matching: find.text('已结束')),
      findsOneWidget,
    );
    expect(goalChip().selected, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text('现在'),
      ),
    );
    await settle(tester);
    expect(find.text('保留这个问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长讨论按需构建，打开时停在最新一条', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.conversations.create(title: '长讨论');
      for (var index = 0; index < 60; index++) {
        await scope!.conversations.append(
          conversation,
          role: index.isEven ? 'user' : 'assistant',
          content: '第 $index 条消息',
        );
      }
      return conversation;
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    expect(find.text('第 59 条消息', findRichText: true), findsOneWidget);
    expect(find.text('第 0 条消息', findRichText: true), findsNothing);

    // 滚到最早的一端，滚动监听加载更早的一页后再滚到新的最早一端。
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await settle(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await settle(tester);
    expect(find.text('第 0 条消息', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习页可以进入先不看上次答案的独立重做', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '独立重做界面');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '旧的答案',
        isCorrect: true,
        independent: true,
      );
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('再答一次（先不看上次）'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('再答一次（先不看上次）'));
    await settle(tester);

    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回时草稿保存失败会留在学习页', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '保存失败也要留住');
      await scope!.chat.learning.openAttempt(id);
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.enterText(
      find.descendant(
        of: find.ancestor(
          of: find.text('答案或关键步骤'),
          matching: find.byType(forui.FTextField),
        ),
        matching: _editableFields(),
      ),
      '还没保存下来的草稿',
    );
    await tester.runAsync(() async {
      await scope!.db.execute('''
        CREATE TRIGGER fail_attempt_update BEFORE UPDATE ON attempt
        BEGIN
          SELECT RAISE(ABORT, '模拟草稿保存失败');
        END;
      ''');
    });

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);

    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.textContaining('保存草稿'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新打开学习页仍保持独立重做', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '重做状态要留下');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '上一次的答案',
        isCorrect: false,
        independent: true,
      );
      await scope!.chat.learning.openAttempt(id, independentRedo: true);
      return id;
    }))!;
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LearningPage(questionId: questionId),
      ),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(find.text('上一次的答案'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习页可以展开历次尝试的全部帮助', (tester) async {
    await openApp(tester, size: const Size(390, 1200));
    final id = (await tester.runAsync(() async {
      final conversationId = await scope!.chat.learning.capture(stem: '展开全部帮助');
      for (var index = 0; index < 3; index++) {
        await scope!.chat.learning.help(
          questionId: conversationId,
          mode: BuddyMode.hint,
        );
      }
      return conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LearningPage(questionId: id)),
    );
    await settle(tester);

    expect(find.text('查看全部 3 次帮助'), findsOneWidget);
    expect(find.textContaining('· 提示：'), findsNWidgets(2));
    await tester.scrollUntilVisible(
      find.text('查看全部 3 次帮助'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('查看全部 3 次帮助'));
    await settle(tester);
    expect(find.text('收起较早帮助'), findsOneWidget);
    expect(find.textContaining('· 提示：'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('回答、记忆和建议卡片保留各自的操作', (tester) async {
    await openApp(tester, size: const Size(390, 900));
    final id = await tester.runAsync(() async {
      final conversation = await scope!.conversations.create(title: '条件概率');
      await scope!.conversations.append(
        conversation,
        role: 'user',
        content: '为什么条件概率要除以条件事件的概率？',
      );
      await scope!.conversations.append(
        conversation,
        role: 'assistant',
        content:
            '### 先缩小范围\n\n已知 B 发生时，只在 B 的范围内看 A。'
            '分子计算两件事同时发生的概率，分母将 B 的概率重新归一化。',
        structured: {
          'model': true,
          'citations': [
            {
              'material_id': 1,
              'material_title': '概率论讲义',
              'page_no': 7,
              'quote': '条件概率是已知一个事件发生时，另一个事件发生的概率。',
              'verified': true,
            },
          ],
          'memory_items': [
            {
              'id': 'memory-1',
              'kind': 'preference',
              'content': '讲解概率时先用具体例子。',
              'source': 'inferred',
              'status': 'pending',
            },
          ],
          'next_steps': [
            {
              'title': '用抽球问题练习条件概率',
              'action': '分别写出已知条件与要求的事件。',
              'minutes': 10,
            },
          ],
        },
      );
      return conversation;
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    expect(find.text('参考依据'), findsOneWidget);
    expect(find.text('记忆建议'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('下一步建议'), findsOneWidget);
    expect(find.text('约 10 分钟'), findsOneWidget);
    await preview(tester, 'model-cards');

    await tester.tap(find.text('记下'));
    await settle(tester);
    expect(find.text('已记下'), findsOneWidget);
    expect(find.text('待确认'), findsNothing);
    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect(find.text('已记下'), findsNothing);

    final dismiss = find.widgetWithText(forui.FButton, '暂不安排');
    await tester.ensureVisible(dismiss);
    await tester.tap(dismiss);
    await settle(tester);
    final history = await tester.runAsync(
      () => scope!.chat.discussion.history(id!),
    );
    expect(history!.last.structured?['dismissed'], ['用抽球问题练习条件概率']);
    await tester.pumpAndSettle();
    expect(find.text('下一步建议'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新问题独立保存，已有讨论保持原样，返回后可继续', (tester) async {
    await openApp(tester);
    final oldId = await tester.runAsync(
      () => scope!.chat.discussion.createConversation(title: '原有讨论'),
    );
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '导数的定义是什么',
    );
    await tester.tap(find.text('发送问题'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('导数的定义是什么'), findsOneWidget);
    final records = await tester.runAsync(
      () => scope!.chat.discussion.records(),
    );
    expect(records, hasLength(2));
    expect(records!.first.id, isNot(oldId));
    final original = await tester.runAsync(
      () => scope!.chat.discussion.history(oldId!),
    );
    expect(original, isEmpty);
    expect(tester.takeException(), isNull);
    await preview(tester, 'discussion');
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(NowPage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('导数的定义是什么'),
      180,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('导数的定义是什么'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结束讨论只改记录状态，发消息重新打开', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.conversations.create(title: '待结束的讨论');
      await scope!.conversations.append(
        conversation,
        role: 'user',
        content: '这条讨论要结束',
      );
      await scope!.conversations.append(
        conversation,
        role: 'assistant',
        content: '结束后仍可继续',
      );
      return conversation;
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    await tester.tap(find.text('结束讨论'));
    await settle(tester);
    expect(find.byType(forui.FDialog), findsNothing);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('已结束'), findsOneWidget);
    expect(find.text('结束讨论'), findsNothing);
    final ended = await tester.runAsync(() => scope!.chat.discussion.byId(id!));
    expect(ended!.open, isFalse);

    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .last,
      '再问一句',
    );
    await tester.tap(find.byIcon(FLucideIcons.arrowUp));
    await settle(tester);
    final reopened = await tester.runAsync(
      () => scope!.chat.discussion.byId(id!),
    );
    expect(reopened!.open, isTrue);
    expect(find.text('已结束'), findsNothing);
    expect(find.text('结束讨论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('继续上次按最近一次学习排序，并给出草稿与下一步', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: 'book',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率是已知一个事件发生时，另一个事件发生的概率。',
      );
      await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 1,
        pageTo: 1,
        title: '读完条件概率',
        steps: const [
          StudyStepDraft(title: '阅读条件概率的定义', pageFrom: 1, pageTo: 1),
        ],
      );
      final questionId = await scope!.chat.learning.capture(stem: '写出条件概率公式');
      final view = await scope!.chat.learning.view(questionId);
      await scope!.attempts.saveDraft(
        view.openAttempt!.id,
        answer: '先写出 P(A|B)=P(AB)/P(B)',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);

    expect(find.text('写出条件概率公式'), findsOneWidget);
    expect(find.textContaining('上次写于'), findsOneWidget);
    expect(find.textContaining('写到了：先写出 P(A|B)=P(AB)/P(B)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('读完条件概率'),
      160,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('下一步：阅读条件概率的定义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('事项可定位来源讨论与材料原文，预约预选对应事项', (tester) async {
    await openApp(tester);
    final data = await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '微积分讲义',
        kind: 'text',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final conversation = await scope!.chat.discussion.createConversation(
        title: '理解变化率',
        materialId: material,
        pageNo: 3,
      );
      final item = await scope!.tasks.createItem(
        title: '练习导数定义',
        conversationId: conversation,
        note: '阅读第 3 页后独立写出定义，解释差商与极限的关系',
        estMinutes: 20,
      );
      await scope!.tasks.createItem(title: '另一项任务');
      return (conversation: conversation, item: item);
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    await preview(tester, 'plan');
    await tester.tap(find.text('事项'));
    await settle(tester);
    await tester.tap(find.text('练习导数定义'));
    await settle(tester);
    await preview(tester, 'item-detail');
    await tester.tap(find.text('预约时间').last);
    await settle(tester);
    final dropdown = tester.widget<forui.FSelect<int>>(_select<int>('学习事项'));
    final selected = tester.widget<EditableText>(_selectField<int>('学习事项'));
    expect(dropdown.format(data!.item), '练习导数定义');
    expect(selected.controller.text, '练习导数定义');
    await tester.tap(find.text('取消').last);
    await settle(tester);
    await tester.tap(find.text('练习导数定义'));
    await settle(tester);
    await tester.tap(find.text('返回来源讨论'));
    await settle(tester);
    expect(
      tester.widget<DiscussionPage>(find.byType(DiscussionPage)).conversationId,
      data.conversation,
    );
    await tester.tap(find.text('查看原文'));
    await settle(tester);
    expect(find.text('导数描述函数在一点附近的变化率。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏、放大文字与键盘下核心页面没有布局溢出', (tester) async {
    await openApp(tester, size: const Size(320, 700));
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('记录').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('安排').last);
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.runAsync(
      () => scope!.tasks.createItem(title: '整理第三章笔记', estMinutes: 30),
    );
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);
    expect(find.text('这周还能做什么'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final completeButton = find.widgetWithText(forui.FButton, '完成');
    await tester.ensureVisible(completeButton);
    await tester.tap(completeButton.hitTestable());
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);
    await tester.tap(find.text('发送问题'));
    await settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习中操作条在真机宽度与放大文字下不溢出', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '求极限 lim sin3x/2x，x 趋于 0'),
    );
    await tester.tap(find.text('记录').last);
    await settle(tester);
    final record = find.widgetWithText(forui.FTile, '求极限 lim sin3x/2x，x 趋于 0');
    expect(record, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('records-answer-filter')));
    await settle(tester);
    await tester.tap(find.text('待处理'));
    await settle(tester);
    expect(record, findsNothing);
    await tester.tap(find.byKey(const ValueKey('records-answer-filter')));
    await settle(tester);
    await tester.tap(find.text('未作答'));
    await settle(tester);
    expect(record, findsOneWidget);
    await tester.tap(find.descendant(of: record, matching: find.text('继续作答')));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('提交作答'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
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

  testWidgets('作答草稿在页面里先保存再检查，提交后清空', (tester) async {
    await openApp(tester, size: const Size(390, 1200));
    final questionId = await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '写出条件概率公式'),
    );
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('继续作答'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);

    final page = find.byType(LearningPage);
    await tester.enterText(
      find.descendant(of: page, matching: _editableFields()).first,
      '先写出 P(A|B)=P(AB)/P(B)',
    );
    await tester.tap(find.text('做错了'));
    await tester.pump();
    await tester.tap(find.text('补充依据（可选）'));
    await settle(tester);
    final fields = find.descendant(of: page, matching: _editableFields());
    await tester.ensureVisible(fields.at(2));
    await tester.enterText(fields.at(2), '卡在定义');
    await tester.ensureVisible(fields.at(3));
    await tester.enterText(fields.at(3), '与标准答案一致');
    await tester.ensureVisible(find.widgetWithText(ZhixinChip, '用了应用外帮助'));
    // 选项芯片把点击从标签中心转到芯片本体，命中结果里没有标签自己的 RenderBox；
    // 点击仍然落在芯片的手势区，这里不按标签自身的命中结果报错。
    await tester.tap(
      find.widgetWithText(ZhixinChip, '用了应用外帮助'),
      warnIfMissed: false,
    );
    await tester.pump();

    // 点检查时先把整份草稿写进未提交尝试，回答再读这一份。
    await tester.ensureVisible(find.text('检查'));
    await tester.tap(find.text('检查').hitTestable());
    // 等本地检查结果或配置提示；本地兜底会顺带弹一次配置引导。
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.text('配置模型以使用学习帮助').evaluate().isNotEmpty) {
        break;
      }
      final result = find.textContaining('本地检查', findRichText: true);
      final busy = find.byType(forui.FProgress).evaluate().isNotEmpty;
      if (result.evaluate().isNotEmpty && !busy) break;
    }
    // 未配置模型时本地回答会提示配置，先留在本地继续。
    if (find.text('配置模型以使用学习帮助').evaluate().isNotEmpty) {
      await tester.tap(find.text('继续本地使用'));
    }
    await settle(tester);
    expect(find.textContaining('本地检查', findRichText: true), findsWidgets);

    final draft = (await tester.runAsync(
      () => scope!.chat.learning.view(questionId!),
    ))!.openAttempt!;
    expect(draft.userAnswer, '先写出 P(A|B)=P(AB)/P(B)');
    expect(draft.isCorrect, isFalse);
    expect(draft.independent, isFalse);
    expect(draft.hintUsed, isTrue);
    expect(draft.feedback, '卡在定义');
    expect(draft.submitted, isFalse);
    final checkables = await tester.runAsync(
      () => scope!.assessments.forAttempt(draft.id),
    );
    expect(checkables, hasLength(1));
    expect(checkables!.single.result, '与标准答案一致');

    // 提交直接使用页面上的草稿，不再经过提交弹窗；提交后编辑区清空。
    await tester.ensureVisible(find.text('提交作答'));
    await tester.tap(find.text('提交作答').hitTestable());
    await settle(tester);
    expect(find.text('记下这次作答'), findsNothing);
    final submitted = await tester.runAsync(
      () => scope!.attempts.attemptById(draft.id),
    );
    expect(submitted!.submitted, isTrue);
    expect(submitted.userAnswer, '先写出 P(A|B)=P(AB)/P(B)');
    expect(submitted.isCorrect, isFalse);
    expect(submitted.hintUsed, isTrue);
    expect(submitted.feedback, '卡在定义');
    expect(
      (await tester.runAsync(() => scope!.chat.learning.view(questionId!)))!
          .openAttempt,
      isNull,
    );
    final cleared = tester
        .widget<EditableText>(
          find.descendant(of: page, matching: _editableFields()).first,
        )
        .controller
        .text;
    expect(cleared, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复之后迟到的提示不写进恢复后的数据', (tester) async {
    final ai = _DelayedHelpAi();
    await openApp(tester, ai: ai, size: const Size(390, 1200));

    final questionId = (await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '求条件概率'),
    ))!;
    // 先在提示之前留一份整库备份，恢复之后题目与作答仍回到这一份。
    final backup = File('${directory.path}/恢复前.zip');
    await tester.runAsync(() => scope!.backupRepository(backup.path));
    final bytes = (await tester.runAsync(backup.readAsBytes))!;
    final attemptId = (await tester.runAsync(
      () => scope!.chat.learning.view(questionId),
    ))!.openAttempt!.id;

    await tester.tap(find.text('记录').last);
    await settle(tester);
    final record = find.widgetWithText(forui.FTile, '求条件概率');
    await tester.tap(find.descendant(of: record, matching: find.text('继续作答')));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);

    // 提示进入模型请求后一直等在这里，用例在等待期间整库恢复。
    await tester.tap(find.text('提示'));
    for (var i = 0; i < 80 && !ai.entered.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(ai.entered.isCompleted, isTrue);

    await tester.runAsync(() => scope!.restore(bytes));
    ai.resume.complete();
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.textContaining('获取帮助没有完成').evaluate().isNotEmpty) break;
    }

    // 迟到的回答留在页面之外，恢复后的作答仍没有帮助记录。
    expect(find.textContaining('获取帮助没有完成'), findsOneWidget);
    expect(find.text('恢复之后才回来的提示'), findsNothing);
    // 读库加超时：以后这条路径再出问题时应报失败，而不是把整条用例挂住。
    final attempt = await tester.runAsync(
      () => scope!.attempts
          .attemptById(attemptId)
          .timeout(const Duration(seconds: 10)),
    );
    expect(attempt!.helps, isEmpty);
    expect(tester.takeException(), isNull);
    // 整库恢复后首页与三栏在后台重读，等这些读取结束再关库，避免关库等读锁。
    await settle(tester);
  });

  testWidgets('连续点开始作答只建立一份草稿', (tester) async {
    await openApp(tester);
    final id = (await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '第 8 题求条件概率');
      return result.userMessage.conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    final button = find.text('开始作答');
    await tester.tap(button);
    await tester.tap(button);
    await settle(tester);

    expect(find.byType(LearningPage), findsOneWidget);
    final attempts = await tester.runAsync(
      () => scope!.attempts.attemptsFor(id),
    );
    expect(attempts, hasLength(1));
    expect(attempts!.single.submitted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录页显示最近一次作答与模型判断', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '记录摘要');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '设 P(A|B)=P(AB)/P(B)',
        isCorrect: true,
        independent: true,
      );
      await scope!.assessments.add(
        attemptId: attempt.id,
        kind: AssessmentKind.model,
        result: '步骤完整，结论正确',
        basis: '对照材料第 2 页',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await preview(tester, 'records');

    expect(find.textContaining('作答：设 P(A|B)'), findsOneWidget);
    expect(find.textContaining('自评：独立完成'), findsOneWidget);
    expect(find.textContaining('判断：步骤完整'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学习页把最近讨论与作答放在同一条记录里', (tester) async {
    await openApp(tester);
    final id = (await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '讨论里的条件概率');
      return result.userMessage.conversationId;
    }))!;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LearningPage(questionId: id)),
    );
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('同一条记录里的讨论'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('同一条记录里的讨论'), findsOneWidget);
    expect(find.textContaining('你：讨论里的条件概率'), findsOneWidget);
    expect(find.textContaining('搭子：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录默认打开学习页，复查入口直接进入独立重做', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final id = await scope!.chat.learning.capture(stem: '记录复查题目');
      final attempt = await scope!.chat.learning.openAttempt(id);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '上次写下的答案',
        isCorrect: true,
        independent: true,
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('记录复查题目').first);
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('作答草稿'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    await tester.tap(find.text('复查（先不看上次）'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('独立重做：'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('独立重做：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录里可以清空一条记录，消息与作答一起删除', (tester) async {
    await openApp(tester);
    await tester.runAsync(() => scope!.chat.learning.capture(stem: '保留的题目'));
    final deletedImage = (await tester.runAsync(() async {
      final file = File('${scope!.paths.imagesDir}/deleted-record.jpg');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      return file;
    }))!;
    final conversationId = (await tester.runAsync(
      () => scope!.chat.discussion.createConversation(title: '要清空的记录'),
    ))!;
    await tester.runAsync(() async {
      await scope!.conversations.append(
        conversationId,
        role: 'user',
        content: '这条记录会被清空',
        imagePaths: ['deleted-record.jpg'],
      );
      await scope!.attempts.ensureOpenAttempt(conversationId);
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    expect(find.text('要清空的记录'), findsOneWidget);

    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    await tester.tap(find.text('清空记录'));
    await settle(tester);
    await tester.tap(find.text('清空'));
    await settle(tester);

    expect(find.text('要清空的记录'), findsNothing);
    expect(await tester.runAsync(deletedImage.exists), isFalse);
    final conversations = await tester.runAsync(
      () => scope!.chat.discussion.records(),
    );
    expect(
      conversations!.any((record) => record.id == conversationId),
      isFalse,
    );
    expect(
      await tester.runAsync(() => scope!.attempts.attemptsFor(conversationId)),
      isEmpty,
    );
    final rows = await tester.runAsync(
      () => scope!.conversations.questionRows(),
    );
    expect(rows!.single.question.stem, '保留的题目');
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表可以删除', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.study.plan.addTimetable(
        weekday: 3,
        startTime: '08:00',
        endTime: '09:00',
        title: '数据结构',
      ),
    );
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.scrollUntilVisible(
      find.byIcon(FLucideIcons.trash2),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // 底部导航栏盖住列表末端，再往上拖一段，删除按钮才落在可点击的区域内。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.trash2));
    await settle(tester);
    expect(find.text('删除这节课'), findsOneWidget);
    await tester.tap(find.widgetWithText(forui.FButton, '删除'));
    await settle(tester);

    expect(find.text('数据结构'), findsNothing);
    expect(await tester.runAsync(() => scope!.schedule.timetable()), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算沿用已保存的可用时段', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.study.capacity.setWindow(start: '19:00', end: '19:30'),
    );
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);
    expect(find.text('常用学习时段：19:00–19:30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算点选算出的空档直接预约', (tester) async {
    await openApp(tester);
    final itemId = await tester.runAsync(() async {
      await scope!.study.capacity.setWindow(start: '19:00', end: '19:30');
      return scope!.tasks.createItem(title: '整理笔记', estMinutes: 20);
    });
    final window = await tester.runAsync(() async {
      final plan = await scope!.study.capacity.compute();
      return plan.candidates.single.windows.first;
    });
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);

    final label =
        '${dayLabel(window!.start)} '
        '${clockOf(window.start)}–${clockOf(window.end)}';
    expect(find.text(label), findsOneWidget);
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);

    // 写入之前先说明这次会新建预约到什么时间。
    expect(find.text('按这个空档预约'), findsOneWidget);
    expect(find.textContaining('新建预约：'), findsOneWidget);
    expect(find.textContaining('这次只调整这一项'), findsOneWidget);
    await tester.tap(find.text('按这个时间预约'));
    await settle(tester);

    final blocks = await tester.runAsync(
      () => scope!.schedule.blocksForItem(itemId!),
    );
    expect(blocks, hasLength(1));
    expect(blocks!.single.startAt, window.start);
    expect(blocks.single.endAt, window.end);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间预算点选空档前说明原预约会改到的时间', (tester) async {
    await openApp(tester);
    final itemId = await tester.runAsync(() async {
      await scope!.study.capacity.setWindow(start: '19:00', end: '19:30');
      final id = await scope!.tasks.createItem(title: '整理笔记', estMinutes: 20);
      final day = DateTime.now().add(const Duration(days: 1));
      await scope!.schedule.addBlock(
        planItemId: id,
        start: DateTime(day.year, day.month, day.day, 18),
        end: DateTime(day.year, day.month, day.day, 18, 20),
      );
      return id;
    });
    final window = await tester.runAsync(() async {
      final plan = await scope!.study.capacity.compute();
      return plan.candidates.single.windows.first;
    });
    await tester.tap(find.text('安排').last.hitTestable());
    await settle(tester);
    await tester.tap(find.text('这周能做什么'));
    await settle(tester);

    expect(find.text('这次估算会把以下弹性预约算作可调整'), findsOneWidget);
    expect(find.text('没有点选的预约保持原时间。'), findsOneWidget);

    final label =
        '${dayLabel(window!.start)} '
        '${clockOf(window.start)}–${clockOf(window.end)}';
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);

    expect(find.textContaining('原预约：'), findsOneWidget);
    expect(find.textContaining('改到：'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);

    final blocks = await tester.runAsync(
      () => scope!.schedule.blocksForItem(itemId!),
    );
    expect(blocks, hasLength(1));
    expect(blocks!.single.startAt.hour, 18);
    expect(blocks.single.endAt.hour, 18);

    // 再选一次，保留原预约并追加一段。
    await tester.tap(find.text(label).hitTestable());
    await settle(tester);
    expect(find.text('再加一段'), findsOneWidget);
    await tester.tap(find.text('再加一段'));
    await settle(tester);
    final two = await tester.runAsync(
      () => scope!.schedule.blocksForItem(itemId!),
    );
    expect(two, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统学习设置框在真机宽度下不溢出', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: 'text',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率的定义。',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 2,
        content: '全概率公式。',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.text('概率论讲义'));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.route));
    await settle(tester);
    expect(find.textContaining('系统学习《概率论讲义》'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统学习确认前标明顺序来源', (tester) async {
    await openApp(tester, size: const Size(390, 844));
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: 'text',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率的定义。',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 2,
        content: '全概率公式。',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.text('概率论讲义'));
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.route));
    await settle(tester);
    await tester.tap(find.text('生成顺序'));
    await settle(tester);
    expect(find.textContaining('来源：按页顺序'), findsOneWidget);
    expect(find.textContaining('覆盖本次所选 2 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加一页遇到已有页码时不覆盖，提示到详情更正', (tester) async {
    await openApp(tester);
    final materialId = await tester.runAsync(() async {
      final id = await scope!.library.material.create(title: '概率论讲义');
      await scope!.library.material.addPage(
        materialId: id,
        pageNo: 1,
        content: '已经校对过的原文',
      );
      return id;
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.filePlus));
    await settle(tester);

    final fields = find.descendant(
      of: find.byType(forui.FDialog),
      matching: _editableFields(),
    );
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '1');
    await tester.enterText(fields.at(2), '后来粘贴的原文');
    await tester.tap(find.text('保存').last);
    await settle(tester);
    expect(find.textContaining('第 1 页已有原文'), findsOneWidget);

    await tester.tap(find.text('取消').last);
    await settle(tester);
    final pages = await tester.runAsync(
      () => scope!.library.material.pages(materialId!),
    );
    expect(pages!.single.content, '已经校对过的原文');
    expect(tester.takeException(), isNull);
  });

  testWidgets('过期记忆单独标出且不参与回答上下文', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.memory.edit.add(
        kind: MemoryKind.constraint,
        content: '本周只有半小时可用于复习',
        validUntil: DateTime.now().subtract(const Duration(days: 1)),
      ),
    );
    await tester.tap(find.byIcon(FLucideIcons.brain));
    await settle(tester);
    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('本周只有半小时可用于复习'), findsOneWidget);
    final memories = await tester.runAsync(
      () async => (await scope!.chat.context.load()).memories,
    );
    expect(
      memories!.any((memory) => memory.content == '本周只有半小时可用于复习'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页只推荐有效安排，并恢复系统学习的原位置', (tester) async {
    await openApp(tester);
    final planId = await tester.runAsync(() async {
      final goal = await scope!.tasks.createGoal(title: '高等数学 · 导数与微分');
      final material = await scope!.library.material.create(
        title: '微积分学习讲义',
        kind: 'text',
        goalId: goal,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数与变化率',
      );
      final conversation = await scope!.chat.discussion.createConversation(
        title: '如何理解导数的几何意义',
        materialId: material,
        pageNo: 3,
        goalId: goal,
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        title: '理解导数的定义',
        steps: const [
          StudyStepDraft(title: '从变化率理解导数', pageFrom: 3, pageTo: 3),
        ],
      );
      final now = scope!.timePolicy.now;
      // 三条安排都放在今天且不跨零点；只有最后一条仍在进行。
      final base = now.subtract(const Duration(minutes: 1));
      final states = ['done', 'cancelled', 'valid'];
      for (var index = 0; index < states.length; index++) {
        final state = states[index];
        final item = await scope!.tasks.createItem(
          title: state == 'valid' ? '独立推导一次差商极限' : '已结束的安排',
          goalId: goal,
          conversationId: conversation,
          note: '说明极限存在的条件',
          estMinutes: 20,
        );
        final start = base.subtract(Duration(minutes: (2 - index) * 30));
        final block = await scope!.schedule.addBlock(
          planItemId: item,
          start: start,
          end: start.add(const Duration(minutes: 20)),
        );
        if (state == 'done') {
          await scope!.study.plan.setStatus(item, PlanItemStatus.done);
        }
        if (state == 'cancelled') {
          await scope!.schedule.setBlockStatus(block, 'cancelled');
        }
      }
      final activity = await scope!.chat.context.loadActivity();
      expect(activity.ongoing!.item.title, '独立推导一次差商极限');
      final week = scope!.timePolicy.naturalWeekRange(now);
      // 这一步的安排只用来验证安排列表与跳转，时刻固定成本周某一天的 08:00。
      // 选离“现在”最远的那一天，是因为上面三条安排围着 now，按 now 前后 20 分钟
      // 检查时间段：放在本周第一天（通常是周一）时，UTC 的 CI 恰好在周一 08:00
      // 前后跑测试就会撞上那三条，报时间段冲突。
      final firstMorning = week.start.add(const Duration(hours: 8));
      final lastMorning = week.start.add(const Duration(days: 6, hours: 8));
      final scheduledAt =
          firstMorning.difference(now).abs() >=
              lastMorning.difference(now).abs()
          ? firstMorning
          : lastMorning;
      await scope!.schedule.addBlock(
        planItemId: plan.steps.single.id,
        start: scheduledAt,
        end: scheduledAt.add(const Duration(minutes: 20)),
      );
      return plan.plan.id;
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    final initialPlanList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      120,
      scrollable: initialPlanList,
    );
    await preview(tester, 'plan-populated');
    expect(find.text('理解导数的定义'), findsOneWidget);
    expect(find.textContaining('下一步：从变化率理解导数'), findsOneWidget);
    final scheduledStep = find.text('从变化率理解导数');
    final planList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(scheduledStep, -120, scrollable: planList);
    // 已预约的学习步骤写出所属计划，开始与结束时刻在左侧上下排列。
    final scheduledTile = find.ancestor(
      of: scheduledStep,
      matching: find.byType(forui.FTile),
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('所属计划：理解导数的定义')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('08:00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('08:20')),
      findsOneWidget,
    );
    await tester.tap(scheduledStep.hitTestable());
    await settle(tester);
    await tester.tap(find.text('打开学习计划').hitTestable());
    await settle(tester);
    expect(find.byType(StudyPlanPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);
    await preview(tester, 'now-populated');
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      160,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('理解导数的定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    expect(find.text('从变化率理解导数'), findsOneWidget);
    final view = await tester.runAsync(
      () => scope!.study.systemPlan.view(planId!),
    );
    expect(view!.plan.currentPage, 3);
    expect(tester.takeException(), isNull);
    await preview(tester, 'study-plan');
  });

  testWidgets('贴一道题只发图片时可以先存讨论，文字才带出处', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('贴一道题'));
    await settle(tester);

    final dialog = find.byType(forui.FDialog);
    expect(dialog, findsOneWidget);
    // 没有文字也没有图片时不能保存；只有图片时也不显示出处与摘录。
    final empty = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '保存'),
    );
    expect(empty.onPress, isNull);
    expect(find.text('出处（可选）'), findsNothing);

    await tester.enterText(
      find.descendant(of: dialog, matching: _editableFields()).first,
      '求条件概率',
    );
    await settle(tester);
    expect(find.text('出处（可选）'), findsOneWidget);
    final filled = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '保存'),
    );
    expect(filled.onPress, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('接受下一步建议时可以直接选定时间', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.conversations.create(title: '再练一次');
      await scope!.conversations.append(
        conversation,
        role: 'user',
        content: '第 8 题又做错了，怎么办',
      );
      await scope!.conversations.append(
        conversation,
        role: 'assistant',
        content: '先收下这条安排，再自己独立做一遍。',
        structured: {
          'next_steps': [
            {'title': '再独立做一遍第 8 题', 'action': '合上笔记重新做一遍。', 'minutes': 10},
          ],
        },
      );
      return conversation;
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    await tester.ensureVisible(find.text('保存并选时间'));
    await tester.tap(find.text('保存并选时间').hitTestable());
    await settle(tester);
    await tester.tap(find.text('单独记录').hitTestable());
    await settle(tester);
    expect(find.text('预约学习时间'), findsOneWidget);
    await tester.tap(find.widgetWithText(forui.FButton, '预约').hitTestable());
    await settle(tester);

    final stored = await tester.runAsync(() async {
      final items = await scope!.tasks.items();
      final blocks = await scope!.schedule.blocksForItem(items.single.id);
      return (items: items, blocks: blocks);
    });
    expect(stored!.items.single.title, '再独立做一遍第 8 题');
    expect(stored.blocks, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页把正在进行的预约直接打开到材料页', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '导数讲义',
        kind: 'text',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        title: '导数练习计划',
        steps: const [StudyStepDraft(title: '理解导数的定义', pageFrom: 3, pageTo: 3)],
      );
      final now = scope!.timePolicy.now;
      final dayStart = scope!.timePolicy.naturalDate(now);
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 5));
      final start = fiveMinutesAgo.isBefore(dayStart)
          ? dayStart
          : fiveMinutesAgo;
      await scope!.schedule.addBlock(
        planItemId: plan.steps.single.id,
        start: start,
        end: start.add(const Duration(minutes: 20)),
      );
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('正在进行'), findsOneWidget);
    expect(find.textContaining('正在进行 · '), findsOneWidget);
    await tester.tap(find.text('开始学习'));
    await settle(tester);
    expect(find.byType(MaterialDetailPage), findsOneWidget);
    expect(find.textContaining('本次范围：第 3 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页把没有预约的待办放在接下来', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.tasks.createItem(title: '整理错题', estMinutes: 25);
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('待开始 · 约 25 分钟'), findsOneWidget);
    expect(find.text('整理错题'), findsOneWidget);
    expect(find.text('查看事项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页按记录去重，有草稿的题目只出现一次并直达作答', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.chat.learning.capture(stem: '首页去重题目');
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('首页去重题目'), findsOneWidget);
    await tester.tap(find.text('首页去重题目'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预约可以直接打开这一步的材料，结束预约不推进计划', (tester) async {
    await openApp(tester);
    final data = await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '导数讲义',
        kind: 'text',
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        steps: const [StudyStepDraft(title: '理解导数的定义', pageFrom: 3, pageTo: 3)],
      );
      final step = plan.steps.single;
      final start = scope!.timePolicy.now.subtract(const Duration(minutes: 5));
      final block = await scope!.schedule.addBlock(
        planItemId: step.id,
        start: start,
        end: start.add(const Duration(minutes: 20)),
      );
      return (stepId: step.id, blockId: block, planId: plan.plan.id);
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    final planList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      120,
      scrollable: planList,
    );
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    await tester.tap(find.text('学这一步').hitTestable());
    await settle(tester);
    expect(find.byType(MaterialDetailPage), findsOneWidget);
    expect(find.textContaining('本次范围：第 3 页'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.textContaining('最近预约：'), findsOneWidget);

    await tester.ensureVisible(find.text('理解导数的定义').hitTestable());
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    await tester.tap(find.text('结束本次预约').hitTestable());
    await settle(tester);
    await tester.tap(
      find.widgetWithText(forui.FButton, '结束本次预约').hitTestable(),
    );
    await settle(tester);

    final after = await tester.runAsync(() async {
      return (
        step: await scope!.tasks.byId(data!.stepId),
        block: await scope!.schedule.blockById(data.blockId),
        plan: await scope!.study.systemPlan.view(data.planId),
      );
    });
    expect(after!.step!.status, PlanItemStatus.doing);
    expect(after.block!.status, 'done');
    expect(after.plan.plan.stepsDone, 0);
    // 结束预约后安排页会再读一次周日程；等这次读取收尾再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('讨论里可以开始作答，题目沿用首条内容', (tester) async {
    await openApp(tester);
    final conversationId = await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '第 8 题求条件概率');
      return result.userMessage.conversationId;
    });
    final id = conversationId!;

    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('第 8 题求条件概率').first);
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('开始作答'), findsOneWidget);

    await tester.tap(find.text('开始作答'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('第 8 题求条件概率'), findsOneWidget);

    final view = await tester.runAsync(() => scope!.chat.learning.view(id));
    expect(view!.question.conversationId, id);
    expect(view.question.stem, '第 8 题求条件概率');
    expect(view.attempts.single.helps, isEmpty);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('继续作答'), findsOneWidget);
    final sessions = await tester.runAsync(() => scope!.studyRecords.recent());
    expect(sessions!.single.endedAt, isNotNull);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.widgetWithText(forui.FTile, '第 8 题求条件概率'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('records-search-entry')));
    await settle(tester);
    await tester.enterText(_editableFields(), '条件概率');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(find.widgetWithText(forui.FTile, '第 8 题求条件概率'), findsOneWidget);
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
    await tester.tap(find.byIcon(FLucideIcons.settings));
    await settle(tester);
    expect(find.text('外观'), findsOneWidget);

    await tester.tap(_selectField<ThemeMode>('深浅色'));
    await settle(tester);
    await tester.tap(find.text('深色').last);
    await settle(tester);
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.dark,
    );

    await tester.tap(_selectField<ThemeMode>('深浅色'));
    await settle(tester);
    await tester.tap(find.text('浅色').last);
    await settle(tester);
    expect(
      Theme.of(tester.element(find.byType(SettingsPage))).brightness,
      Brightness.light,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页列出提交历史、留存与两类数据包入口', (tester) async {
    await openApp(tester);
    await tester.runAsync(() => scope!.tasks.createGoal(title: '版本页目标'));
    await tester.tap(find.byIcon(FLucideIcons.settings));
    await settle(tester);
    final dataTile = find.text('数据版本');
    await tester.scrollUntilVisible(
      dataTile,
      260,
      scrollable: _settingsScrollable(),
    );
    await tester.ensureVisible(dataTile);
    await tester.pumpAndSettle();
    await tester.tap(dataTile);
    await settle(tester);
    expect(find.byType(DataVersionPage), findsOneWidget);
    expect(find.text('命名当前版本'), findsOneWidget);
    expect(find.text('导出当前数据'), findsOneWidget);
    expect(find.text('备份版本库'), findsOneWidget);
    expect(find.text('提交历史'), findsOneWidget);
    expect(find.textContaining('条保留提交'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页列出恢复点并标明可以回到恢复前', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.tasks.createGoal(title: '恢复点目标');
      final backup = File('${directory.path}/restore.zip');
      await scope!.backupRepository(backup.path);
      await scope!.restore(await backup.readAsBytes());
    });
    await tester.tap(find.byIcon(FLucideIcons.settings));
    await settle(tester);
    final dataTile = find.text('数据版本');
    await tester.scrollUntilVisible(
      dataTile,
      260,
      scrollable: _settingsScrollable(),
    );
    await tester.ensureVisible(dataTile);
    await tester.pumpAndSettle();
    await tester.tap(dataTile);
    await settle(tester);

    final section = find.text('恢复点');
    await tester.scrollUntilVisible(
      section,
      200,
      scrollable: find
          .descendant(
            of: find.byType(DataVersionPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(section, findsOneWidget);
    expect(find.textContaining('整库恢复前自动保存'), findsOneWidget);
    expect(find.textContaining('最多保留最近 5 份'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页直接禁用不能撤销的提交并说明原因', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.db.insert('conversation', {
        'title': '不能撤销的讨论',
        'entry_kind': 'text',
        'status': 'open',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
    );
    await tester.tap(find.byIcon(FLucideIcons.settings));
    await settle(tester);
    final dataTile = find.text('数据版本');
    await tester.scrollUntilVisible(
      dataTile,
      260,
      scrollable: _settingsScrollable(),
    );
    await tester.ensureVisible(dataTile);
    await tester.pumpAndSettle();
    await tester.tap(dataTile);
    await settle(tester);

    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    final items = tester.widgetList<forui.FTile>(
      find.ancestor(
        of: find.text('撤销这次操作'),
        matching: find.byType(forui.FTile),
      ),
    );
    expect(items.any((item) => item.enabled == false), isTrue);
    expect(find.text('“conversation”的改动暂不支持单项撤销'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截止时间保存后立即生效，撤销后设置与时间口径一起刷新', (tester) async {
    await openApp(tester);
    await tester.tap(find.byIcon(FLucideIcons.settings));
    await settle(tester);
    final cutoffField = _selectField<int>('每天的截止时间');
    await tester.scrollUntilVisible(
      cutoffField,
      260,
      scrollable: _settingsScrollable(),
    );
    expect(scope!.cutoffHour, 4);

    await tester.tap(cutoffField);
    await settle(tester);
    await tester.tap(find.text('0 点').last);
    await settle(tester);
    expect(scope!.cutoffHour, 0);

    final head = await tester.runAsync(() => scope!.currentHead());
    final result = await tester.runAsync(
      () => scope!.data.revisions.undoCommit(head!),
    );
    expect(result!.applied, isTrue, reason: result.message);
    await settle(tester);
    expect(scope!.cutoffHour, 4);
    expect(tester.widget<EditableText>(cutoffField).controller.text, '4 点');
    expect(tester.takeException(), isNull);
  });
}
