// “模型额度”里的购买面板：概览读取失败、购买失败的分支、回到前台刷新与
// latest_purchase 入口（02 第 3.16 节、ADR-0067、ADR-0073、ADR-0074）。
//
// 面板只依赖账号服务的三个购买方法；这里用一个继承 AccountService 的替身直接
// 给出概览、链接与余额，不经过假服务端，也不覆盖服务端自己的业务规则。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/domain/models/quota_purchase.dart';
import 'package:zhixin/ui/quota_purchase_panel.dart';
import 'package:zhixin/ui/theme.dart';

import '../support/fake_server.dart';

/// 只实现购买面板用到的三个方法；其余账号行为不会被面板调用。
class _FakeAccount extends AccountService {
  _FakeAccount({required this.overview})
    : super(
        store: AccountStore(MemorySecretStore()),
        preferences: CloudPreferencesStore(filesDir: 'quota-panel-test'),
      );

  QuotaPurchaseOverview overview;
  QuotaPurchaseFailure? overviewError;
  QuotaPurchaseFailure? purchaseError;
  QuotaPurchaseLink? purchaseLink;
  QuotaBalance balance = const QuotaBalance(remaining: 0, total: 0, used: 0);

  /// 给「请求正在进行」的用例把响应停在途中；为空时立即返回。
  Completer<QuotaPurchaseLink>? pendingPurchase;
  Completer<QuotaBalance>? pendingBalance;

  int overviewCalls = 0;
  int balanceCalls = 0;
  final purchaseRequests = <({String? skuId, String? clientRequestNo})>[];

  @override
  Future<QuotaPurchaseOverview> quotaPurchases() async {
    overviewCalls++;
    if (overviewError case final error?) throw error;
    return overview;
  }

  @override
  Future<QuotaPurchaseLink> quotaPurchaseLink({
    String? skuId,
    String? clientRequestNo,
  }) async {
    purchaseRequests.add((skuId: skuId, clientRequestNo: clientRequestNo));
    if (pendingPurchase case final pending?) return pending.future;
    if (purchaseError case final error?) throw error;
    return purchaseLink!;
  }

  @override
  Future<QuotaBalance> quotaBalance() async {
    balanceCalls++;
    if (pendingBalance case final pending?) return pending.future;
    return balance;
  }
}

QuotaPurchaseOption _option({String skuId = 'sku-1', int points = 100}) =>
    QuotaPurchaseOption(
      skuId: skuId,
      displayName: '基础包',
      price: '6.00',
      quotaAmount: points,
    );

QuotaPurchaseProduct _product({List<QuotaPurchaseOption>? options}) =>
    QuotaPurchaseProduct(
      capabilityStatus: 'ENABLED',
      billingMode: 'QUANTITY',
      quotaUnit: 'POINT',
      options: options ?? [_option()],
    );

QuotaPurchaseOverview _overview({
  int balancePoints = 100,
  bool balanceUnavailable = false,
  QuotaPurchaseLink? latestPurchase,
}) => QuotaPurchaseOverview(
  balancePoints: balancePoints,
  balanceUnavailable: balanceUnavailable,
  tokensPerPoint: 1000,
  product: _product(),
  latestPurchase: latestPurchase,
);

