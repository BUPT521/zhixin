import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/platform/app_paths.dart';
import 'package:zhixin/ui/home_shell.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

/// 启动失败页与失败页的重试。
///
/// 装配拆开之后这页仍然独立显示并可以重试：库文件被一个同名目录占住时首屏
/// 打不开，页面给出“本地数据库没有打开”；修好目录之后点“重试打开”直接进入
/// 首页，不必重启应用。
void main() {
  testWidgets('本地数据库打不开时显示失败页，重试之后进入首页', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('zhixin-startup-failure'),
    ))!;
    addTearDown(() => closeAppScope(null, root));
    await tester.runAsync(() => disableTelemetryForTests(root.path));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
        }
        return null;
      },
    );
    final spaces = AppSpaces(AppPaths(root.path, cacheDir: root.path));
    final dbPath = spaces.pathsFor(AppSpaces.local).dbPath;
    // 用同名目录占住库文件：打开数据库失败，失败页按“本地数据库没有打开”显示。
    await tester.runAsync(() => Directory(dbPath).create(recursive: true));

    /// 等一次首屏装配结束。
    ///
    /// 重试是在测试的假异步区里发起的：每轮既让真实的文件与数据库走完，也
    /// 推进一帧让装配自己的异步继续，两者缺一都会停在中途。
    Future<Object?> waitStartup(AppScopeState state) async {
      var done = false;
      Object? failure;
      state.ready.then(
        (_) {
          done = true;
        },
        onError: (Object error, StackTrace _) {
          failure = error;
          done = true;
        },
      );
      for (var round = 0; round < 600 && !done; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue, reason: '首屏装配没有在时限内结束');
      return failure;
    }

    AppScopeState? state;
    await tester.runAsync(() async {
      await tester.pumpWidget(ZhixinApp(spaces: spaces));
      state = tester.state<AppScopeState>(find.byType(AppScope));
    });
    final failure = await waitStartup(state!);
    await tester.pump();

    // 失败页给出原因与三个入口，首页没有建起来。
    expect(failure, isNotNull);
    expect(find.text('本地数据库没有打开'), findsOneWidget);
    expect(find.textContaining('错误：'), findsOneWidget);
    expect(find.text('重试打开'), findsOneWidget);
    expect(find.text('发送诊断反馈'), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(state!.dataReady, isFalse);

    // 修好数据目录之后重试：新的装配成功，页面换成首页。
    await tester.runAsync(() => Directory(dbPath).delete(recursive: true));
    await tester.tap(find.text('重试打开'));
    await tester.pump();
    expect(await waitStartup(state!), isNull);
    await tester.pump();

    expect(find.text('本地数据库没有打开'), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(state!.dataReady, isTrue);
    expect(File(dbPath).existsSync(), isTrue);

    // 收尾：先让首页自己的定时器（切栏预读、提示）到期，再按同一套“真实等待
    // 加推进帧”关掉装配，临时目录在用例结束时才能删掉。
    await tester.pump(const Duration(seconds: 1));
    var closed = false;
    state!.closeSpace().then(
      (_) {
        closed = true;
      },
      onError: (Object _, StackTrace _) {
        closed = true;
      },
    );
    for (var round = 0; round < 200 && !closed; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
