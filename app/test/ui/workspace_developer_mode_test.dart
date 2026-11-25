import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/app_database.dart' show zhixinSchemaVersion;

import 'workspace_support.dart';

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 100 && !ready(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

void main() {
  registerWorkspaceTests();

  testWidgets('开发者模式控制实例地址、密钥和模型配置入口', (tester) async {
    const customAddress = 'https://zhixin.example.test';
    final checked = <String>[];
    final backend = MockClient((request) async {
      if (request.url.path != '/readyz') return http.Response('', 404);
      expect(request.headers['authorization'], isNull);
      checked.add(request.url.origin);
      final status = request.url.origin == customAddress ? 'ready' : 'other';
      return http.Response(
        jsonEncode({'status': status, 'schema_version': zhixinSchemaVersion}),
        200,
      );
    });
    addTearDown(backend.close);
    await openApp(
      tester,
      size: const Size(430, 1300),
      serverClientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: backend),
    );
    final account = scope!.accountServices.account;
    final originalAddress = await tester.runAsync(account.serverBaseUrl);
    await openMineEntry(tester, '设置');

    final mode = find.widgetWithText(forui.FSwitch, '开发者模式');
    final address = find.widgetWithText(forui.FTile, '知新服务地址');
    final keys = find.widgetWithText(forui.FTile, '知新 API Key');
    final model = find.widgetWithText(forui.FTextField, '模型名');
    await tester.scrollUntilVisible(
      mode,
      160,
      scrollable: settingsScrollable(),
    );
    expect(tester.widget<forui.FSwitch>(mode).value, isFalse);
    expect(address, findsNothing);
    expect(keys, findsNothing);
    expect(model, findsNothing);

    tester.widget<forui.FSwitch>(mode).onChange!(true);
    await _waitUntil(tester, () => tester.widget<forui.FSwitch>(mode).value);
    await settle(tester);
    await tester.scrollUntilVisible(
      keys,
      120,
      scrollable: settingsScrollable(),
    );
    expect(keys, findsOneWidget);
    await tester.ensureVisible(address);
    await _waitUntil(
      tester,
      () => tester.widget<forui.FTile>(address).onPress != null,
    );
    await tester.tap(address);
    await settle(tester);

    final field = find.descendant(
      of: find.widgetWithText(forui.FTextField, '实例地址'),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'https://provider.example.test');
    await tester.tap(find.text('保存地址'));
    await settle(tester);
    expect(find.text('该地址没有可用的知新服务'), findsOneWidget);
    expect(await tester.runAsync(account.serverBaseUrl), originalAddress);

    await tester.enterText(field, customAddress);
    await tester.tap(find.text('保存地址'));
    await _waitUntil(tester, () => field.evaluate().isEmpty);
    await settle(tester);
    expect(field, findsNothing);
    expect(await tester.runAsync(account.serverBaseUrl), customAddress);
    expect(checked, ['https://provider.example.test', customAddress]);

    await tester.scrollUntilVisible(
      model,
      120,
      scrollable: settingsScrollable(),
    );
    expect(model, findsOneWidget);
    expect(find.text('zhixin-chat'), findsOneWidget);

    tester.state<ScrollableState>(settingsScrollable()).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      mode,
      160,
      scrollable: settingsScrollable(),
    );
    tester.widget<forui.FSwitch>(mode).onChange!(false);
    await _waitUntil(tester, () => !tester.widget<forui.FSwitch>(mode).value);
    await settle(tester);
    expect(address, findsNothing);
    expect(keys, findsNothing);
    expect(model, findsNothing);
    expect(await tester.runAsync(account.serverBaseUrl), customAddress);
  });
}
