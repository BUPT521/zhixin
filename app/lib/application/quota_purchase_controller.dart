import 'dart:async';

import '../domain/models/quota_purchase.dart';
import '../domain/rules/uuid_v7.dart';

/// 一次余额查询的结论：余额是否比上次多、查到了多少。
class QuotaBalanceOutcome {
  const QuotaBalanceOutcome({required this.paid, required this.remaining});

  /// 这次查到的余额比上次多：刚打开的那张购买链接已经付过款。
  final bool paid;

  /// 查到的可用积分。
  final int remaining;
}

/// 额度购买的对账、刷新排队、幂等键与限流冷却。
///
/// 这四件事原先都写在 widget 的 State 里：付款是否到账要先和上一次余额比，回前台
/// 的补查要排队，同一次点击的重试要复用幂等键，429 之后要按服务端给的秒数禁用
/// 按钮。放在普通控制器里之后，面板只保留渲染、生命周期与拉起支付宝（A30）。
class QuotaPurchaseController {
  QuotaPurchaseController({required this.now, this.onChanged});

  /// 当前时间：购买链接的有效期与冷却到点都按它判断。
  final DateTime Function() now;

  /// 状态变化时通知面板重绘。
  void Function()? onChanged;

  void _changed() => onChanged?.call();

  // —— 概览 ——

  QuotaPurchaseOverview? _purchases;
  bool _loadFailed = false;
  String? _loadError;

  /// 已经读到的概览；还没读到或未登录时为空。
  QuotaPurchaseOverview? get purchases => _purchases;

  /// 概览读取失败时面板仍保留上一次的数据，并在上方说明与给出重试。
  bool get loadFailed => _loadFailed;

  String? get loadError => _loadError;

  void loaded(QuotaPurchaseOverview purchases) {
    _purchases = purchases;
    _loadFailed = false;
    _loadError = null;
    _changed();
  }

  void loadFailedWith(String message) {
    _loadFailed = true;
    _loadError = message;
    _changed();
  }

  // —— 一次性说明 ——

  String? _notice;

  /// 购买卡片下方的一次性说明；新的一次操作开始时清空。
  String? get notice => _notice;

  void setNotice(String? message) {
    if (_notice == message) return;
    _notice = message;
    _changed();
  }

  // —— 忙与刷新排队 ——

  bool _busy = false;

  /// 正在读概览、查余额或取购买链接。
  bool get busy => _busy;

  /// 开始一次请求；已经在忙时返回 false，调用方据此把这次刷新排队。
  bool begin() {
    if (_busy) return false;
    _busy = true;
    _changed();
    return true;
  }

  /// 结束一次请求，返回之后要不要补一次排队中的刷新。
  bool end() {
    _busy = false;
    final queued = _refreshQueued;
    _refreshQueued = false;
    _changed();
    return queued;
  }

  bool _refreshQueued = false;

  /// 忙的时候到来的一次刷新：记下来，等当前这次结束之后再补一次。
  void queueRefresh() => _refreshQueued = true;

  // —— 限流冷却 ——

  DateTime? _cooldownUntil;

  /// 429 之后按钮要禁用到的时刻；为空表示现在可以点。
  DateTime? get cooldownUntil => _cooldownUntil;

  bool get cooling => _cooldownUntil != null;

  /// 冷却还剩几秒，用于说明“请 N 秒后再试”；没有在冷却时为空。
  int? get cooldownSecondsLeft {
    final until = _cooldownUntil;
    if (until == null) return null;
    final left = until.difference(now()).inSeconds;
    return left <= 0 ? null : left;
  }

  /// 按服务端给的等待秒数禁用按钮；没有给出秒数时按 30 秒处理。
  void startCooldown(int seconds) {
    final wait = seconds <= 0 ? 1 : seconds;
    _cooldownUntil = now().add(Duration(seconds: wait));
    _changed();
  }

  /// 冷却到点：清掉并通知面板恢复可点。
  ///
  /// 由面板按剩余秒数排的那个定时器调用；不在这里比较时钟，界面用例推进的是
  /// 测试时钟，与墙上时间不一定是同一个。
  void clearCooldown() {
    if (_cooldownUntil == null) return;
    _cooldownUntil = null;
    _changed();
  }

  // —— 幂等键与购买链接 ——

  ({QuotaPurchaseOption option, String requestNo})? _pendingPurchase;
  QuotaPurchaseLink? _failedOpenLink;
  QuotaPurchaseLink? _lastLink;
  String? _paidRequestNo;

  /// 同一次点击失败之后可以重试的那一项；没有可重试的失败时为空。
  ({QuotaPurchaseOption option, String requestNo})? get pendingPurchase =>
      _pendingPurchase;

  /// 购买链接已经取到但没能拉起支付宝时留下来的那一张，供“复制链接”与“重试打开”。
  QuotaPurchaseLink? get failedOpenLink => _failedOpenLink;

