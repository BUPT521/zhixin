/// 即刻收积分包：商品、档位、购买链接与余额，见 ADR-0067。
///
/// 价格、档位与发放的积分都来自「即刻收」小程序，客户端只展示与打开购买页，不参与
/// 定价；余额是即刻收一侧的客观数量，实际扣减发生在服务端核销时。
library;

class QuotaPurchaseOption {
  const QuotaPurchaseOption({
    required this.skuId,
    required this.displayName,
    required this.price,
    required this.quotaAmount,
  });

  /// 档位标识，按不透明标识回传，不解析内容。
  final String skuId;
  final String displayName;

  /// 展示价格，十进制字符串，单位元，由即刻收给出。
  final String price;

  /// 购买这一档增加的积分。
  final int quotaAmount;
}

class QuotaPurchaseProduct {
  const QuotaPurchaseProduct({
    required this.capabilityStatus,
    required this.billingMode,
    required this.quotaUnit,
    required this.options,
  });

  /// NOT_CONFIGURED、CONFIGURING、PENDING、ACTION_REQUIRED、ENABLED、DISABLED、
  /// TERMINATED；只有 ENABLED 表示允许新增购买。
  final String capabilityStatus;
  final String billingMode;
  final String quotaUnit;
  final List<QuotaPurchaseOption> options;

  /// 档位非空不代表可售，只有收费状态是 ENABLED 且卖的是积分时才允许购买。
  bool get purchasable => capabilityStatus == 'ENABLED' && quotaUnit == 'POINT';
}

class QuotaPurchaseLink {
  const QuotaPurchaseLink({
    required this.outRequestNo,
    required this.purchaseUrl,
    required this.expiresAt,
    this.skuId,
  });

  final String outRequestNo;

  /// 托管购买页入口，按不透明链接打开，不解析、不拼接。
  final String purchaseUrl;
  final DateTime expiresAt;
  final String? skuId;
}

class QuotaPurchaseOverview {
  const QuotaPurchaseOverview({
    required this.balancePoints,
    this.balanceUnavailable = false,
    this.tokensPerPoint,
    this.product,
    this.latestPurchase,
  });

  /// 即刻收一侧的剩余积分；没有配置商品时或余额暂时查不到时为 0。
  final int balancePoints;

  /// 余额暂时查不到或商品不是按积分出售时为真；此时 [balancePoints] 不可用，
  /// 界面提示“暂时查不到余额”，商品与档位照常显示（ADR-0073）。
  final bool balanceUnavailable;

  /// 一个积分覆盖的计费 token 数，用来把积分换算成 token；旧版服务端不返回时为
  /// null，这时界面只显示积分，不做换算。
  final int? tokensPerPoint;
  final QuotaPurchaseProduct? product;

  /// 最近一次仍然可用、没有过期的购买入口；服务端只回 ready 且未过期的一张。
  final QuotaPurchaseLink? latestPurchase;
}

class QuotaBalance {
  const QuotaBalance({
    required this.remaining,
    required this.total,
    required this.used,
  });

  /// 剩余积分，已排除预占；不能用 total-used 代替。
  final int remaining;
  final int total;
  final int used;
}

/// 购买或余额请求失败的种类；界面按它分别说明下一步，不把失败压成一句。
enum QuotaPurchaseFailureKind {
  /// 429：请求过于频繁，按服务端给的等待时间稍后再试。
  rateLimited,

  /// 409：商品已下架，或者现在出售的不是积分。
  conflict,

  /// 403：账号还没有确认任何登录方式。
  contactUnverified,

  /// 请求没有到达服务端，或连接中途断开。
  offline,

  /// 服务端暂时不可用。
  unavailable,
  unknown,
}

/// 一次购买或余额请求失败：只带界面需要的种类与等待时长。
///
/// 数据层的 [ServerProblem] 由账号服务翻译成这个值类型，界面不直接依赖数据层。
class QuotaPurchaseFailure implements Exception {
  const QuotaPurchaseFailure(this.kind, {this.retryAfter});

  final QuotaPurchaseFailureKind kind;

  /// 服务端要求等待的时长；只有 429 可能给出。
  final Duration? retryAfter;

  @override
  String toString() => 'QuotaPurchaseFailure($kind)';
}
