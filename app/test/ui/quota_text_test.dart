import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/quota_text.dart';

void main() {
  test('分开显示两种模型的已结算计费量', () {
    expect(
      modelUsageText(chatTokens: 12345, embeddingTokens: 6789),
      '聊天 12,345 · 嵌入 6,789 计费 token',
    );
  });

  test('积分当日视图写明今天已扣多少、还剩多少', () {
    expect(
      pointsQuotaText(chargedPoints: 5, remainingPoints: 27),
      '今天已从积分扣除 5 分，剩余 27 分。',
    );
    expect(
      pointsQuotaText(chargedPoints: 0, remainingPoints: 1000),
      '今天还没有从积分扣除，剩余 1,000 分。',
    );
  });

  test('只给一个数字时只写那一项，不整行藏掉', () {
    expect(
      pointsQuotaText(chargedPoints: 5, remainingPoints: null),
      '今天已从积分扣除 5 分。',
    );
    expect(
      pointsQuotaText(chargedPoints: 0, remainingPoints: null),
      '今天还没有从积分扣除。',
    );
    expect(
      pointsQuotaText(chargedPoints: null, remainingPoints: 27),
      '剩余 27 分。',
    );
  });

  test('没有开通收款时两个数字都是 null，不显示积分视图', () {
    expect(pointsQuotaText(chargedPoints: null, remainingPoints: null), '');
  });
}
