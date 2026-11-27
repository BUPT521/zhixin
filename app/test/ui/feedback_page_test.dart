import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/feedback_service.dart';
import 'package:zhixin/domain/models/server_models.dart';
import 'package:zhixin/platform/app_info.dart';
import 'package:zhixin/ui/feedback_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';

/// 反馈表单：必填、邮箱格式、成功回执、限流与网络失败；不要求登录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-feedback-page-');
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

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 100,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  Future<void> pumpPage(WidgetTester tester, FeedbackSubmitter submit) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: zhixinTheme,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            forui.FLocalizations.delegate,
          ],
          builder: (context, child) => forui.FTheme(
            data: zhixinForuiTheme,
            child: forui.FToaster(
              child: AppScope(
                themeAccent: ThemeAccentController(),
                themeMode: ThemeModeController(),
                child: child!,
              ),
            ),
          ),
          home: FeedbackPage(submit: submit),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await tester.pump();
  }

  Finder contentField() => find.byType(EditableText).first;

  Finder contactField() => find.byType(EditableText).at(1);

  String fieldText(WidgetTester tester, Finder finder) =>
      tester.widget<EditableText>(finder).controller.text;

  Future<void> fill(
    WidgetTester tester, {
    String? content,
    String? contact,
  }) async {
    if (content != null) await tester.enterText(contentField(), content);
    if (contact != null) await tester.enterText(contactField(), contact);
    await tester.pump();
  }

  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('提交反馈'));
    await tester.pump();
    await tester.tap(find.text('提交反馈'));
    await tester.pump();
  }

  testWidgets('正文必填，联系邮箱要做格式校验', (tester) async {
    await pumpPage(
      tester,
      (draft) async => ServerFeedbackReceipt(id: 'feedback-1'),
    );
    await waitFor(tester, find.text('提交反馈'));

    await tapSubmit(tester);
    expect(find.text('请先写反馈内容'), findsOneWidget);

    await fill(tester, content: '在记录页按下一步没有反应', contact: 'not-an-email');
    await tapSubmit(tester);
    await tester.pump();
    expect(find.text('联系邮箱格式不正确，请检查或留空'), findsOneWidget);

    // 清掉不合法的邮箱之后就通过本地校验，交给提交实现。
    await fill(tester, contact: '');
    await tapSubmit(tester);
    await waitFor(tester, find.text('反馈已提交'));
    expect(find.text('联系邮箱格式不正确，请检查或留空'), findsNothing);
  });

  testWidgets('提交成功后显示回执编号与时间，并自动带上版本与平台', (tester) async {
    FeedbackDraft? submitted;
    await pumpPage(tester, (draft) async {
      submitted = draft;
      return ServerFeedbackReceipt(
        id: 'feedback-9',
        createdAt: DateTime(2026, 11, 18, 10, 30),
      );
    });
    await waitFor(tester, find.text('提交反馈'));

    await fill(
      tester,
      content: '  在记录页按“下一步”没有反应  ',
      contact: 'me@example.com',
    );
    await tapSubmit(tester);
    await waitFor(tester, find.text('反馈已提交'));

    expect(find.text('回执编号：feedback-9'), findsOneWidget);
    expect(find.text('提交时间：2026-11-18 10:30:00'), findsOneWidget);
    expect(submitted, isNotNull);
    expect(submitted!.content, '在记录页按“下一步”没有反应');
    expect(submitted!.contact, 'me@example.com');
    expect(submitted!.appVersion, appVersion);
    expect(submitted!.platform, 'android');
    expect(submitted!.diagnostics, isEmpty);
    // 提交成功之后清空输入，回执留在页面上。
    expect(fieldText(tester, contentField()), isEmpty);
  });

  testWidgets('限流时提示稍后再试，并保留已经填写的内容', (tester) async {
    await pumpPage(
      tester,
      (draft) async => throw const ServerProblem(
        code: 'rate_limited',
        status: 429,
        retryAfterSeconds: 30,
      ),
    );
    await waitFor(tester, find.text('提交反馈'));

    await fill(tester, content: '提交太快也要保住内容');
    await tapSubmit(tester);
    await waitFor(tester, find.textContaining('请 30 秒后再试'));

    expect(find.textContaining('已经填写的内容还在'), findsOneWidget);
    expect(fieldText(tester, contentField()), '提交太快也要保住内容');
    // 限流不给重试按钮：等一会儿再提交，避免连续请求继续被拒绝。
    expect(find.widgetWithText(forui.FButton, '重试'), findsNothing);
  });

  testWidgets('网络失败保留输入并给重试，重试成功后显示回执', (tester) async {
    var attempts = 0;
    await pumpPage(tester, (draft) async {
      attempts++;
      if (attempts == 1) throw const ServerProblem.offline('测试断网');
      return ServerFeedbackReceipt(
        id: 'feedback-10',
        createdAt: DateTime(2026, 11, 18, 11),
      );
    });
    await waitFor(tester, find.text('提交反馈'));

    await fill(tester, content: '断网时也不丢内容');
    await tapSubmit(tester);
    await waitFor(tester, find.textContaining('无法连接服务端'));

    expect(find.textContaining('已经填写的内容还在'), findsOneWidget);
    expect(fieldText(tester, contentField()), '断网时也不丢内容');

    await tester.tap(find.widgetWithText(forui.FButton, '重试'));
    await waitFor(tester, find.text('反馈已提交'));
    expect(attempts, 2);
    expect(find.text('回执编号：feedback-10'), findsOneWidget);
  });

  testWidgets('附带诊断摘要时先展示要提交的片段', (tester) async {
    FeedbackDraft? submitted;
    await pumpPage(tester, (draft) async {
      submitted = draft;
      return ServerFeedbackReceipt(id: 'feedback-11');
    });
    await waitFor(tester, find.text('提交反馈'));

    await fill(tester, content: '带上本机诊断');
    await tester.tap(find.text('附带本机诊断摘要'));
    await tester.pump();
    expect(find.textContaining('启动次数：'), findsOneWidget);
    expect(find.textContaining('本机诊断里没有记录到错误。'), findsOneWidget);

    await tapSubmit(tester);
    await waitFor(tester, find.text('反馈已提交'));
    expect(submitted!.diagnostics, contains('启动次数：'));
    expect(submitted!.diagnostics, isNot(contains('stack')));
  });
}
