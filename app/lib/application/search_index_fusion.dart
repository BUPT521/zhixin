import '../data/vector/vector_index.dart';
import '../domain/models/evidence.dart';
import '../domain/models/score.dart';
import '../domain/rules/embedding.dart';

/// 融合与结果构造：检索索引里不做 I/O 的纯函数。
///
/// 关键词与向量两路各取一批候选，由这里按名次倒数相加融合，再把候选换成
/// 界面与提示词使用的 [EvidenceHit]。这些函数不读库、不碰索引句柄，单独放在
/// 一个文件里，检索行为可以直接用输入输出核对。

/// 把两路候选按名次倒数相加，返回融合后的候选。
///
/// 同一片段在文本与向量两路都出现时分数相加；名次相同、分数也相同时按来源键
/// 与片段号排序，保证结果稳定。常数与文本集合内部全文子查询的平滑常数一致，
/// 拆分前后的差异只来自两路各自排序。
List<StoredVector> fuseCandidates(List<List<StoredVector>> routes) {
  final scores = <String, double>{};
  final rows = <String, StoredVector>{};
  for (final route in routes) {
    for (var index = 0; index < route.length; index++) {
      final row = route[index];
      final key = '${row.sourceKey}#${row.chunk}';
      scores[key] =
          (scores[key] ?? 0) + 1 / (vectorFusionRankConstant + index + 1);
      rows.putIfAbsent(key, () => row);
    }
  }
  final keys = rows.keys.toList(growable: false);
  keys.sort((left, right) {
    final byScore = scores[right]!.compareTo(scores[left]!);
    if (byScore != 0) return byScore;
    return left.compareTo(right);
  });
  return [for (final key in keys) withFusionScore(rows[key]!, scores[key]!)];
}

/// 换掉候选的分数，其余字段照旧。
StoredVector withFusionScore(StoredVector row, double score) => StoredVector(
  sourceKey: row.sourceKey,
  chunk: row.chunk,
  content: row.content,
  sourceVersion: row.sourceVersion,
  locatorJson: row.locatorJson,
  distance: row.distance,
  score: score,
);

/// 把一条索引候选换成本轮的结果条目。
///
/// 片段正文只用来占位，核对之后由调用方按当前记录重算摘要；[semantic] 为真
/// 表示这条来自向量一路。
EvidenceHit hitForCandidate(
  SemanticLocator locator,
  StoredVector candidate, {
  required bool semantic,
}) {
  final kind = switch (locator.kind) {
    'material_page' => EvidenceKind.materialPage,
    'answer' => EvidenceKind.answer,
    'attempt' => EvidenceKind.answer,
    'message' => EvidenceKind.message,
    _ => EvidenceKind.message,
  };
  return EvidenceHit(
    kind: kind,
    identity: locator.sourceKey,
    title: switch (kind) {
      EvidenceKind.materialPage => '第 ${locator.pageNo} 页',
      EvidenceKind.answer => '一次已提交作答',
      EvidenceKind.question => '题目',
      EvidenceKind.message => '一次讨论',
      EvidenceKind.unknown => '来源未知',
    },
    snippet: candidate.content,
    text: candidate.content,
    matchedText: candidate.content,
    literal: false,
    semantic: semantic,
    score: Score.clamp(candidate.score),
    location: EvidenceLocation(
      conversationId: locator.conversationId,
      messageId: locator.messageId,
      materialId: locator.materialId,
      pageNo: locator.pageNo,
      attemptId: locator.attemptId,
    ),
    sourceVersion: candidate.sourceVersion,
  );
}
