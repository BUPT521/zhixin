import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/score.dart';

void main() {
  test('构造时把输入夹到 0–1', () {
    expect(Score.clamp(-3).value, 0);
    expect(Score.clamp(0).value, 0);
    expect(Score.clamp(0.42).value, 0.42);
    expect(Score.clamp(1).value, 1);
    expect(Score.clamp(9).value, 1);
  });

  test('NaN 视为没有相关度', () {
    expect(Score.clamp(double.nan), Score.zero);
    expect(Score.clamp(double.nan).value, 0);
  });

  test('按数值比较大小', () {
    expect(Score.clamp(0.8).compareTo(Score.clamp(0.3)), greaterThan(0));
    expect(Score.clamp(0.3).compareTo(Score.clamp(0.8)), lessThan(0));
    expect(Score.clamp(0.8).compareTo(Score.clamp(0.8)), 0);
    expect(Score.zero.compareTo(Score.one), lessThan(0));
  });

  test('同一数值相等且哈希一致，不同数值不相等', () {
    expect(Score.clamp(0.5), Score.clamp(0.5));
    expect(Score.clamp(0.5).hashCode, Score.clamp(0.5).hashCode);
    expect(Score.clamp(0.5) == Score.clamp(0.6), isFalse);
    expect(Score.clamp(-1), Score.zero);
    expect(Score.clamp(2), Score.one);
  });

  test('文本形式带三位小数，便于日志与断言阅读', () {
    expect(Score.clamp(0.5).toString(), 'Score(0.500)');
    expect(Score.zero.toString(), 'Score(0.000)');
  });
}
