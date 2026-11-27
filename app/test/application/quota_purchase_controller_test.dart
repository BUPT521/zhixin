// 额度购买的对账、刷新排队、幂等键与限流冷却（审查条目 A30）。
//
// 这四件事原先写在额度购买面板的 widget State 里，没有任何用例；抽成普通控制器
// 之后可以单独核对：到账只在“先前读到过余额、这次变多”时成立，可以继续购买的
// 链接要同时满足未过期、有档位、没付过款，同一段等待里到来的刷新要排队补上。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/quota_purchase_controller.dart';
import 'package:zhixin/domain/models/quota_purchase.dart';

void main() {
  late DateTime now;
  late QuotaPurchaseController controller;

  const option = QuotaPurchaseOption(
    skuId: 'sku-1',
    displayName: '小包',
    price: '6.00',
    quotaAmount: 100,
  );
  const product = QuotaPurchaseProduct(
    capabilityStatus: 'ENABLED',
    billingMode: 'ONE_TIME',
    quotaUnit: 'POINT',
    options: [option],
  );

  QuotaPurchaseLink link({String requestNo = 'req-1', Duration? validFor}) =>
      QuotaPurchaseLink(
        outRequestNo: requestNo,
        purchaseUrl: 'https://pay.example.test/$requestNo',
        expiresAt: now.add(validFor ?? const Duration(minutes: 10)),
        skuId: 'sku-1',
      );

  QuotaPurchaseOverview overview({
    int balance = 100,
    QuotaPurchaseLink? latest,
  }) => QuotaPurchaseOverview(
    balancePoints: balance,
    tokensPerPoint: 10000,
    product: product,
    latestPurchase: latest,
  );

  setUp(() {
    now = DateTime(2026, 11, 27, 12);
    controller = QuotaPurchaseController(now: () => now);
    addTearDown(controller.dispose);
  });

  test('到账只在先前读到过余额、这次变多时成立', () {
    // 没有对照时只说刷新，不说到账。
    final first = controller.applyBalance(
      const QuotaBalance(remaining: 100, total: 100, used: 0),
      quiet: false,
    );
    expect(first.paid, isFalse);
    expect(controller.notice, '已刷新，可用积分 100 分。');

    // 记下概览之后再查，余额变多：这张链接已经付过款。
    controller.loaded(overview(balance: 100));
    final second = controller.applyBalance(
      const QuotaBalance(remaining: 220, total: 220, used: 0),
      quiet: true,
    );
    expect(second.paid, isTrue);
    expect(controller.notice, '已到账，可用积分 220 分。');
    expect(controller.purchases!.balancePoints, 220);
  });

  test('后台补查没查到新积分时不覆盖已有说明，余额查不到时不说到账', () {
    controller.loaded(overview(balance: 100));
    controller.setNotice('已有说明');
    final outcome = controller.applyBalance(
      const QuotaBalance(remaining: 100, total: 100, used: 0),
      quiet: true,
    );
    expect(outcome.paid, isFalse);
    expect(controller.notice, '已有说明');

    controller.loaded(
      const QuotaPurchaseOverview(balancePoints: 0, balanceUnavailable: true),
    );
    controller.setNotice('已有说明');
    final unavailable = controller.applyBalance(
      const QuotaBalance(remaining: 50, total: 50, used: 0),
      quiet: false,
    );
    expect(unavailable.paid, isFalse, reason: '先前读不到余额时没有对照');
  });

  test('可以继续购买的链接要未过期、有档位、且没付过款', () {
    controller.loaded(overview(latest: link()));
    expect(controller.latestLink()?.outRequestNo, 'req-1');

    // 付过款的那一张不再提供，避免重新打开一张支付过的页面。
    controller.markLinkPaid(link());
    expect(controller.latestLink(), isNull);

    // 过期的那一张不再提供。
    controller.markLinkPaid(null);
    controller.loaded(overview(latest: link(requestNo: 'req-2')));
    expect(controller.latestLink()?.outRequestNo, 'req-2');
    now = now.add(const Duration(minutes: 11));
    expect(controller.latestLink(), isNull);
  });

  test('同一次点击的重试复用幂等键，换一次点击生成新键', () {
    expect(controller.requestNo(retryOf: 'req-1'), 'req-1');
    final generated = controller.requestNo();
    expect(generated, isNotEmpty);
    expect(controller.requestNo(), isNot(generated));
  });

  test('忙的时候到来的刷新排队，当前一次结束后再补一次', () {
    expect(controller.begin(), isTrue);
    expect(controller.begin(), isFalse);
    controller.queueRefresh();
    expect(controller.end(), isTrue, reason: '结束之后要补一次排队中的刷新');
    expect(controller.end(), isFalse, reason: '补过一次就不再重复');
  });

  test('限流冷却按服务端给的秒数禁用按钮，到点由面板排的定时器清掉', () {
    controller.startCooldown(30);
    expect(controller.cooling, isTrue);
    expect(controller.cooldownSecondsLeft, 30);

    now = now.add(const Duration(seconds: 10));
    expect(controller.cooldownSecondsLeft, 20);

    controller.clearCooldown();
    expect(controller.cooling, isFalse);
  });

  test('切换账号时清掉等待返回与待重试项', () {
    controller.setAwaitingReturn(true);
    controller.rememberPendingPurchase(option, 'req-9');
    controller.rememberFailedOpenLink(link());

    controller.staleIdentity();

    expect(controller.awaitingReturn, isFalse);
    expect(controller.pendingPurchase, isNull);
    expect(controller.failedOpenLink, isNull);
  });
}
