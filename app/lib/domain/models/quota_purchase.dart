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
    this.tokensPerPoint,
    this.product,
    this.latestPurchase,
  });

  /// 即刻收一侧的剩余积分；没有配置商品时为 0。
  final int balancePoints;

  /// 一个积分覆盖的计费 token 数，用来把积分换算成 token；旧版服务端不返回时为
  /// null，这时界面只显示积分，不做换算。
  final int? tokensPerPoint;
  final QuotaPurchaseProduct? product;
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
