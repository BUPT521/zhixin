import 'format.dart';

/// 嵌入用量和免费额度使用账号页统一的积分比例。比例缺失时展示 token。
String embeddingQuotaText({
  required int usedTokens,
  int? dailyTokens,
  int? tokensPerPoint,
}) {
  final used = usedTokens < 0 ? 0 : usedTokens;
  final limit = dailyTokens ?? 0;
  if (tokensPerPoint != null && tokensPerPoint > 0) {
    final usage = '嵌入今日已用 ${quotaPoints(used, tokensPerPoint)} 积分';
    if (limit <= 0) return usage;
    return '$usage · 每日免费额度 ${freeQuotaPoints(limit, tokensPerPoint)} 积分';
  }
  if (limit <= 0) {
    return '嵌入今日已用 ${groupDigits(used)} token；暂时读不到每日上限。';
  }
  final rounded = (used * 100 / limit).round();
  final percent = used > 0 && rounded < 1 ? 1 : rounded;
  return '嵌入今日已用 $percent% · ${groupDigits(used)} / '
      '${groupDigits(limit)} token';
}

/// 模型积分的当日视图：今天已经从积分扣了多少、余额副本里还剩多少。
///
/// 两个数字各按自己的可用性显示：服务端没有开通收款时两个都不给，调用方按空串
/// 处理、不显示这一行；开通了收款但余额副本还没建好或账号还没有副本时只给已扣
/// 积分，这一行仍然要说明今天扣了多少，不因为缺少剩余而整行藏掉。核销只在当天
/// 用量超过免费额度之后发生，所以当天没有超额时已扣积分是 0，这一行写成“还没有
/// 从积分扣除”。
String pointsQuotaText({
  required int? chargedPoints,
  required int? remainingPoints,
}) {
  final charged = chargedPoints;
  final remaining = remainingPoints;
  if (charged == null && remaining == null) return '';
  final left = remaining == null ? '' : '剩余 ${groupDigits(remaining)} 分';
  if (charged == null) return '$left。';
  final used = charged <= 0
      ? '今天还没有从积分扣除'
      : '今天已从积分扣除 ${groupDigits(charged)} 分';
  return left.isEmpty ? '$used。' : '$used，$left。';
}
