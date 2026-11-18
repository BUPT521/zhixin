import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/plugins/persona/persona_catalog.dart';
import 'package:zhixin/plugins/runtime/plugin_runtime.dart';
import 'package:zhixin/ui/copy.dart';
import 'package:zhixin/ui/embedding_settings_page.dart';
import 'package:zhixin/ui/mine_page.dart';
import 'package:zhixin/ui/persona_page.dart';
import 'package:zhixin/ui/plugins_page.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';

/// 设置页、“我的”页的入口，以及插件与人格的列表、启停与切换写进 app_meta。
///
/// 直接装配页面与 [AppScope]，不从首页推进导航：这两页的验收点是列表、文案与
/// 启停结果，导航动画与首页加载另有用例覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-plugins-page-');
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
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  Future<String?> readMeta(WidgetTester tester, String key) async {
    String? value;
    await tester.runAsync(() async {
      value = await scope!.testing.db.selectGenerated(
        (db) => db.appMetaValue(key).getSingleOrNull(),
      );
    });
    return value;
  }

  Future<void> waitForMeta(
    WidgetTester tester,
    String key,
    String? expected,
  ) async {
    for (var round = 0; round < 100; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (await readMeta(tester, key) == expected) return;
    }
    fail('等待 app_meta $key 变成 $expected 超时');
  }

  /// 只装应用根与一个页面，等首读完成；页面里的列表与开关照常工作。
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
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
              child: AppScope(themeMode: ThemeModeController(), child: child!),
            ),
          ),
          home: page,
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
  }

  testWidgets('设置页显示语义索引入口，危险操作在页底', (tester) async {
    await pumpPage(tester, const SettingsPage());
    // 先等首读骨架换成内容，再核对入口；只看标题栏会在骨架阶段就返回。
    await waitFor(tester, find.text('语义索引'));
    expect(find.byType(SettingsPage), findsOneWidget);

    // 搜索页提示“可以在设置里更新”，入口就在模型段之后；没有配置时写“未启用”。
    expect(find.widgetWithText(forui.FTile, '语义索引'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);

    // 账号、插件与人格都移到了“我的”，设置页只留偏好配置。
    expect(find.text('账号与云同步'), findsNothing);
    expect(find.widgetWithText(forui.FTile, pluginsPageTitle), findsNothing);
    expect(find.widgetWithText(forui.FTile, personaPageTitle), findsNothing);

    // 设置页比手机屏长，危险的模型配置删除与清空单独成段，在页底。
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var step = 0; step < 10; step++) {
      if (find.widgetWithText(forui.FTile, '删除模型配置').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.widgetWithText(forui.FTile, '删除模型配置'), findsOneWidget);
    expect(find.text('危险操作'), findsOneWidget);

    for (var step = 0; step < 10; step++) {
      if (find.widgetWithText(forui.FTile, '清空全部记录').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.widgetWithText(forui.FTile, '清空全部记录'), findsOneWidget);
  });

  testWidgets('我的页未登录时给登录入口，并列出数据、学习与通用入口', (tester) async {
    final active = ValueNotifier<int>(3);
    addTearDown(active.dispose);
    await pumpPage(tester, MinePage(activeTab: active));
    await waitFor(tester, find.text('登录或注册'));

    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('学习记录只保存在这台设备'), findsOneWidget);
    // 未登录时不显示云端备份；同步按钮只在登录之后出现。
    expect(find.widgetWithText(forui.FTile, '云端备份'), findsNothing);
    expect(find.text('立即同步'), findsNothing);

    for (final title in [
      '数据版本',
      '学习记忆',
      personaPageTitle,
      pluginsPageTitle,
      '设置',
      '关于',
    ]) {
      expect(
        find.widgetWithText(forui.FTile, title),
        findsOneWidget,
        reason: '我的页缺少入口：$title',
      );
    }
    expect(find.text(pluginsEntrySubtitle), findsOneWidget);
    expect(find.text(personaEntrySubtitle), findsOneWidget);

    await tester.tap(find.text('登录或注册'));
    // 账号页先放转圈，读完登录状态才排出服务地址与登录卡。
    await waitFor(tester, find.text('忘记密码'));
    expect(find.text('账号与云同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的页的设置入口打开设置页', (tester) async {
    final active = ValueNotifier<int>(3);
    addTearDown(active.dispose);
    await pumpPage(tester, MinePage(activeTab: active));
    await waitFor(tester, find.widgetWithText(forui.FTile, '设置'));

    await tester.tap(find.widgetWithText(forui.FTile, '设置'));
    await waitFor(tester, find.widgetWithText(forui.FTile, '语义索引'));
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('设置页的语义索引入口打开语义索引页', (tester) async {
    await pumpPage(tester, const SettingsPage());
    await waitFor(tester, find.widgetWithText(forui.FTile, '语义索引'));

    await tester.tap(find.widgetWithText(forui.FTile, '语义索引'));
    await waitFor(tester, find.text('索引状态'));

    // 三段分开排：索引状态、嵌入来源、可发送范围。
    expect(find.text('索引状态'), findsOneWidget);
    expect(find.text('嵌入来源'), findsWidgets);
    expect(find.text('可发送范围'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EmbeddingSettingsPage),
        matching: find.byType(forui.FSwitch),
      ),
      findsOneWidget,
    );
  });

  testWidgets('插件页列出人格插件并可以停用', (tester) async {
    await pumpPage(tester, const PluginsPage());
    await waitFor(tester, find.textContaining('人格插件 · 版本 1.0.0'));

    expect(find.byType(PluginsPage), findsOneWidget);
    expect(find.text('人格'), findsWidgets, reason: '插件名称');
    expect(find.textContaining('已启用'), findsOneWidget);
    expect(find.textContaining('权限：不需要权限'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PluginsPage),
        matching: find.byType(forui.FSwitch),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find
          .descendant(
            of: find.byType(PluginsPage),
            matching: find.byType(forui.FSwitch),
          )
          .first,
    );
    await waitForMeta(tester, pluginEnabledKey('persona'), '0');
    expect(
      find.descendant(
        of: find.byType(PluginsPage),
        matching: find.textContaining('已停用'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('人格页单选启用与停用，写进 app_meta 并更新状态标签', (tester) async {
    await pumpPage(tester, const PersonaPage());
    await waitFor(tester, find.text('温和讲题'));

    expect(find.byType(PersonaPage), findsOneWidget);
    expect(find.text('简短直接'), findsOneWidget);
    expect(find.textContaining('人格只影响语气、称呼、讲解风格与篇幅倾向'), findsOneWidget);
    expect(find.text('不使用人格'), findsOneWidget);
    expect(find.text(personaDefaultTone), findsOneWidget);
    expect(find.text(personaExtrasUnavailable), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);
    expect(find.text('已启用'), findsNothing);

    // 三枚单选：不使用人格、温和讲题、简短直接。
    final radios = find.descendant(
      of: find.byType(PersonaPage),
      matching: find.byType(forui.FRadio),
    );
    expect(radios, findsNWidgets(3));

    await tester.tap(radios.at(1));
    await waitForMeta(tester, personaActiveKey, 'calm-teacher');
    await tester.pump();
    expect(find.text('当前启用'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text(personaDefaultTone), findsNothing);

    // 打开第二个人格会替换当前项，同一时间只留一个启用。
    await tester.tap(radios.at(2));
    await waitForMeta(tester, personaActiveKey, 'brief-coach');
    await tester.pump();
    expect(find.text('当前启用'), findsOneWidget);

    // 点“不使用人格”停用；状态标签回到未启用。
    await tester.tap(radios.first);
    await waitForMeta(tester, personaActiveKey, '');
    await tester.pump();
    expect(find.text('当前启用'), findsNothing);
    expect(find.text('未启用'), findsOneWidget);
    expect(find.text(personaDefaultTone), findsOneWidget);
  });
}
