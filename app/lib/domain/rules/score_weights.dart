import '../models/score.dart';

/// 换算权重时用的旧量纲上界：字面命中 100 + 10 + 2，其中 10 是命中位置分，
/// 2 是题目加分（作答加 1、材料页与消息不加）。
const double _legacyScale = 112;

/// 检索打分的显式权重表：每类来源先把原始分归一化到 0–1，再乘该来源的权重。
///
/// 旧代码里同一相关度有七套量纲，跨来源比较实际在比不同的尺子。权重表把
/// 每类来源的旧量纲上界除以 [_legacyScale] 作为权重，于是统一后的分数范围
/// 仍是 0–1，跨来源的先后也与旧代码一致：字面命中（1.0）在前，跨次作答
/// （60/112 ≈ 0.54）居中，关键词命中（15/112）与语义命中（13/112）在后。
///
/// 字面命中在合并时另有“原样命中优先”的规则，不靠数值大小排在最前；权重
/// 只负责同一来源内部保持原有顺序、不同来源之间可以比较大小。
enum ScoreSource {
  /// 字面命中：旧量纲 100–112，用户输入的整句出现在原文里，取满权重。
  literal(label: '字面命中', rawLower: 100, rawUpper: 112, weight: 1),

  /// 关键词命中：FTS5 的 bm25 相关度换成 14 + relevance/(1 + relevance)，
  /// 旧量纲 14–15。
  keyword(
    label: '关键词命中',
    rawLower: 14,
    rawUpper: 15,
    weight: 15 / _legacyScale,
  ),

  /// 语义命中：余弦距离换成 10 + (1 - 距离) * 3，旧量纲 10–13。
  semantic(
    label: '语义命中',
    rawLower: 10,
    rawUpper: 13,
    weight: 13 / _legacyScale,
  ),

  /// 跨次作答：同一线程里旧量纲从 60 起、每往后一条减 0.1。它是用户回看
  /// “上次、后来”时补齐的作答，排在关键词与语义命中之前。
  crossSession(
    label: '跨次作答',
    rawLower: 0,
    rawUpper: 60,
    weight: 60 / _legacyScale,
  );

  const ScoreSource({
    required this.label,
    required this.rawLower,
    required this.rawUpper,
    required this.weight,
  });

  /// 界面上说明这条命中来自哪一路时用的名称。
  final String label;

  /// 旧量纲的下界，归一化时减去它。
  final double rawLower;

  /// 旧量纲的上界，归一化时作为量程。
  final double rawUpper;

  /// 归属到统一 0–1 分数时乘的权重，等于旧量纲上界除以 [_legacyScale]。
  final double weight;

  /// 把一个落在旧量纲里的原始分换算成统一分数。
  ///
  /// 原始分先按 [rawLower] 到 [rawUpper] 归一化到 0–1，再乘 [weight]；
  /// 超出量程的值由 [Score.clamp] 夹住。同一来源的原始分越高，结果越大，
  /// 顺序因此与旧量纲一致。
  Score normalize(double raw) {
    final span = rawUpper - rawLower;
    if (span <= 0) return Score.zero;
    final unit = ((raw - rawLower) / span).clamp(0.0, 1.0);
    return Score.clamp(unit * weight);
  }
}

/// 字面命中的分数：命中位置越靠前越高，题目加 2、作答加 1（沿用旧量纲的
/// 类别加分），没有找到位置时为 0。
///
/// [offset] 是命中起始位置（从 1 开始），[textLength] 是参与匹配的原文长度。
Score literalMatchScore({
  required int offset,
  required int textLength,
  int kindPriority = 0,
}) {
  if (offset <= 0) return Score.zero;
  final length = textLength <= 0 ? 1 : textLength;
  final position = (1 - (offset - 1) / length) * 10;
  return ScoreSource.literal.normalize(100 + position + kindPriority);
}

/// 关键词命中的分数：FTS5 给更相关的结果更小的 bm25 值，取反后按
/// relevance/(1 + relevance) 映射回旧量纲 14–15。
Score keywordMatchScore(num? bm25Rank) {
  final relevance = -(bm25Rank ?? 0);
  if (relevance <= 0) return ScoreSource.keyword.normalize(14);
  return ScoreSource.keyword.normalize(14 + relevance / (1 + relevance));
}

/// 语义命中的分数：余弦距离 0–1，越接近 1 越相关，对应旧量纲 10–13。
Score semanticMatchScore(double distance) {
  final similarity = (1 - distance).clamp(0.0, 1.0);
  return ScoreSource.semantic.normalize(10 + similarity * 3);
}

/// 跨次作答的分数：同一线程里越靠前越高，对应旧量纲 60 起、每条减 0.1。
Score crossSessionScore(int index) {
  final raw = 60 - index * 0.1;
  return ScoreSource.crossSession.normalize(raw < 0 ? 0 : raw);
}
