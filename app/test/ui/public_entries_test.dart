import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/format.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

/// 公共入口的宿主：页面读 `context.zhixin`，与真实界面用同一份 Forui 主题。
Widget _host(Widget child) => forui.FTheme(
  data: zhixinForuiTheme,
  child: MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('设备标识脱敏', () {
    test('只保留前八位，短标识原样，空值给空串', () {
      expect(maskedDeviceId(null), '');
      expect(maskedDeviceId('   '), '');
      expect(maskedDeviceId('abc'), 'abc');
      expect(maskedDeviceId('abcdefgh'), 'abcdefgh');
      expect(maskedDeviceId('abcdefghij'), 'abcdefgh');
      expect(maskedDeviceId('  abcdefghij  '), 'abcdefgh');
      expect(maskedDeviceId('abcdefghij', keep: 4), 'abcd');
    });
  });

  group('字节格式化', () {
    test('1025 B 只有一个结果，各档按四舍五入取整', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1025), '1 KB');
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes(1024 * 1024 - 1), '1024 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('防抖', () {
    test('连续调用只执行最后一次', () async {
      var calls = 0;
      final debouncer = Debouncer(duration: const Duration(milliseconds: 10));
      debouncer(() => calls++);
      debouncer(() => calls++);
      debouncer(() => calls++);
      expect(debouncer.isPending, isTrue);
      expect(calls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 1);
      expect(debouncer.isPending, isFalse);
      debouncer.dispose();
    });

    test('取消之后不再执行', () async {
      var calls = 0;
      final debouncer = Debouncer(duration: const Duration(milliseconds: 10));
      debouncer(() => calls++);
      debouncer.cancel();
      expect(debouncer.isPending, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 0);
    });
  });

  group('分隔线', () {
    testWidgets('一像素高，上下各留一档，取容器描边色', (tester) async {
      await tester.pumpWidget(_host(const CardDivider()));
      expect(tester.getSize(find.byType(CardDivider)).height, 25);
      final lineFinder = find.descendant(
        of: find.byType(CardDivider),
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(lineFinder).height, 1);
      final line = tester.widget<ColoredBox>(lineFinder);
      final colors = zhixinForuiTheme.extension<ZhixinTheme>().colors;
      expect(line.color, colors.outlineVariant);
    });

    testWidgets('紧凑的分组可以改成更小的间距', (tester) async {
      await tester.pumpWidget(_host(const CardDivider(gap: 8)));
      expect(tester.getSize(find.byType(CardDivider)).height, 17);
    });
  });

  group('一次性结果提示', () {
    testWidgets('成功说明是一行小字，不画错误描边', (tester) async {
      await tester.pumpWidget(_host(const ResultNotice(message: '已保存')));
      expect(find.text('已保存'), findsOneWidget);
      expect(find.byType(InlineNotice), findsNothing);
    });

    testWidgets('失败说明可以带重试', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        _host(
          ResultNotice(message: '没有保存', failed: true, onRetry: () => retried++),
        ),
      );
      expect(find.byType(InlineNotice), findsOneWidget);
      expect(find.text('没有保存'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('失败说明不给重试动作时没有按钮', (tester) async {
      await tester.pumpWidget(
        _host(const ResultNotice(message: '没有保存', failed: true)),
      );
      expect(find.byType(InlineNotice), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });
  });
}
