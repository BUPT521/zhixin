import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/date_time_dialogs.dart';
import 'package:zhixin/ui/theme.dart';

/// 日期与时间选择改由 Material 的选择器承担；这里验证范围钳制、确认与取消。
void main() {
  testWidgets('日期选择限制范围，确认后返回本地日期', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DateTime? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showZhixinDatePicker(
          context: context,
          initialDate: DateTime(2026, 11, 1),
          firstDate: DateTime(2026, 11, 12),
          lastDate: DateTime(2026, 11, 30),
        );
      }),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    // 初始日期早于范围下界，打开时已经落到 12 日。
    await tester.tap(find.text('12').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2026, 11, 12));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('13').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2026, 11, 13));
  });

  testWidgets('时间选择确认返回当前时刻，取消返回空值', (tester) async {
    const initialTime = TimeOfDay(hour: 18, minute: 47);
    TimeOfDay? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showZhixinTimePicker(
          context: context,
          initialTime: initialTime,
        );
      }),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, initialTime);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}

Widget _host(ValueChanged<BuildContext> open) => MaterialApp(
  theme: zhixinTheme,
  localizationsDelegates: const [...GlobalMaterialLocalizations.delegates],
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(onPressed: () => open(context), child: const Text('打开')),
    ),
  ),
);
