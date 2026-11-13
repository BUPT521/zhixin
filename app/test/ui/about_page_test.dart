import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/platform/app_license.dart';
import 'package:zhixin/platform/app_info.dart';
import 'package:zhixin/ui/about_page.dart';
import 'package:zhixin/ui/theme.dart';

void main() {
  setUpAll(registerAppLicense);

  Widget aboutApp() => MaterialApp(
    title: appName,
    theme: zhixinTheme,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      ...GlobalMaterialLocalizations.delegates,
      forui.FLocalizations.delegate,
    ],
    // 关于页的两个入口已换成 Forui 的 FTile，它要求上层有 FTheme。
    builder: (context, child) =>
        forui.FTheme(data: zhixinForuiTheme, child: child!),
    home: const AboutPage(),
  );

  testWidgets('关于页显示应用名、版本与两个入口', (tester) async {
    await tester.pumpWidget(aboutApp());

    expect(find.text(appName), findsOneWidget);
    expect(find.text('版本 $appVersion'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('项目主页'), findsOneWidget);
  });

  testWidgets('开源许可入口打开许可页并带上应用版本', (tester) async {
    await tester.pumpWidget(aboutApp());

    await tester.tap(find.text('开源许可'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text(appVersion), findsOneWidget);
  });

  test('应用内 MIT 许可与仓库 LICENSE 同文', () {
    final file = File('../LICENSE').existsSync()
        ? File('../LICENSE')
        : File('LICENSE');
    expect(_normalize(appLicenseText), _normalize(file.readAsStringSync()));
  });
}

String _normalize(String text) => text.replaceAll('\r\n', '\n').trim();
