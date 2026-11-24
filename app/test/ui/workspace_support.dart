import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/copy.dart';
import 'package:zhixin/ui/mine_page.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/zhixin_icon_button.dart';

import 'package:zhixin/domain/models/result.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

Finder editableFields() => find.byWidgetPredicate(
  (widget) => widget is EditableText && !widget.readOnly,
);

/// FSelect.rich 返回的是私有子类，按类型取不到，只能按祖先判断。
Finder select<T>(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is forui.FSelect<T>),
);

Finder selectField<T>(String label) =>
    find.descendant(of: select<T>(label), matching: find.byType(EditableText));

/// 讨论页顶行的“更多讨论操作”菜单触发器；菜单项要点开之后才在树里。
Finder discussionMoreMenu() => find.byWidgetPredicate(
  (widget) => widget is ZhixinIconButton && widget.tooltip == '更多讨论操作',
);

/// 设置页自身的滚动区域。下拉框和输入框内部也有 Scrollable，
/// 直接取 Scrollable 会拿到输入框里面那个横向的。
Finder settingsScrollable() => find
    .descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 进入应用之后才回答的模型替身：用例在恢复数据之后才让它返回，
/// 用来走“等待回答期间发生了恢复”的页面路径。
class DelayedHelpAi implements BuddyAi {
  final Completer<void> entered = Completer<void>();
  final Completer<void> resume = Completer<void>();

  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

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

late Directory directory;
AppScopeState? scope;
final previewKey = GlobalKey();

/// 每个用例文件在 main 开头调用一次：绑定、致命点击检查与共享装配的收尾。
void registerWorkspaceTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-ui-');
    await disableTelemetryForTests(directory.path);
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
    await closeAppScope(scope, directory);
    scope = null;
  });
}

/// FToast 的自动收起靠定时器；在测试里推进到它收起，避免用例结束时留下未触发的计时器。
Future<void> clearToasts(WidgetTester tester) async {
  if (find.byType(forui.FToaster).evaluate().isEmpty) return;
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 推进到应用把读取、生成与提示都放完，界面停在稳定状态。
///
/// 先按应用自己的访问队列推进若干帧，再等生成中的回答结束；真实等待只在读取
/// 还没放完时出现，不再按固定时长反复等。
Future<void> settle(WidgetTester tester) async {
  final gate = scope!.testing.gate;
  // 每轮推进一帧的时间：界面据此发起读取、收起过渡动画，防抖与提示的定时器也在
  // 假时间里到期。真实等待只用来让读取走完，队列空着时很短。
  await settleFrames(tester, scope);
  for (var i = 0; i < 200; i++) {
    // 发送按钮生成中只显示停止图标，不再有转圈，按停止按钮判断仍在请求。
    final busy =
        find.byType(forui.FCircularProgress).evaluate().isNotEmpty ||
        find.byIcon(FLucideIcons.square).evaluate().isNotEmpty;
    if (!busy) break;
    await tester.pump(const Duration(milliseconds: 20));
    await advanceAsync(tester, gate, const Duration(milliseconds: 20));
  }
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
  Clock? clock,
  ServerClient Function(String baseUrl)? serverClientFactory,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: ZhixinApp(
          ai: ai,
          clock: clock,
          serverClientFactory: serverClientFactory,
        ),
      ),
    );
    scope = tester.state<AppScopeState>(find.byType(AppScope));
    await scope!.ready;
  });
  await settle(tester);
}

/// 从底栏“我的”打开一个次级入口：先切栏，再滚到这一行点开。
Future<void> openMineEntry(WidgetTester tester, String title) async {
  await tester.tap(
    find.descendant(
      of: find.byType(forui.FBottomNavigationBar),
      matching: find.text(tabMine),
    ),
  );
  await settle(tester);
  final entry = find.descendant(
    of: find.byType(MinePage),
    matching: find.widgetWithText(forui.FTile, title),
  );
  await tester.scrollUntilVisible(
    entry,
    200,
    scrollable: find
        .descendant(
          of: find.byType(MinePage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await settle(tester);
}

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
