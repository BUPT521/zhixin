import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

void main() {
  testWidgets('整页等待的圈按 36 显示，颜色取主色', (tester) async {
    await tester.pumpWidget(
      forui.FTheme(
        data: zhixinForuiTheme,
        child: const MaterialApp(home: Scaffold(body: PageLoading())),
      ),
    );

    // Forui 的默认尺寸取正文字号，手机上只有 18；整页等待这一处显式放大，
    // 页面换成别家组件时尺寸也不能悄悄回到字号。
    final iconTheme = tester.widget<IconTheme>(
      find
          .descendant(
            of: find.byType(forui.FCircularProgress),
            matching: find.byType(IconTheme),
          )
          .first,
    );
    expect(iconTheme.data.size, PageLoading.diameter);
    expect(PageLoading.diameter, greaterThanOrEqualTo(32));
    expect(iconTheme.data.color, zhixinForuiTheme.colors.primary);
  });
}
