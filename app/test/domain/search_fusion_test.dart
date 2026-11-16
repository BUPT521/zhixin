import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/score.dart';
import 'package:zhixin/domain/models/search.dart';
import 'package:zhixin/domain/rules/search_fusion.dart';

EvidenceHit _hit({
  required String identity,
  String? conversationId,
  bool literal = false,
  bool semantic = false,
  Score? score,
}) {
  return EvidenceHit(
    kind: EvidenceKind.message,
    identity: identity,
    title: '矩阵讨论',
    snippet: '片段 $identity',
    matchedText: '片段 $identity',
    literal: literal,
    semantic: semantic,
    score: score ?? Score.clamp(0.5),
    location: EvidenceLocation(conversationId: conversationId),
  );
}

SearchEntry _local(String id, {int rank = 1, bool literal = false}) {
  return SearchEntry(
    key: 'conversation:$id',
    hits: [_hit(identity: 'message:$id', conversationId: id, literal: literal)],
    localRank: rank,
  );
}

void main() {
  test('两路都命中的记录排在只被一路命中的记录之前', () {
    final fused = fuseSearch(
      [_local('conv-1', rank: 1), _local('conv-2', rank: 2)],
      [
        _hit(identity: 'message:20', conversationId: 'conv-2', semantic: true),
        _hit(identity: 'message:30', conversationId: 'conv-3', semantic: true),
      ],
    );

    expect(fused.map((entry) => entry.key), [
      'conversation:conv-2',
      'conversation:conv-1',
      'conversation:conv-3',
    ]);
    expect(fused.first.localRank, 2);
    expect(fused.first.semanticRank, 1);
  });

  test('原样命中始终置顶，不受名次分数影响', () {
    final fused = fuseSearch(
      [_local('conv-1', rank: 1), _local('conv-2', rank: 2, literal: true)],
      [_hit(identity: 'message:20', conversationId: 'conv-2', semantic: true)],
    );

    expect(fused.first.key, 'conversation:conv-2');
    expect(fused.first.hasLiteral, isTrue);
    expect(fused.first.semanticOnly, isFalse);
  });

  test('同一条记录在融合结果里只出现一次，并保留本地命中的片段', () {
    final fused = fuseSearch(
      [_local('conv-7')],
      [_hit(identity: 'message:99', conversationId: 'conv-7', semantic: true)],
    );

    expect(fused, hasLength(1));
    final entry = fused.single;
    expect(entry.key, 'conversation:conv-7');
    expect(entry.localRank, 1);
    expect(entry.semanticRank, 1);
    expect(entry.hits, hasLength(1));
    expect(entry.hits.single.semantic, isFalse);
    expect(entry.semanticOnly, isFalse);
  });

  test('只由语义找到的记录带语义标签，材料页按页单独成条', () {
    final fused = fuseSearch(const [], [
      _hit(identity: 'message:8', conversationId: 'conv-8', semantic: true),
      EvidenceHit(
        kind: EvidenceKind.materialPage,
        identity: 'material_page:mat-3:7',
        title: '《讲义》第 7 页',
        snippet: '矩阵的秩',
        matchedText: '矩阵的秩',
        literal: false,
        semantic: true,
        score: Score.clamp(0.5),
        location: const EvidenceLocation(materialId: 'mat-3', pageNo: 7),
      ),
    ]);

    expect(fused, hasLength(2));
    expect(fused.every((entry) => entry.semanticOnly), isTrue);
    expect(fused.map((entry) => entry.key), contains('material_page:mat-3:7'));
  });

  test('分数相同按本地名次、再按记录标识，重复执行顺序一致', () {
    // 两条本地记录给同一个名次，分数相同，只能靠记录标识决定先后。
    final first = fuseSearch([
      _local('conv-2', rank: 5),
      _local('conv-1', rank: 5),
    ], const []);
    final second = fuseSearch([
      _local('conv-2', rank: 5),
      _local('conv-1', rank: 5),
    ], const []);

    expect(first.map((entry) => entry.key), [
      'conversation:conv-1',
      'conversation:conv-2',
    ]);
    expect(second.map((entry) => entry.key), first.map((entry) => entry.key));
  });

  test('分组键保持原样：有讨论标识按记录，材料页按页', () {
    expect(
      searchEntryKey(_hit(identity: 'message:5', conversationId: 'conv-5')),
      'conversation:conv-5',
    );
    expect(
      searchEntryKey(
        EvidenceHit(
          kind: EvidenceKind.materialPage,
          identity: 'material_page:mat-3:7',
          title: '第 7 页',
          snippet: '矩阵',
          matchedText: '矩阵',
          literal: false,
          score: Score.clamp(0.5),
          location: const EvidenceLocation(materialId: 'mat-3', pageNo: 7),
        ),
      ),
      'material_page:mat-3:7',
    );
  });
}
