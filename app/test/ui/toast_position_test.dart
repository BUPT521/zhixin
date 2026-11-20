import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_toast.dart';

/// 短提示的位置固定在屏幕下方：Forui 默认把触屏设备的提示放在顶部，
/// 应用根换成中下之后，页面里的提示不再随平台跑到上面去。
void main() {
  testWidgets('短提示落在屏幕下半部，并让开底部导航', (tester) async {
    const height = 844.0;
    tester.view.physicalSize = const Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
          child: forui.FToaster(style: zhixinToasterStyle, child: child!),
        ),
        home: Builder(
          builder: (context) => Center(
            child: forui.FButton(
              onPress: () => showToast(context, '本周没有可顺延的搭子预约'),
              child: const Text('顺延'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('顺延'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('本周没有可顺延的搭子预约'), findsOneWidget);
    final toast = tester.getRect(find.byType(forui.FToast));
    expect(toast.center.dy, greaterThan(height / 2), reason: '提示要落在屏幕下半部');
    expect(
      toast.bottom,
      lessThanOrEqualTo(height - 96),
      reason: '底部要留出底栏导航的高度',
    );
    expect(toast.center.dx, closeTo(390 / 2, 1), reason: '提示居中对齐');

    // 提示靠定时器自动收起，推到收起之后再结束用例，避免留下未触发的计时器。
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
