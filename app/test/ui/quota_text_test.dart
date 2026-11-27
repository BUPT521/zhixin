import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/quota_text.dart';

/// 嵌入额度的相对显示：给出百分比与“已用 / 每日上限 token”，不出现积分单位。
void main() {
  test('嵌入用量和免费额度按同一积分比例显示', () {
    expect(
      embeddingQuotaText(
        usedTokens: 12345,
        dailyTokens: 200001,
        tokensPerPoint: 10000,
      ),
      '嵌入今日已用 2 积分 · 每日免费额度 20 积分',
    );
  });

  test('有上限时显示已用占比与已用、上限 token', () {
    expect(
      embeddingQuotaText(usedTokens: 12345, dailyTokens: 200000),
      '嵌入今日已用 6% · 12,345 / 200,000 token',
    );
    expect(
      embeddingQuotaText(usedTokens: 120000, dailyTokens: 200000),
      '嵌入今日已用 60% · 120,000 / 200,000 token',
    );
    expect(
      embeddingQuotaText(usedTokens: 0, dailyTokens: 200000),
      '嵌入今日已用 0% · 0 / 200,000 token',
    );
  });

  test('上限为 0 时只显示已用 token 与说明', () {
    expect(
      embeddingQuotaText(usedTokens: 12345, dailyTokens: 0),
      '嵌入今日已用 12,345 token；暂时读不到每日上限。',
    );
  });

  test('旧版服务端没有嵌入额度数值时按 0 处理', () {
    expect(
      embeddingQuotaText(usedTokens: 0, dailyTokens: null),
      '嵌入今日已用 0 token；暂时读不到每日上限。',
    );
  });

  test('用了一点但占比不到 1% 时显示 1%，超过上限时照实显示', () {
    expect(
      embeddingQuotaText(usedTokens: 1, dailyTokens: 200000),
      '嵌入今日已用 1% · 1 / 200,000 token',
    );
    expect(
      embeddingQuotaText(usedTokens: 250000, dailyTokens: 200000),
      '嵌入今日已用 125% · 250,000 / 200,000 token',
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
