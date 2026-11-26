import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/account_service.dart';
import '../domain/models/quota_purchase.dart';
import '../domain/rules/uuid_v7.dart';
import 'format.dart';
import 'theme.dart';
import 'workspace_widgets.dart';

/// “模型额度”一节：展示即刻收的积分余额与档位，按托管购买页完成付款。
///
/// 客户端不参与定价，也不凭返回页放行：点购买只取一张购买链接交给支付宝，回到知新
/// 之后重新查余额；扣减发生在服务端核销，见 ADR-0067。每次点击带一个幂等键，同一次
/// 点击失败后的重试沿用原来的键，换一次点击换新键，避免重试时重复创单（ADR-0074）。
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

  /// 概览读取失败时保留上一次的数据，并在上方说明与给出重试，不把整段藏起来。
  bool _loadFailed = false;
  String? _loadError;

  /// 已经打开购买页，等用户回到知新之后刷新余额。外部应用拉起时 launcher 立刻
  /// 返回，付款是否完成只能靠回到前台这一个信号判断。
  bool _awaitingReturn = false;

  /// 只有先进过后台、再回到前台才算“从支付宝回来”；启动与页面切换的 resumed
  /// 不刷新余额，避免每切一次页就多查一次。
  bool _paused = false;

  /// 刷新途中又来了一个刷新请求（例如回到前台时上一次查询还没结束）：记下来，
  /// 等当前这次结束之后再补一次，而不是丢掉。
  bool _refreshQueued = false;

  /// 回到前台查一次之后余额没有变化时安排的补查，离开页面时取消。
  Timer? _resumeTimer;

  /// 429 之后按钮要禁用到的时刻；定时器到点清空，界面随之恢复可点。
  Timer? _cooldownTimer;

  /// 同一次点击的幂等键：失败后重试沿用这里记下的键，换一次点击生成新键。
  ({QuotaPurchaseOption option, String requestNo})? _pendingPurchase;

  /// 购买链接已经取到但没能拉起支付宝时留下来，供“复制链接”与“重试打开”使用。
  QuotaPurchaseLink? _failedOpenLink;

  /// 本次打开的购买链接，用来判断回到前台时它是否还在有效期内。
  QuotaPurchaseLink? _lastLink;

  /// 已经付过款的购买链接编号：余额在打开它之后增加了，这张链接不再作为“继续上次
  /// 购买”的入口，免得把用户带回一张已经支付过的页面（ADR-0074）。
  String? _paidRequestNo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resumeTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _paused = true;
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final cameBack = _paused;
    _paused = false;
    if (!cameBack || !_awaitingReturn) return;
    _awaitingReturn = false;
    unawaited(_refreshAfterReturn());
  }

  Future<void> _load() async {
    try {
      final purchases = await widget.account.quotaPurchases();
      if (!mounted) return;
      setState(() {
        _purchases = purchases;
        _loadFailed = false;
        _loadError = null;
      });
    } on QuotaPurchaseFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loadError = _loadFailureText(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loadError = '暂时无法读取购买信息，请稍后重试。';
      });
    }
  }

  /// 概览读取失败的一句说明；429 时把服务端给的等待秒数写出来。
  String _loadFailureText(QuotaPurchaseFailure error) {
    final waited = error.retryAfter?.inSeconds;
    return switch (error.kind) {
      QuotaPurchaseFailureKind.rateLimited when waited != null =>
        '暂时无法读取购买信息，请求过于频繁，请 $waited 秒后重试。',
      QuotaPurchaseFailureKind.rateLimited => '暂时无法读取购买信息，请求过于频繁，请稍后重试。',
      QuotaPurchaseFailureKind.offline => '暂时无法读取购买信息，网络不可用，请检查网络后重试。',
      QuotaPurchaseFailureKind.unavailable => '暂时无法读取购买信息，服务端暂时不可用，请稍后重试。',
      _ => '暂时无法读取购买信息，请稍后重试。',
    };
  }

  /// 回到前台之后先查一次余额；余额没有变化且链接还没过期时，再安排一次补查，
  /// 因为支付宝的到账通知可能比回到前台晚几秒。
  Future<void> _refreshAfterReturn() async {
    final before = _purchases;
    final link = _lastLink ?? _purchases?.latestPurchase;
    final refreshed = await _refreshBalance(quiet: true);
    if (!mounted || !refreshed || before == null) return;
    final after = _purchases;
    if (after == null || after.balanceUnavailable) return;
    final changed = after.balancePoints != before.balancePoints;
    final expired = link != null && !link.expiresAt.isAfter(DateTime.now());
    if (changed || expired) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) unawaited(_refreshBalance(quiet: true));
    });
  }

  /// 查一次余额；[quiet] 为真时是后台补查，不覆盖已有的说明。
  ///
  /// 正在刷新时把这次请求排队，当前一次结束后再补一次，不直接丢掉。
  Future<bool> _refreshBalance({bool quiet = false}) async {
    if (_busy) {
      _refreshQueued = true;
      return false;
    }
    final epoch = widget.account.identityEpoch;
    setState(() {
      _busy = true;
      if (!quiet) _notice = null;
    });
    var refreshed = false;
    try {
      final balance = await widget.account.quotaBalance();
      if (!mounted || widget.account.identityEpoch != epoch) return false;
      final purchases = _purchases;
      final before = purchases == null || purchases.balanceUnavailable
          ? null
          : purchases.balancePoints;
      refreshed = true;
      // 只有先前读到过余额、这次又变多了才算到账：先前读不到时没有对照，不能
      // 直接说“已到账”。
      final paid = before != null && balance.remaining > before;
      setState(() {
        if (purchases == null) return;
        _purchases = QuotaPurchaseOverview(
          balancePoints: balance.remaining,
          tokensPerPoint: purchases.tokensPerPoint,
          product: purchases.product,
          latestPurchase: purchases.latestPurchase,
        );
        if (paid) {
          // 增加的积分来自刚打开的那张购买链接：它已经付过款，不再作为继续购买的
          // 入口，否则会重新打开一张已经支付过的页面。
          _paidRequestNo =
              _lastLink?.outRequestNo ?? purchases.latestPurchase?.outRequestNo;
          _notice = '已到账，可用积分 ${balance.remaining} 分。';
        } else if (before == null) {
          _notice = '已刷新，可用积分 ${balance.remaining} 分。';
        } else if (!quiet) {
          _notice = '还没有查到新的积分，可以稍后再刷新一次。';
        }
      });
      if (paid) await widget.onPaid();
    } on AccountSignedOut {
      if (mounted) {
        _awaitingReturn = false;
        setState(() => _notice = '登录状态已经变化，请重新登录之后再查询余额。');
      }
    } on QuotaPurchaseFailure catch (error) {
      if (!mounted) return false;
      final waited = error.retryAfter?.inSeconds;
      setState(
        () => _notice =
            error.kind == QuotaPurchaseFailureKind.rateLimited && waited != null
            ? '余额查询过于频繁，请 $waited 秒后再试。'
            : '暂时无法查询余额，请稍后再试。',
      );
    } catch (_) {
      if (mounted) setState(() => _notice = '暂时无法查询余额，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
      _runQueuedRefresh();
    }
    return refreshed;
  }

  /// 忙的时候到来的一次刷新被记下来了：当前这次结束后补上，不直接丢掉。
  void _runQueuedRefresh() {
    if (!mounted || !_refreshQueued) return;
    _refreshQueued = false;
    unawaited(_refreshBalance(quiet: true));
  }

  /// 点一个档位：取一张新的购买链接并交给支付宝。
  ///
  /// [requestNo] 只由同一次点击失败后的重试传入；普通点击不传，这里生成新键。
  Future<void> _buy(QuotaPurchaseOption option, {String? requestNo}) async {
    if (_busy || _cooldownTimer != null) return;
    final epoch = widget.account.identityEpoch;
    final key = requestNo ?? newUuidV7();
    setState(() {
      _busy = true;
      _notice = null;
      _pendingPurchase = null;
      _failedOpenLink = null;
    });
    try {
      final link = await widget.account.quotaPurchaseLink(
        skuId: option.skuId,
        clientRequestNo: key,
      );
      if (!mounted) return;
      if (widget.account.identityEpoch != epoch) {
        _staleIdentity();
        return;
      }
      _lastLink = link;
      await _openLink(link, epoch: epoch);
    } on AccountSignedOut {
      if (mounted) _staleIdentity();
    } on QuotaPurchaseFailure catch (error) {
      if (!mounted) return;
      if (widget.account.identityEpoch != epoch) {
        _staleIdentity();
        return;
      }
      _handlePurchaseProblem(error, option: option, requestNo: key);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice = '暂时无法获取购买链接，请稍后重试。';
        _pendingPurchase = (option: option, requestNo: key);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _runQueuedRefresh();
    }
  }

  /// 按失败的类型分别说明；429 记下等待时间并禁用按钮到那时，409、403 与离线
  /// 各有下一步，不压成同一句话。
  void _handlePurchaseProblem(
    QuotaPurchaseFailure error, {
    required QuotaPurchaseOption option,
    required String requestNo,
  }) {
    if (error.kind == QuotaPurchaseFailureKind.rateLimited) {
      final seconds = error.retryAfter?.inSeconds;
      _startCooldown(seconds ?? 30);
      setState(
        () => _notice = seconds == null
            ? '请求过于频繁，请稍后再试。'
            : '请求过于频繁，请 $seconds 秒后再试。',
      );
      return;
    }
    final transient = switch (error.kind) {
      QuotaPurchaseFailureKind.offline => true,
      QuotaPurchaseFailureKind.unavailable => true,
      _ => false,
    };
    final text = switch (error.kind) {
      QuotaPurchaseFailureKind.conflict => '商品已经下架，或者现在出售的不是积分，暂时不能购买。',
      QuotaPurchaseFailureKind.contactUnverified =>
        '请先在账号页确认一种登录方式，确认之后才能购买积分。',
      QuotaPurchaseFailureKind.offline => '网络不可用，请检查网络后重试。',
      QuotaPurchaseFailureKind.unavailable => '服务端暂时无法查询即刻收商品，请稍后再试。',
      _ => '暂时无法获取购买链接，请稍后重试。',
    };
    setState(() {
      _notice = text;
      _pendingPurchase = transient
          ? (option: option, requestNo: requestNo)
          : null;
    });
  }

  /// 用外部应用打开购买页；没能拉起支付宝时保留链接，供复制与重试打开使用。
  Future<void> _openLink(QuotaPurchaseLink link, {required int epoch}) async {
    final url = link.purchaseUrl.trim();
    if (url.isEmpty) {
      setState(() => _notice = '服务端没有返回可以打开的购买页，请稍后重试。');
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    // 拉起支付宝的往返里用户可能已经切了账号：这次结果不属于当前身份。
    if (widget.account.identityEpoch != epoch) {
      _staleIdentity();
      return;
    }
    if (opened) {
      _awaitingReturn = true;
      setState(() => _notice = '在支付宝里完成付款后回到知新，这里会重新查一次余额。');
      return;
    }
    setState(() {
      _notice = '没能打开支付宝，确认已安装后重试。';
      _failedOpenLink = link;
    });
  }

  /// 打开上次没有过期的购买链接；打开之前先核对有效期，过期就重新读一次概览。
  /// 已经付过款的那一张不再提供，避免重新打开一张支付过的页面。
  Future<void> _openLatest() async {
    if (_busy) return;
    var purchases = _purchases;
    if (purchases == null) return;
    var latest = _latestLink(purchases);
    if (latest == null) {
      if (purchases.latestPurchase?.outRequestNo == _paidRequestNo) {
        setState(() => _notice = '上次的购买已经到账，不再重复打开同一张购买页。');
        return;
      }
      await _load();
      if (!mounted) return;
      purchases = _purchases;
      latest = purchases == null ? null : _latestLink(purchases);
      if (latest == null) {
        setState(() => _notice = '上次的购买链接已经过期，请重新选择档位购买。');
        return;
      }
    }
    final epoch = widget.account.identityEpoch;
    final link = latest;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _lastLink = link;
      await _openLink(link, epoch: epoch);
    } finally {
      if (mounted) setState(() => _busy = false);
      _runQueuedRefresh();
    }
  }

  Future<void> _reopenLink(QuotaPurchaseLink link) async {
    if (_busy) return;
    final epoch = widget.account.identityEpoch;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _openLink(link, epoch: epoch);
    } finally {
      if (mounted) setState(() => _busy = false);
      _runQueuedRefresh();
    }
  }

  /// 没能打开支付宝时把链接复制出去，用户可以自己粘到浏览器里打开。
  Future<void> _copyLink() async {
    final link = _failedOpenLink;
    if (link == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: link.purchaseUrl));
      if (mounted) setState(() => _notice = '购买链接已复制，可以粘贴到浏览器里打开。');
    } catch (_) {
      if (mounted) setState(() => _notice = '复制购买链接失败，可以稍后再试。');
    }
  }

  /// 429 之后禁用按钮到服务端给的等待时间；没有给出秒数时按 30 秒处理。
  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(Duration(seconds: seconds <= 0 ? 1 : seconds), () {
      if (!mounted) return;
      setState(() => _cooldownTimer = null);
    });
  }

  /// 切了账号或实例：清掉等待返回的标记，提示重新登录，不把旧账号的链接当结果。
  void _staleIdentity() {
    _awaitingReturn = false;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    setState(() => _notice = '登录状态已经变化，请重新登录之后再购买。');
  }

  /// 同一次点击重试时复用的动作；没有可重试的失败时为空。
  VoidCallback? get _retryAction {
    final pending = _pendingPurchase;
    if (pending != null) {
      return () => _buy(pending.option, requestNo: pending.requestNo);
    }
    final link = _failedOpenLink;
    if (link != null) return () => _reopenLink(link);
    return null;
  }

  /// 可以“继续上次购买”的入口：同一个档位、没有过期、链接非空，而且这张链接
  /// 还没有付过款。付过款的那一张再打开只会让人以为要再付一次（ADR-0074）。
  QuotaPurchaseLink? _latestLink(QuotaPurchaseOverview purchases) {
    final latest = purchases.latestPurchase;
    if (latest == null || latest.purchaseUrl.trim().isEmpty) return null;
    if (!latest.expiresAt.isAfter(DateTime.now())) return null;
    if (latest.outRequestNo == _paidRequestNo) return null;
    final sku = latest.skuId;
    if (sku == null) return null;
    final product = purchases.product;
    if (product == null) return null;
    return product.options.any((option) => option.skuId == sku) ? latest : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final purchases = _purchases;
    if (purchases == null) {
      if (!_loadFailed) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: theme.space.sm),
        child: InlineNotice(
          message: _loadError ?? '暂时无法读取购买信息，请稍后重试。',
          onRetry: _busy ? null : _load,
        ),
      );
    }
    final product = purchases.product;
    final options = product?.purchasable == true
        ? product!.options
        : const <QuotaPurchaseOption>[];
    final hasPoints =
        !purchases.balanceUnavailable && purchases.balancePoints > 0;
    if (product == null &&
        !hasPoints &&
        !purchases.balanceUnavailable &&
        !_loadFailed) {
      return const SizedBox.shrink();
    }
    final enabled = !_busy && widget.enabled && _cooldownTimer == null;
    final tokensPerPoint = purchases.tokensPerPoint;
    final ratio = tokensPerPoint != null && tokensPerPoint > 0
        ? tokensPerPoint
        : null;
    final daily = widget.dailyTokens;
    final latest = _latestLink(purchases);
    final retry = _retryAction;
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
    // 一张卡片从余额说到档位：余额与刷新在上，档位各占一行、价格与积分只写一次，
    // 购买按钮落在自己那一行；说明与重试留在这张卡片的下方，不再和档位按钮挤在
    // 同一个 Wrap 里。
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loadFailed)
                InlineNotice(
                  message: _loadError ?? '暂时无法读取购买信息，请稍后重试。',
                  onRetry: _busy ? null : _load,
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('购买积分', style: theme.text.titleSmall),
                        SizedBox(height: theme.space.xs),
                        Text(
                          purchases.balanceUnavailable
                              ? '暂时查不到余额，稍后再试。'
                              : '可用积分 ${groupDigits(purchases.balancePoints)} 分',
                          style: theme.text.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: theme.space.sm),
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    size: forui.FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: enabled ? () => _refreshBalance() : null,
                    prefix: const Icon(FLucideIcons.refreshCw),
                    child: const Text('刷新余额'),
                  ),
                ],
              ),
              if (legend != null)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs),
                  child: Text(
                    legend,
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(
                  '积分跨日保留；每轮结束先扣当天免费额度，再扣积分。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (product != null && !product.purchasable)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs),
                  child: Text(_statusText(product.capabilityStatus)),
                ),
              if (options.isNotEmpty) ...[
                const _Rule(),
                for (final option in options)
                  _optionRow(
                    option,
                    enabled: enabled,
                    ratio: ratio,
                    daily: daily,
                  ),
              ],
              if (latest != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: EdgeInsets.only(top: theme.space.sm),
                    child: forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      size: forui.FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: enabled ? _openLatest : null,
                      child: const Text('继续上次购买'),
                    ),
                  ),
                ),
              if (_notice case final notice?)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.sm),
                  child: Text(notice, style: theme.text.bodySmall),
                ),
              if (_busy)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.sm),
                  child: Row(
                    children: [
                      const forui.FCircularProgress(size: .xs),
                      SizedBox(width: theme.space.sm),
                      Text('正在与支付宝核对…', style: theme.text.bodySmall),
                    ],
                  ),
                ),
              if (retry != null || _failedOpenLink != null)
                Padding(
                  padding: EdgeInsets.only(top: theme.space.xs),
                  child: Wrap(
                    spacing: theme.space.sm,
                    runSpacing: theme.space.sm,
                    children: [
                      if (retry != null)
                        forui.FButton(
                          variant: forui.FButtonVariant.ghost,
                          size: forui.FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: enabled ? retry : null,
                          child: const Text('重试'),
                        ),
                      if (_failedOpenLink != null)
                        forui.FButton(
                          variant: forui.FButtonVariant.ghost,
                          size: forui.FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: _busy ? null : _copyLink,
                          child: const Text('复制链接'),
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

  /// 一个档位一行：名称与价格在同一行，发放积分与换算在下面，右侧是这一档的
  /// 购买按钮。价格、积分与按钮不再各列一遍。
  Widget _optionRow(
    QuotaPurchaseOption option, {
    required bool enabled,
    required int? ratio,
    required int? daily,
  }) {
    final theme = context.zhixin;
    final conversion = ratio == null
        ? null
        : _conversion(option.quotaAmount * ratio, daily);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        option.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text.titleSmall,
                      ),
                    ),
                    SizedBox(width: theme.space.sm),
                    Text('¥${option.price}', style: theme.text.titleSmall),
                  ],
                ),
                SizedBox(height: theme.space.xs),
                Text(
                  '${groupDigits(option.quotaAmount)} 分',
                  style: theme.text.bodyMedium,
                ),
                if (conversion != null)
                  Text(
                    conversion,
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(width: theme.space.md),
          forui.FButton(
            mainAxisSize: MainAxisSize.min,
            semanticsLabel: '购买 ${option.displayName}',
            onPress: enabled ? () => _buy(option) : null,
            child: const Text('购买'),
          ),
        ],
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

/// 购买卡片里的分隔线：与卡片内容同宽，上下各留一档。
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.space.sm),
      child: SizedBox(
        height: 1,
        child: ColoredBox(color: theme.colors.outlineVariant),
      ),
    );
  }
}
