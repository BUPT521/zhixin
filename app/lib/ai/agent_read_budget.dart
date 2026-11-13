/// 本轮材料读取与补搜共用的字数预算；默认五万字以内，先读先占。
class AgentReadBudget {
  AgentReadBudget([this.remaining = 48000]);

  int remaining;

  bool get exhausted => remaining <= 0;

  /// 取 [chars] 个字符的预算；不够时返回空并保持剩余量不变。
  bool take(int chars) {
    if (chars <= 0) return true;
    if (chars > remaining) return false;
    remaining -= chars;
    return true;
  }

  /// 本次最多能返回多少字符。
  int cap(int chars) => chars < remaining ? chars : remaining;
}
