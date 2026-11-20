import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_toast.dart';

/// 短提示的位置与停留时间：Forui 默认把触屏设备的提示放在顶部、统一停 5 秒，
/// 应用改成落在下方，手机上 3 秒收起。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 按应用根的装法搭出页面，点一下按钮弹出一条提示。
  Future<void> pumpToast(
    WidgetTester tester, {
    TargetPlatform? platform,
    String message = '本周没有可顺延的搭子预约',
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: platform == null
            ? zhixinTheme
            : zhixinTheme.copyWith(platform: platform),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          ...GlobalMaterialLocalizations.delegates,
          forui.FLocalizations.delegate,
        ],
        builder: (context, child) => forui.FTheme(
          data: zhixinForuiTheme,
          child: forui.FToaster(style: zhixinToasterStyle, child: child!),
        ),
        home: Builder(
          builder: (context) => Center(
            child: forui.FButton(
              onPress: () => showToast(context, message),
              child: const Text('顺延'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('顺延'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(message), findsOneWidget);
  }

  testWidgets('短提示落在屏幕下半部，并让开底部导航', (tester) async {
    const height = 844.0;
    await pumpToast(tester);

    final toast = tester.getRect(find.byType(forui.FToast));
    expect(toast.center.dy, greaterThan(height / 2), reason: '提示要落在屏幕下半部');
    expect(
      toast.bottom,
      lessThanOrEqualTo(height - 96),
      reason: '底部要留出底栏导航的高度',
    );
    expect(toast.center.dx, closeTo(390 / 2, 1), reason: '提示居中对齐');
  });

  testWidgets('手机上的短提示 3 秒收起', (tester) async {
    await pumpToast(tester);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(forui.FToast), findsOneWidget, reason: '2 秒时还在');

    // 收起本身有 300 毫秒的退场动画，多推一帧再判断。
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(forui.FToast), findsNothing);
  });

  testWidgets('桌面上的短提示仍是 5 秒', (tester) async {
    await pumpToast(tester, platform: TargetPlatform.windows);

    await tester.pump(const Duration(milliseconds: 3500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(forui.FToast), findsOneWidget, reason: '桌面在 3.5 秒时还留着');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(forui.FToast), findsNothing);
  });
}
