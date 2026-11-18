import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/application/update_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/update_notice.dart';

/// 设置页顶部的更新提示：显示版本、更新说明、sha256 与签名核对结果，
/// “去下载”交给系统浏览器，“稍后”关闭。
void main() {
  AppUpdate update({
    bool mandatory = false,
    ReleaseSignatureState signature = ReleaseSignatureState.verified,
    String notes = '登录、云端备份与同步',
  }) => AppUpdate(
    release: ServerRelease(
      platform: 'android',
      version: '0.2.0',
      build: 3,
      url: 'https://example.test/zhixin-0.2.0.apk',
      sha256:
          '70248747c7a1f9260ad35da8de214707a737e8bec4c83cea33284b563a534c54',
      notes: notes,
    ),
    mandatory: mandatory,
    signature: signature,
  );

  Widget app(
    AppUpdate value, {
    VoidCallback? onDownload,
    VoidCallback? onDismiss,
  }) => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Scaffold(
        body: ListView(
          children: [
            UpdateNoticeCard(
              update: value,
              onDownload: onDownload ?? () {},
              onDismiss: onDismiss ?? () {},
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('显示版本、更新说明、sha256 与签名结果，点击去下载回调', (tester) async {
    var downloaded = false;
    await tester.pumpWidget(app(update(), onDownload: () => downloaded = true));

    expect(find.text('发现新版本 0.2.0（构建 3）'), findsOneWidget);
    expect(find.text('登录、云端备份与同步'), findsOneWidget);
    expect(
      find.textContaining(
        '70248747c7a1f9260ad35da8de214707a737e8bec4c83cea33284b563a534c54',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('已用内置公钥校验签名'), findsOneWidget);
    expect(find.text('可选更新'), findsOneWidget);
    expect(find.textContaining('不在本机自动下载或安装'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '去下载'));
    await tester.pumpAndSettle();
    expect(downloaded, isTrue);
  });

  testWidgets('必须更新的版本带标记与说明', (tester) async {
    await tester.pumpWidget(app(update(mandatory: true)));

    expect(find.text('必须更新'), findsOneWidget);
    expect(find.textContaining('低于当前允许的最低版本'), findsOneWidget);
  });

  testWidgets('未配置公钥时详情说明跳过签名校验', (tester) async {
    await tester.pumpWidget(
      app(update(signature: ReleaseSignatureState.skippedNoKey)),
    );
    expect(find.textContaining('跳过签名校验'), findsOneWidget);
  });

  testWidgets('点稍后关闭提示', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(app(update(), onDismiss: () => dismissed = true));

    await tester.tap(find.widgetWithText(forui.FButton, '稍后'));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
  });
}