QuotaPurchaseLink _link({
  String? skuId,
  String url = 'https://example.test/pay',
  Duration remaining = const Duration(minutes: 10),
}) => QuotaPurchaseLink(
  outRequestNo: 'req-1',
  skuId: skuId,
  purchaseUrl: url,
  expiresAt: DateTime.now().add(remaining),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAccount account;
  late List<String> launchedUrls;
  bool launchResult = true;
  String? copiedText;

  setUp(() {
    account = _FakeAccount(overview: _overview());
    launchedUrls = [];
    launchResult = true;
    copiedText = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launchedUrls.add((call.arguments as Map)['url']! as String);
          return launchResult;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    account.dispose();
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    // 按手机宽度排版：档位名称、价格、积分与购买按钮要在同一行里放得下。
    tester.view.physicalSize = const Size(390, 1400);
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
        builder: (context, child) =>
            forui.FTheme(data: zhixinForuiTheme, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuotaPurchasePanel(
              account: account,
              enabled: true,
              dailyTokens: null,
              onPaid: () async {},
            ),
          ),
        ),
      ),
    );
    // 概览读取走一个异步 Future，等它回填之后再断言。
    await tester.pump();
    await tester.pump();
  }

  Finder purchaseButton() => find.widgetWithText(forui.FButton, '购买');

  /// 等 forui 点击动画的计时器走完，测试结束时不留下未完成的 Timer。
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 300));

  testWidgets('概览读取遇到 429 时说明原因、写出等待秒数并给重试', (tester) async {
    account.overviewError = const QuotaPurchaseFailure(
      QuotaPurchaseFailureKind.rateLimited,
      retryAfter: Duration(seconds: 8),
    );
    await pumpPanel(tester);

    expect(find.textContaining('暂时无法读取购买信息'), findsOneWidget);
    expect(find.textContaining('8 秒'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试之后读到概览，正常显示余额与档位。
    account.overviewError = null;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('可用积分'), findsOneWidget);
    expect(find.textContaining('暂时无法读取购买信息'), findsNothing);
    expect(purchaseButton(), findsOneWidget);
    await settle(tester);
  });

  testWidgets('balance_unavailable 时提示暂时查不到余额，档位照常显示', (tester) async {
    account.overview = _overview(balancePoints: 0, balanceUnavailable: true);
    await pumpPanel(tester);

    expect(find.textContaining('暂时查不到余额'), findsOneWidget);
    expect(find.textContaining('可用积分'), findsNothing);
    expect(purchaseButton(), findsOneWidget);
    expect(find.textContaining('基础包'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('同一次点击的重试复用同一个 client_request_no，换一次点击换新', (tester) async {
    account.purchaseError = const QuotaPurchaseFailure(
      QuotaPurchaseFailureKind.offline,
    );
    account.purchaseLink = _link(skuId: 'sku-1');
    await pumpPanel(tester);

    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(account.purchaseRequests, hasLength(1));
    final first = account.purchaseRequests.first.clientRequestNo;
    expect(first, isNotNull);
    expect(first!.length, lessThanOrEqualTo(64));
    expect(find.textContaining('网络不可用'), findsOneWidget);

    // 同一次点击失败之后的重试沿用原来的键。
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(account.purchaseRequests, hasLength(2));
    expect(account.purchaseRequests[1].clientRequestNo, first);

    // 链接取到、打开成功；此时换一次点击就要换新键。
    account.purchaseError = null;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(account.purchaseRequests, hasLength(3));
    expect(account.purchaseRequests[2].clientRequestNo, first);
    expect(launchedUrls, ['https://example.test/pay']);

    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(account.purchaseRequests, hasLength(4));
    final second = account.purchaseRequests[3].clientRequestNo;
    expect(second, isNotNull);
    expect(second, isNot(first));
    await settle(tester);
  });

  testWidgets('购买遇到 429 时提示稍后再试，并禁用按钮到 retryAfter', (tester) async {
    account.purchaseLink = _link(skuId: 'sku-1');
    account.purchaseError = const QuotaPurchaseFailure(
      QuotaPurchaseFailureKind.rateLimited,
      retryAfter: Duration(seconds: 8),
    );
    await pumpPanel(tester);

    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('请 8 秒后再试'), findsOneWidget);
    expect(tester.widget<forui.FButton>(purchaseButton()).onPress, isNull);

    // 等过 8 秒之后恢复可点。
    await tester.pump(const Duration(seconds: 9));
    expect(tester.widget<forui.FButton>(purchaseButton()).onPress, isNotNull);
    await settle(tester);
  });

  testWidgets('购买遇到 409 与 403 分别说明原因，不压成同一句', (tester) async {
    account.purchaseLink = _link(skuId: 'sku-1');
    account.purchaseError = const QuotaPurchaseFailure(
      QuotaPurchaseFailureKind.conflict,
    );
    await pumpPanel(tester);
    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('商品已经下架'), findsOneWidget);

    account.purchaseError = const QuotaPurchaseFailure(
      QuotaPurchaseFailureKind.contactUnverified,
    );
    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('确认一种登录方式'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('只有从支付宝回来才刷新一次余额，没变化时再补查一次', (tester) async {
    account.purchaseLink = _link(skuId: 'sku-1');
    account.balance = const QuotaBalance(remaining: 100, total: 100, used: 0);
    await pumpPanel(tester);

    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(launchedUrls, hasLength(1));

    // 没有先进过后台的 resumed 不算从支付宝回来。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(account.balanceCalls, 0);

    // 进后台再回前台：刷新一次；余额没有变化，6 秒后再补查一次。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(account.balanceCalls, 1);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    expect(account.balanceCalls, 2);

    // 再次回到前台时已经不再等这次购买，不会再查。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(account.balanceCalls, 2);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('没能打开支付宝时提示确认安装，并提供复制链接', (tester) async {
    launchResult = false;
    account.purchaseLink = _link(skuId: 'sku-1');
    await pumpPanel(tester);

    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('没能打开支付宝'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    expect(copiedText, 'https://example.test/pay');
    expect(find.textContaining('购买链接已复制'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('刷新途中回到前台时这一次刷新排队，结束后补上', (tester) async {
    account.purchaseLink = _link(skuId: 'sku-1');
    account.balance = const QuotaBalance(remaining: 100, total: 100, used: 0);
    await pumpPanel(tester);
    await tester.tap(purchaseButton());
    await tester.pump();
    await tester.pump();
    expect(account.balanceCalls, 0);

    // 手动刷新还没回来时回到前台：这次刷新排队，不直接丢掉。
    account.pendingBalance = Completer<QuotaBalance>();
    await tester.tap(find.text('刷新余额'));
    await tester.pump();
    expect(account.balanceCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(account.balanceCalls, 1);

    final pending = account.pendingBalance!;
    account.pendingBalance = null;
    pending.complete(const QuotaBalance(remaining: 100, total: 100, used: 0));
    await tester.pump();
    await tester.pump();
    expect(account.balanceCalls, 2);
    await settle(tester);
  });

  testWidgets('未过期的同档位链接给出继续上次购买入口，直接打开原链接', (tester) async {
    account.overview = _overview(latestPurchase: _link(skuId: 'sku-1'));
    await pumpPanel(tester);

    expect(find.text('继续上次购买'), findsOneWidget);
    await tester.tap(find.text('继续上次购买'));
    await tester.pump();
    await tester.pump();
    expect(launchedUrls, ['https://example.test/pay']);
    // 复用旧链接，不再向服务端要新链接。
    expect(account.purchaseRequests, isEmpty);
    await settle(tester);
  });

  testWidgets('档位对不上或已经过期的链接不给继续上次购买入口', (tester) async {
    account.overview = _overview(
      latestPurchase: _link(
        skuId: 'sku-other',
        remaining: const Duration(minutes: -1),
      ),
    );
    await pumpPanel(tester);

    expect(find.text('继续上次购买'), findsNothing);
    await settle(tester);
  });
}
