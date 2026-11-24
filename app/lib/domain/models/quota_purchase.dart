class QuotaPurchaseOffer {
  const QuotaPurchaseOffer({
    required this.id,
    required this.amountFen,
    required this.tokens,
    required this.sandbox,
  });

  final String id;
  final int amountFen;
  final int tokens;
  final bool sandbox;
}

class QuotaPurchaseOrder {
  const QuotaPurchaseOrder({
    required this.id,
    required this.offer,
    required this.status,
    required this.payable,
  });

  final String id;
  final QuotaPurchaseOffer offer;
  final String status;
  final bool payable;
}

class QuotaPurchaseOverview {
  const QuotaPurchaseOverview({
    required this.balanceTokens,
    this.offer,
    this.latestOrder,
  });

  final int balanceTokens;
  final QuotaPurchaseOffer? offer;
  final QuotaPurchaseOrder? latestOrder;
}
