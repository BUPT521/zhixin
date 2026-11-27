import 'format.dart';

/// 分用途列出已结算用量，使用同一计费单位，避免各自折成整积分后相加。
String modelUsageText({
  required int chatTokens,
  required int embeddingTokens,
}) =>
    '聊天 ${groupDigits(chatTokens)} · 嵌入 ${groupDigits(embeddingTokens)} 计费 token';

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
