import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/platform/app_paths.dart';
import 'package:zhixin/platform/theme_mode_store.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/sync_rig.dart';
import '../support/telemetry.dart';

void main() {
  testWidgets('已有账号从原空间继续同步，另一个账号与未登录空间独立', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('zhixin-account-spaces'),
    ))!;
    addTearDown(() => closeAppScope(null, root));
    await tester.runAsync(() => disableTelemetryForTests(root.path));
    final spaces = AppSpaces(AppPaths(root.path, cacheDir: root.path));
    final fake = FakeServer();
    final initialTheme = ThemeModeController(
      store: ThemeModeStore(spaces.pathsFor(AppSpaces.local).filesDir),
    );
    addTearDown(initialTheme.dispose);

    AppScopeState scope() => tester.state<AppScopeState>(find.byType(AppScope));
    Future<AppScopeState> ready() async {
      final state = (await tester.runAsync(() async {
        await tester.pump();
        final opened = scope();
        await opened.ready;
        return opened;
      }))!;
      await tester.pump();
      return state;
    }

    await tester.runAsync(
      () => tester.pumpWidget(
        ZhixinApp(
          spaces: spaces,
          themeMode: initialTheme,
          serverClientFactory: (base) =>
              ServerClient(baseUrl: base, httpClient: fake.client),
        ),
      ),
    );
    final local = await ready();
    await tester.runAsync(() async {
      await local.themeMode.select(ThemeMode.dark);
      await File('${local.paths.filesDir}/本机.jpg').writeAsString('local');
      await local.accountServices.account.setServerBaseUrl(syncTestServerUrl);
      await local.accountServices.account.register(
        identifier: 'a@example.com',
        password: syncTestPassword,
      );
    });
    final first = await ready();
    expect(first.spaceId, isNot(AppSpaces.local));
    expect(first.themeMode.value, ThemeMode.dark);
    await tester.runAsync(() async {
      expect(await File('${first.paths.filesDir}/本机.jpg').exists(), isTrue);
      await first.accountServices.sync.syncNow();
      await first.accountServices.account.logout();
    });
    final secondLocal = await ready();
    expect(secondLocal.spaceId, AppSpaces.local);
    expect(secondLocal.themeMode.value, ThemeMode.system);
    await tester.runAsync(() async {
      expect(
        await File('${secondLocal.paths.filesDir}/本机.jpg').exists(),
        isFalse,
      );
      await secondLocal.accountServices.account.register(
        identifier: 'b@example.com',
        password: syncTestPassword,
      );
    });
    final second = await ready();
    expect(second.spaceId, isNot(first.spaceId));
    await tester.runAsync(() async {
      expect(await File('${second.paths.filesDir}/本机.jpg').exists(), isFalse);
      await second.accountServices.account.logout(deleteSpace: true);
    });
    final thirdLocal = await ready();
    await tester.runAsync(() async {
      expect(await Directory(second.paths.filesDir).exists(), isFalse);
      await File('${thirdLocal.paths.filesDir}/未登录.jpg').writeAsString('guest');
      await thirdLocal.accountServices.account.login(
        identifier: 'a@example.com',
        password: syncTestPassword,
      );
    });
    final reopened = await ready();
    expect(reopened.spaceId, first.spaceId);
    expect(reopened.themeMode.value, ThemeMode.dark);
    await tester.runAsync(() async {
      expect(
        (await reopened.accountServices.sync.status()).needsBootstrap,
        isFalse,
      );
      expect(
        await File('${reopened.paths.filesDir}/未登录.jpg').exists(),
        isFalse,
      );
      await reopened.clearAllData(password: syncTestPassword);
    });
    final cleared = await ready();
    expect(cleared.spaceId, first.spaceId);
    expect(cleared.themeMode.value, ThemeMode.system);
    await tester.runAsync(() async {
      expect(
        (await cleared.accountServices.account.snapshot()).signedIn,
        isTrue,
      );
      expect(await File('${cleared.paths.filesDir}/本机.jpg').exists(), isFalse);
      await cleared.accountServices.account.deleteAccount(
        password: syncTestPassword,
      );
    });
    final returned = await ready();
    expect(returned.spaceId, AppSpaces.local);
    await tester.runAsync(() async {
      expect(await Directory(first.paths.filesDir).exists(), isFalse);
      expect(await File('${returned.paths.filesDir}/未登录.jpg').exists(), isTrue);
      await returned.closeSpace();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
