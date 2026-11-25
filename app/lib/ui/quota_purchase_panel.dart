import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/account_service.dart';
import '../domain/models/quota_purchase.dart';
import 'format.dart';
import 'theme.dart';

/// “模型额度”一节：展示即刻收的积分余额与档位，按托管购买页完成付款。
///
/// 客户端不参与定价，也不凭返回页放行：点购买只取一张购买链接交给支付宝，回到知新
/// 之后重新查余额；扣减发生在服务端核销，见 ADR-0067。
class QuotaPurchasePanel extends StatefulWidget {
  const QuotaPurchasePanel({
    required this.account,
    required this.enabled,
    required this.onPaid,
    this.dailyTokens,
    super.key,
  });

  final AccountService account;
  final bool enabled;

  /// 聊天每天免费额度的计费 token 数，用来把档位换算成天数；额度读不到时为 null。
  final int? dailyTokens;

  /// 余额变多之后回调，让账号页刷新今日额度。
  final Future<void> Function() onPaid;

  @override
  State<QuotaPurchasePanel> createState() => _QuotaPurchasePanelState();
}

class _QuotaPurchasePanelState extends State<QuotaPurchasePanel>
    with WidgetsBindingObserver {
  QuotaPurchaseOverview? _purchases;
  bool _busy = false;
  String? _notice;

  /// 已经打开购买页，等用户回到知新之后刷新余额。外部应用拉起时 launcher 立刻
  /// 返回，付款是否完成只能靠回到前台这一个信号判断。
  bool _awaitingReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingReturn) {
      _awaitingReturn = false;
      unawaited(_refreshBalance());
    }
  }

  Future<void> _load() async {
    try {
      final purchases = await widget.account.quotaPurchases();
      if (mounted) setState(() => _purchases = purchases);
    } catch (_) {
      // 账号页也能连接未提供购买接口的实例。
    }
  }

  Future<void> _refreshBalance() async {
    if (_busy) return;
    final epoch = widget.account.identityEpoch;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final balance = await widget.account.quotaBalance();
      if (!mounted || widget.account.identityEpoch != epoch) return;
      final purchases = _purchases;
      final before = purchases?.balancePoints ?? 0;
      setState(() {
        if (purchases == null) return;
        _purchases = QuotaPurchaseOverview(
          balancePoints: balance.remaining,
          tokensPerPoint: purchases.tokensPerPoint,
          product: purchases.product,
          latestPurchase: purchases.latestPurchase,
        );
        _notice = balance.remaining > before
            ? '已到账，可用积分 ${balance.remaining} 分。'
            : '还没有查到新的积分，可以稍后再刷新一次。';
      });
      if (balance.remaining > before) await widget.onPaid();
    } catch (_) {
      if (mounted) setState(() => _notice = '暂时无法查询余额，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buy(QuotaPurchaseOption option) async {
    if (_busy) return;
    final epoch = widget.account.identityEpoch;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final link = await widget.account.quotaPurchaseLink(skuId: option.skuId);
      if (!mounted || widget.account.identityEpoch != epoch) return;
      if (link == null) {
        setState(() => _notice = '商品当前不接受购买，可以稍后再试。');
        return;
      }
      final opened = await launchUrl(
        Uri.parse(link.purchaseUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (opened) {
        _awaitingReturn = true;
        setState(() => _notice = '在支付宝里完成付款后回到知新，这里会重新查一次余额。');
      } else {
        setState(() => _notice = '没有可以打开购买页的支付宝，请先安装或更新支付宝。');
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '暂时无法打开购买页，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final purchases = _purchases;
    if (purchases == null) return const SizedBox.shrink();
    final product = purchases.product;
    final options = product?.purchasable == true ? product!.options : const [];
    final hasPoints = purchases.balancePoints > 0;
    if (product == null && !hasPoints) {
      return const SizedBox.shrink();
    }
    final theme = context.zhixin;
    final enabled = !_busy && widget.enabled;
    final tokensPerPoint = purchases.tokensPerPoint;
    final ratio = tokensPerPoint != null && tokensPerPoint > 0
        ? tokensPerPoint
        : null;
    final daily = widget.dailyTokens;
    // 换算口径见 ADR-0068：一个积分覆盖 ratio 个计费 token，免费额度也按计费
    // token 计。额度读不到时只说明比例，不猜每天有多少。
    String? legend;
    if (ratio != null) {
      legend = '1 积分 = ${tokenAmount(ratio)} 计费 token';
      if (daily != null && daily > 0) {
        legend =
            '1 积分 = ${tokenAmount(ratio)} 计费 token；'
            '今天的免费额度是 ${tokenAmount(daily)} 计费 token，'
            '约 ${groupDigits(quotaPoints(daily, ratio))} 积分。';
      }
    }
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('可用积分 ${groupDigits(purchases.balancePoints)} 分'),
              if (legend != null)
                Text(
                  legend,
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              Text(
                '积分跨日保留；每轮结束先扣当天免费额度，再扣积分。',
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
              if (product != null && !product.purchasable)
                Text(_statusText(product.capabilityStatus)),
              for (final option in options)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${option.displayName} · ¥${option.price} · '
                        '${groupDigits(option.quotaAmount)} 分',
                      ),
                      if (ratio != null)
                        Text(
                          _conversion(option.quotaAmount * ratio, daily),
                          style: theme.text.bodySmall.copyWith(
                            color: theme.colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              if (_notice case final notice?) Text(notice),
              if (_busy) const Text('正在与支付宝核对…'),
              Padding(
                padding: EdgeInsets.only(top: theme.space.sm),
                child: Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    for (final option in options)
                      forui.FButton(
                        mainAxisSize: MainAxisSize.min,
                        onPress: enabled ? () => _buy(option) : null,
                        child: Text('购买 ${groupDigits(option.quotaAmount)} 分'),
                      ),
                    forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      variant: forui.FButtonVariant.outline,
                      onPress: enabled ? _refreshBalance : null,
                      child: const Text('刷新余额'),
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

  /// 一档积分的换算：按服务端给的比例换成计费 token，有每日额度时再给出天数。
  String _conversion(int tokens, int? dailyTokens) {
    final base = '约 ${tokenAmount(tokens)}计费 token';
    if (dailyTokens == null || dailyTokens <= 0) return base;
    return '$base，折合 ${quotaDays(tokens / dailyTokens)} 天的免费额度';
  }

  /// 商品不可售时说明原因。已下架与已归档只停新增购买，已有积分照常使用。
  String _statusText(String status) => switch (status) {
    'NOT_CONFIGURED' => '商品还没有配置，暂时不能购买。',
    'CONFIGURING' => '商品正在配置，暂时不能购买。',
    'PENDING' => '商品正在审核，暂时不能购买。',
    'ACTION_REQUIRED' => '商品还需要商户处理，暂时不能购买。',
    'DISABLED' => '商品已下架，已有积分仍可使用。',
    'TERMINATED' => '商品已归档，已有积分仍可使用。',
    _ => '暂时不能购买。',
  };
}
