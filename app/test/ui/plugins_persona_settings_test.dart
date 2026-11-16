import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/plugins/persona/persona_catalog.dart';
import 'package:zhixin/plugins/runtime/plugin_runtime.dart';
import 'package:zhixin/ui/copy.dart';
import 'package:zhixin/ui/persona_page.dart';
import 'package:zhixin/ui/plugins_page.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

/// 设置页的插件与人格入口：列表、启停与切换写进 app_meta。
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
    await scope?.testing.db.close();
    scope = null;
    await directory.delete(recursive: true);
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

  testWidgets('设置页显示插件与人格两个入口', (tester) async {
    await pumpPage(tester, const SettingsPage());
    await waitFor(tester, find.text('设置'));
    expect(find.byType(SettingsPage), findsOneWidget);

    // 设置页比手机屏长，入口在下方；滚到可见再核对。
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var step = 0; step < 10; step++) {
      if (find.widgetWithText(forui.FTile, '插件').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.widgetWithText(forui.FTile, '插件'), findsOneWidget);
    expect(find.widgetWithText(forui.FTile, '人格'), findsOneWidget);
    expect(find.text(pluginsEntrySubtitle), findsOneWidget);
    expect(find.text(personaEntrySubtitle), findsOneWidget);
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

  testWidgets('人格页切换启用与停用，写进 app_meta 并更新状态行', (tester) async {
    await pumpPage(tester, const PersonaPage());
    await waitFor(tester, find.text('温和讲题'));

    expect(find.byType(PersonaPage), findsOneWidget);
    expect(find.text('简短直接'), findsOneWidget);
    expect(find.textContaining('人格只影响语气、称呼、讲解风格与篇幅倾向'), findsOneWidget);
    expect(find.text(personaDefaultTone), findsOneWidget);
    expect(find.text(personaExtrasUnavailable), findsOneWidget);

    await tester.tap(
      find
          .descendant(
            of: find.byType(PersonaPage),
            matching: find.byType(forui.FSwitch),
          )
          .first,
    );
    await waitForMeta(tester, personaActiveKey, 'calm-teacher');
    expect(find.textContaining('当前人格：温和讲题'), findsOneWidget);
    expect(find.text(personaDefaultTone), findsNothing);

    await tester.tap(
      find
          .descendant(
            of: find.byType(PersonaPage),
            matching: find.byType(forui.FSwitch),
          )
          .first,
    );
    await waitForMeta(tester, personaActiveKey, '');
    expect(find.text(personaDefaultTone), findsOneWidget);
  });
}