  /// 本次打开的购买链接，用来判断回到前台时它是否还在有效期内。
  QuotaPurchaseLink? get lastLink => _lastLink;

  /// 已经付过款的购买链接编号：它不再作为“继续上次购买”的入口。
  String? get paidRequestNo => _paidRequestNo;

  /// 这一次点击的幂等键：失败后重试沿用 [retryOf]，换一次点击生成新键（ADR-0074）。
  String requestNo({String? retryOf}) => retryOf ?? newUuidV7();

  /// 记下这一次点击，失败时“重试”据此复用同一个幂等键。
  void rememberPendingPurchase(QuotaPurchaseOption option, String requestNo) {
    _pendingPurchase = (option: option, requestNo: requestNo);
    _changed();
  }

  void clearPendingPurchase() {
    _pendingPurchase = null;
    _changed();
  }

  /// 开始一次购买：清掉上一次的说明、待重试项与没能打开的链接。
  void beginPurchase() {
    _notice = null;
    _pendingPurchase = null;
    _failedOpenLink = null;
  }

  void rememberFailedOpenLink(QuotaPurchaseLink? link) {
    _failedOpenLink = link;
    _changed();
  }

  void rememberLastLink(QuotaPurchaseLink? link) {
    _lastLink = link;
  }

  /// 一张链接已经付过款：它不再提供“继续上次购买”的入口。
  void markLinkPaid(QuotaPurchaseLink? link) {
    final requestNo = link?.outRequestNo;
    if (requestNo == null || requestNo.isEmpty) return;
    _paidRequestNo = requestNo;
  }

  /// 可以“继续上次购买”的那一张：同一个档位、没有过期、链接非空，而且还没有付过款。
  ///
  /// 付过款的那一张再打开只会让人以为要再付一次（ADR-0074）。
  QuotaPurchaseLink? latestLink() {
    final purchases = _purchases;
    final latest = purchases?.latestPurchase;
    if (latest == null || latest.purchaseUrl.trim().isEmpty) return null;
    if (!latest.expiresAt.isAfter(now())) return null;
    if (latest.outRequestNo == _paidRequestNo) return null;
    final sku = latest.skuId;
    if (sku == null) return null;
    final product = purchases?.product;
    if (product == null) return null;
    return product.options.any((option) => option.skuId == sku) ? latest : null;
  }

  // —— 对账 ——

  /// 把一次余额查询的结果并进概览，并判断是否到账。
  ///
  /// 只有先前读到过余额、这次又变多了才算到账：先前读不到时没有对照，不能直接
  /// 说“已到账”；[quiet] 为真时是后台补查，不覆盖已有的说明。
  QuotaBalanceOutcome applyBalance(
    QuotaBalance balance, {
    required bool quiet,
  }) {
    final purchases = _purchases;
    final before = purchases == null || purchases.balanceUnavailable
        ? null
        : purchases.balancePoints;
    final paid = before != null && balance.remaining > before;
    if (purchases != null) {
      _purchases = QuotaPurchaseOverview(
        balancePoints: balance.remaining,
        tokensPerPoint: purchases.tokensPerPoint,
        product: purchases.product,
        latestPurchase: purchases.latestPurchase,
      );
    }
    if (paid) {
      // 增加的积分来自刚打开的那张购买链接：它已经付过款，不再作为继续购买的
      // 入口，否则会重新打开一张已经支付过的页面。
      _notice = '已到账，可用积分 ${balance.remaining} 分。';
    } else if (before == null) {
      _notice = '已刷新，可用积分 ${balance.remaining} 分。';
    } else if (!quiet) {
      _notice = '还没有查到新的积分，可以稍后再刷新一次。';
    }
    _changed();
    return QuotaBalanceOutcome(paid: paid, remaining: balance.remaining);
  }

  // —— 回到前台之后的补查 ——

  bool _awaitingReturn = false;
  Timer? _resumeTimer;

  /// 已经打开购买页，等用户回到知新之后刷新余额。
  bool get awaitingReturn => _awaitingReturn;

  void setAwaitingReturn(bool value) {
    _awaitingReturn = value;
  }

  /// 回到前台补查之后余额没有变化时再查一次，因为支付宝的到账通知可能晚几秒。
  void scheduleResumeRefresh() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 6), () {
      _resumeTimer = null;
      _changed();
      onResumeRefresh?.call();
    });
  }

  /// 补查到点时的动作；面板据此再查一次余额。
  void Function()? onResumeRefresh;

  void cancelResumeRefresh() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void dispose() {
    cancelResumeRefresh();
    _cooldownUntil = null;
    onChanged = null;
    onResumeRefresh = null;
  }

  /// 切了账号或实例：清掉等待返回的标记、补查与待重试项。
  void staleIdentity() {
    _awaitingReturn = false;
    _pendingPurchase = null;
    _failedOpenLink = null;
    cancelResumeRefresh();
  }
}
