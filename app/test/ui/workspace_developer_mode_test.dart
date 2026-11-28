import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/ui/model_api_keys_page.dart';
import 'package:zhixin/ui/workspace_widgets.dart';
import 'package:zhixin/ui/zhixin_switch.dart';

import '../support/fake_server.dart';
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

    final mode = find.widgetWithText(ZhixinSwitch, '开发者模式');
    final address = find.widgetWithText(forui.FTile, '知新服务地址');
    final keys = find.widgetWithText(forui.FTile, '知新 API Key');
    final model = find.widgetWithText(forui.FTextField, '模型名');
    await tester.scrollUntilVisible(
      mode,
      160,
      scrollable: settingsScrollable(),
    );
    expect(tester.widget<ZhixinSwitch>(mode).value, isFalse);
    expect(address, findsNothing);
    expect(keys, findsNothing);
    expect(model, findsNothing);

    tester.widget<ZhixinSwitch>(mode).onChange!(true);
    await _waitUntil(tester, () => tester.widget<ZhixinSwitch>(mode).value);
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
    tester.widget<ZhixinSwitch>(mode).onChange!(false);
    await _waitUntil(tester, () => !tester.widget<ZhixinSwitch>(mode).value);
    await settle(tester);
    expect(address, findsNothing);
    expect(keys, findsNothing);
    expect(model, findsNothing);
    expect(await tester.runAsync(account.serverBaseUrl), customAddress);
  });

  testWidgets('API Key 页写出当前实例的调用地址', (tester) async {
    const customAddress = 'https://zhixin.example.test';
    final server = FakeServer();
    await openApp(
      tester,
      size: const Size(430, 1300),
      serverClientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: server.client),
    );
    await tester.runAsync(() async {
      final account = scope!.accountServices.account;
      await account.setServerBaseUrl(customAddress);
      await account.register(
        identifier: 'api-keys@example.com',
        password: 'password123',
      );
    });
    await settle(tester);

    Finder urlText(String value) => find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == value,
      description: '调用地址 $value',
    );
    final chatUrl = '$customAddress/v1/llm/responses';
    final embeddingUrl = '$customAddress/v1/llm/embeddings';

    // 设置页的入口要先登录，这里直接推入页面，只核对页面写出的地址。
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(builder: (_) => const ModelApiKeysPage()),
        );
    await settle(tester);
    await _waitUntil(tester, () => urlText(chatUrl).evaluate().isNotEmpty);

    expect(find.widgetWithText(SectionHeading, '调用地址'), findsOneWidget);
    expect(urlText(chatUrl), findsOneWidget);
    expect(urlText(embeddingUrl), findsOneWidget);
    expect(find.widgetWithText(forui.FButton, '复制对话地址'), findsOneWidget);
  });
}
