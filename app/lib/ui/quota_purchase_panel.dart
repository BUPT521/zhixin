import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../application/account_service.dart';
import '../domain/models/quota_purchase.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';

class QuotaPurchasePanel extends StatefulWidget {
  const QuotaPurchasePanel({
    required this.account,
    required this.enabled,
    required this.onPaid,
    super.key,
  });

  final AccountService account;
  final bool enabled;
  final Future<void> Function() onPaid;

  @override
  State<QuotaPurchasePanel> createState() => _QuotaPurchasePanelState();
}

class _QuotaPurchasePanelState extends State<QuotaPurchasePanel> {
  static const _alipay = MethodChannel('com.zhixin.app/alipay');

  QuotaPurchaseOverview? _purchases;
  bool _busy = false;
  String? _notice;

  bool get _canPay =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final purchases = await widget.account.quotaPurchases();
      if (mounted) setState(() => _purchases = purchases);
    } catch (_) {
      // 账号页也能连接未提供收款接口的实例。
    }
  }

  Future<void> _buy(QuotaPurchaseOffer offer, {String? orderId}) async {
    if (_busy) return;
    final epoch = widget.account.identityEpoch;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final agreed = await confirmZhixin(
        context: context,
        title: offer.sandbox ? '支付宝沙箱付款' : '购买聊天额度',
        content: Text(
          '${offer.tokens} token · ¥${_yuan(offer.amountFen)}\n'
          '到账后计入当前账号。App 与该账号的模型接入密钥共用余额，先使用每日免费额度。',
        ),
        confirmLabel: '打开支付宝',
      );
      if (!agreed ||
          !mounted ||
          !widget.enabled ||
          widget.account.identityEpoch != epoch) {
        return;
      }
      final checkout = await widget.account.quotaCheckout(
        offer.id,
        orderId: orderId,
      );
      if (!mounted || widget.account.identityEpoch != epoch) return;
      final order = checkout?.order;
      if (order == null ||
          (orderId != null && order.id != orderId) ||
          order.offer.id != offer.id ||
          order.offer.amountFen != offer.amountFen ||
          order.offer.tokens != offer.tokens ||
          order.offer.sandbox != offer.sandbox ||
          !order.payable) {
        setState(() => _notice = '报价或订单状态已更新，请核对后继续。');
        return;
      }
      String? sdkStatus;
      try {
        sdkStatus = await _alipay.invokeMethod<String>('pay', {
          'order': checkout!.orderString,
          'sandbox': offer.sandbox,
        });
      } on PlatformException {
        sdkStatus = 'unavailable';
      }
      if (mounted && widget.account.identityEpoch == epoch) {
        await _check(order.id, sdkStatus: sdkStatus);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice = '暂时无法打开支付宝收银台，请检查最近订单。');
      }
    } finally {
      if (mounted) await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshOrder(String id) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _check(id);
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check(String id, {String? sdkStatus}) async {
    try {
      final order = await widget.account.quotaOrder(id);
      if (!mounted) return;
      setState(() {
        _notice = switch (order.status) {
          'paid' => '已到账，增加了 ${order.offer.tokens} token。',
          'closed' => '支付宝已关闭这笔订单。',
          _ when sdkStatus == '6001' => '已退出支付宝收银台，可以继续支付或查单。',
          _ when sdkStatus == 'unavailable' => '暂时无法打开支付宝收银台，可以稍后继续。',
          _ => '支付宝尚未确认到账，可以稍后查单。',
        };
      });
      if (order.status == 'paid') await widget.onPaid();
    } catch (_) {
      if (mounted) setState(() => _notice = '暂时无法查单，请稍后再试。');
    }
  }

  String _yuan(int fen) =>
      '${fen ~/ 100}.${(fen % 100).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final purchases = _purchases;
    if (purchases == null) return const SizedBox.shrink();
    final offer = purchases.offer;
    final order = purchases.latestOrder;
    if (offer == null && order == null && purchases.balanceTokens == 0) {
      return const SizedBox.shrink();
    }
    final theme = context.zhixin;
    final pending = order?.status == 'pending';
    final checkoutOffer = order?.payable == true ? order?.offer : offer;
    final enabled = !_busy && widget.enabled;
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已购聊天额度 ${purchases.balanceTokens} token'),
              if (order != null)
                Text(
                  '最近订单 · ${order.offer.sandbox ? '沙箱 · ' : ''}'
                  '¥${_yuan(order.offer.amountFen)} · ${order.offer.tokens} token · '
                  '${switch (order.status) {
                    'paid' => '已到账',
                    'closed' => '已关闭',
                    _ => '待确认',
                  }}',
                ),
              if (_canPay && checkoutOffer != null)
                Text(
                  '${checkoutOffer.sandbox ? '沙箱报价' : '一次性购买'} · '
                  '${checkoutOffer.tokens} token · ¥${_yuan(checkoutOffer.amountFen)}',
                ),
              if (_notice case final notice?) Text(notice),
              if (_busy) const Text('正在处理支付宝订单…'),
              if (pending || (_canPay && checkoutOffer != null))
                Padding(
                  padding: EdgeInsets.only(top: theme.space.sm),
                  child: Wrap(
                    spacing: theme.space.sm,
                    runSpacing: theme.space.sm,
                    children: [
                      if (_canPay && checkoutOffer != null)
                        forui.FButton(
                          mainAxisSize: MainAxisSize.min,
                          onPress: enabled
                              ? () => _buy(
                                  checkoutOffer,
                                  orderId: order?.payable == true
                                      ? order?.id
                                      : null,
                                )
                              : null,
                          child: Text(
                            order?.payable == true ? '继续支付' : '支付宝购买',
                          ),
                        ),
                      if (pending && order != null)
                        forui.FButton(
                          mainAxisSize: MainAxisSize.min,
                          variant: forui.FButtonVariant.outline,
                          onPress: enabled
                              ? () => _refreshOrder(order.id)
                              : null,
                          child: const Text('查询支付结果'),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
