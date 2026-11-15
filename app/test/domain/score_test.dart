import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/score.dart';
import 'package:zhixin/domain/rules/score_weights.dart';

EvidenceHit _hit(String identity, Score score, {bool literal = false}) {
  return EvidenceHit(
    kind: EvidenceKind.message,
    identity: identity,
    title: '矩阵讨论',
    snippet: '片段 $identity',
    matchedText: '片段 $identity',
    literal: literal,
    score: score,
    location: const EvidenceLocation(conversationId: 1, messageId: 1),
  );
}

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

  group('权重表', () {
    test('权重等于各来源旧量纲上界除以 112', () {
      expect(ScoreSource.literal.weight, 1);
      expect(ScoreSource.keyword.weight, closeTo(15 / 112, 1e-12));
      expect(ScoreSource.semantic.weight, closeTo(13 / 112, 1e-12));
      expect(ScoreSource.crossSession.weight, closeTo(60 / 112, 1e-12));
    });

    test('旧量纲的量程端点映射到 0 与自己的权重上', () {
      expect(ScoreSource.literal.normalize(100), Score.zero);
      expect(ScoreSource.literal.normalize(112).value, closeTo(1, 1e-12));
      expect(ScoreSource.literal.normalize(106).value, closeTo(0.5, 1e-12));
      expect(ScoreSource.keyword.normalize(14), Score.zero);
      expect(ScoreSource.keyword.normalize(15).value, closeTo(15 / 112, 1e-12));
      expect(ScoreSource.semantic.normalize(10), Score.zero);
      expect(
        ScoreSource.semantic.normalize(13).value,
        closeTo(13 / 112, 1e-12),
      );
      expect(ScoreSource.crossSession.normalize(0), Score.zero);
      expect(
        ScoreSource.crossSession.normalize(60).value,
        closeTo(60 / 112, 1e-12),
      );
    });

    test('同一原始分在同一来源下映射稳定，越界由 clamp 夹住', () {
      expect(
        ScoreSource.keyword.normalize(14.4),
        ScoreSource.keyword.normalize(14.4),
      );
      expect(ScoreSource.keyword.normalize(20).value, closeTo(15 / 112, 1e-12));
      expect(ScoreSource.semantic.normalize(9).value, 0);
      expect(ScoreSource.literal.normalize(50), Score.zero);
    });

    test('同一来源内原始分越高，统一分数越大', () {
      expect(
        literalMatchScore(
          offset: 1,
          textLength: 100,
        ).compareTo(literalMatchScore(offset: 90, textLength: 100)),
        greaterThan(0),
      );
      expect(literalMatchScore(offset: 0, textLength: 100), Score.zero);
      expect(
        literalMatchScore(offset: 10, textLength: 100).compareTo(
          literalMatchScore(offset: 10, textLength: 100, kindPriority: 1),
        ),
        lessThan(0),
      );
      expect(
        keywordMatchScore(-2).compareTo(keywordMatchScore(-0.2)),
        greaterThan(0),
      );
      expect(keywordMatchScore(null), ScoreSource.keyword.normalize(14));
      expect(
        semanticMatchScore(0.1).compareTo(semanticMatchScore(0.9)),
        greaterThan(0),
      );
      expect(
        crossSessionScore(0).compareTo(crossSessionScore(3)),
        greaterThan(0),
      );
    });

    test('四类来源的分数都落在 0–1，旧量纲的先后关系保持不变', () {
      final literal = literalMatchScore(offset: 5, textLength: 1000);
      final cross = crossSessionScore(0);
      final keyword = keywordMatchScore(-1);
      final semantic = semanticMatchScore(0.5);
      for (final score in [literal, cross, keyword, semantic]) {
        expect(score.value, inInclusiveRange(0, 1));
      }
      expect(literal.compareTo(cross), greaterThan(0));
      expect(cross.compareTo(keyword), greaterThan(0));
      expect(keyword.compareTo(semantic), greaterThan(0));
    });
  });

  group('跨来源合并', () {
    test('原样命中在前，其余按统一分数从高到低', () {
      final bundle = EvidenceBundle.merge('矩阵', const EvidenceScope.userAll(), [
        _hit('message:1', keywordMatchScore(-1)),
        _hit('message:2', crossSessionScore(0)),
        _hit(
          'message:3',
          literalMatchScore(offset: 1, textLength: 20),
          literal: true,
        ),
      ]);

      expect(bundle.hits.map((hit) => hit.identity), [
        'message:3',
        'message:2',
        'message:1',
      ]);
    });

    test('同一条证据被两路命中时保留原样命中那条', () {
      final bundle = EvidenceBundle.merge('矩阵', const EvidenceScope.userAll(), [
        _hit('message:1', semanticMatchScore(0)),
        _hit(
          'message:1',
          literalMatchScore(offset: 1, textLength: 20),
          literal: true,
        ),
      ]);

      expect(bundle.hits, hasLength(1));
      expect(bundle.hits.single.literal, isTrue);
    });
  });
}
