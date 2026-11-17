/// 相关度分数：0 到 1 的闭区间，越大越相关，1 表示最相关。
///
/// 检索有三类来源，每类原本各有一套分值范围：字面命中 100–112、语义命中
/// 10–13、跨次作答 60 附近。统一成这个类型之后，跨来源的比较与排序不再拿
/// 不同的尺子相减；各来源的原始分换算见 `domain/rules/score_weights.dart` 的
/// 权重表。关键词与语义候选由索引一次给出，分数是引擎的融合分，只在同一批
/// 索引结果内部比较。
///
/// 构造时一律把输入夹到 0–1，包括负数、大于 1 的值与 NaN，因此 `value`
/// 始终在值域内，调用方不需要再判一次。
class Score implements Comparable<Score> {
  /// 把任意实数夹到 0–1；NaN 视为 0，表示没有相关度。
  factory Score.clamp(double value) {
    if (value.isNaN || value <= 0) return zero;
    if (value >= 1) return one;
    return Score._(value);
  }

  const Score._(this.value);

  /// 下限：没有相关度。
  static const Score zero = Score._(0);

  /// 上限：最相关。
  static const Score one = Score._(1);

  final double value;

  /// 按数值比较，供排序使用；分数越高排得越前。
  @override
  int compareTo(Score other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is Score && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Score(${value.toStringAsFixed(3)})';
}
