import 'format.dart';

/// 分用途列出已结算用量。两类都折成积分并保留一位小数，避免各自取整之后与
/// 合计差一分；旧版服务端不返回折算比例时退回计费 token。
String modelUsageText({
  required int chatTokens,
  required int embeddingTokens,
  int? tokensPerPoint,
}) {
  final ratio = tokensPerPoint;
  if (ratio == null || ratio <= 0) {
    return '聊天 ${groupDigits(chatTokens)} · 嵌入 ${groupDigits(embeddingTokens)} 计费 token';
  }
  String points(int tokens) => (tokens / ratio).toStringAsFixed(1);
  return '聊天 ${points(chatTokens)} 分 · 嵌入 ${points(embeddingTokens)} 分';
}

/// 购买积分的当日视图：今天已经从积分扣了多少、余额副本里还剩多少。
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
