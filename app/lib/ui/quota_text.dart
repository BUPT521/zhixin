import 'format.dart';

/// 嵌入额度的相对显示：已用占比与“已用 / 每日上限 token”。
///
/// 嵌入按原始 token 一比一记账，不按计费权重折算，也不能用购买的积分支付，
/// 所以这里不出现积分单位。上限缺失或不大于 0 时只报已用 token，不凭缺失的
/// 上限编一个百分比；有上限时百分比取整，已用不为 0 时最低显示 1%，避免明明
/// 用了一点却显示成 0%；并发请求可能让已用超过上限，这时照实显示超过 100%。
String embeddingQuotaText({required int usedTokens, int? dailyTokens}) {
  final used = usedTokens < 0 ? 0 : usedTokens;
  final limit = dailyTokens ?? 0;
  if (limit <= 0) {
    return '嵌入今日已用 ${groupDigits(used)} token；暂时读不到每日上限。';
  }
  final rounded = (used * 100 / limit).round();
  final percent = used > 0 && rounded < 1 ? 1 : rounded;
  return '嵌入今日已用 $percent% · ${groupDigits(used)} / '
      '${groupDigits(limit)} token';
}

/// 聊天积分的当日视图：今天已经从积分扣了多少、余额副本里还剩多少。
///
/// 服务端没有开通收款时不返回这两个数，调用方按空串处理、不显示这一行；两个数
/// 只给一个时同样不显示，避免把缺失的一项写成零。核销只在当天用量超过免费额度
/// 之后发生，所以当天没有超额时已扣积分是 0，这一行写成“还没有从积分扣除”。
String pointsQuotaText({
  required int? chargedPoints,
  required int? remainingPoints,
}) {
  final charged = chargedPoints;
  final remaining = remainingPoints;
  if (charged == null || remaining == null) return '';
  final left = '剩余 ${groupDigits(remaining)} 分';
  return charged <= 0
      ? '今天还没有从积分扣除，$left。'
      : '今天已从积分扣除 ${groupDigits(charged)} 分，$left。';
}
