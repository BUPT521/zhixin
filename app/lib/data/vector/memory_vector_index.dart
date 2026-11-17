import 'dart:typed_data';

import '../../domain/rules/embedding.dart';
import '../../domain/rules/search_terms.dart';
import 'vector_index.dart';

/// 纯 Dart 的索引实现，供服务层测试使用；关键词匹配口径与 zvec 的实现一致。
class MemoryVectorIndex implements VectorIndex {
  MemoryVectorIndex(this.spec);

  @override
  final EmbeddingModelSpec spec;

  final _metadata = <String, String>{'epoch': '0', 'source_count': '0'};
  final _sources = <String, _MemorySource>{};

  @override
  int get entryCount =>
      _sources.values.fold(0, (count, source) => count + source.chunks.length);

  @override
  int get sourceCount => int.parse(_metadata['source_count']!);

  @override
  Map<String, IndexedSource> indexedSources(List<String> keys) {
    final result = <String, IndexedSource>{};
    for (final key in keys) {
      final source = _sources[key];
      if (source == null) continue;
      result[key] = IndexedSource(
        sourceVersion: source.version,
        chunks: source.chunks.length,
      );
    }
    return result;
  }

  @override
  String? meta(String key) {
    VectorIndex.validateMetaKey(key);
    return _metadata[key];
  }

  @override
  void setMeta(String key, String value) {
    VectorIndex.validateMetaKey(key);
    _metadata[key] = value;
  }

  @override
  void finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  }) {
    _metadata.addAll({'built_at': builtAt, 'source_count': '$sourceCount'});
  }

  @override
  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  }) {
    if (chunks.length != vectors.length && vectors.isNotEmpty) {
      throw ArgumentError('片段数与向量数不一致');
    }
    final sourceKey = locator.sourceKey;
    if (chunks.isEmpty) {
      _sources.remove(sourceKey);
      return;
    }
    _sources[sourceKey] = _MemorySource(
      locator: locator,
      version: sourceVersion,
      chunks: List.of(chunks),
      vectors: vectors.map(_prepareVector).toList(),
    );
  }

  @override
  int pruneSources(Set<String> keep) {
    final before = entryCount;
    if (keep.isEmpty) {
      clear();
      return before;
    }
    _sources.removeWhere((key, _) => !keep.contains(key));
    return before - entryCount;
  }

  @override
  List<StoredVector> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) {
    if (spec.id == textOnlyModelSpec.id) return const [];
    final vector = _prepareVector(query);
    final matches = <StoredVector>[];
    for (final source in _sources.values) {
      if (prefilter != null && !prefilter.allows(source.locator)) continue;
      final locatorJson = VectorIndex.jsonOf(source.locator);
      for (var chunk = 0; chunk < source.chunks.length; chunk++) {
        matches.add(
          StoredVector(
            sourceKey: source.locator.sourceKey,
            chunk: chunk,
            content: source.chunks[chunk],
            sourceVersion: source.version,
            locatorJson: locatorJson,
            distance: cosineDistance(vector, source.vectors[chunk]),
          ),
        );
      }
    }
    matches.sort((left, right) => left.distance.compareTo(right.distance));
    return matches.take(k).toList();
  }

  @override
  List<StoredVector> searchHybrid(
    String text, {
    List<double>? vector,
    int k = 20,
    VectorPrefilter? prefilter,
  }) {
    if (k <= 0) return const [];
    const rankConstant = 60;
    final terms = bigrams(text.trim()).toSet();
    final byKey = <String, StoredVector>{};
    final keywordRanks = <String, int>{};
    if (terms.isNotEmpty) {
      final matches = <StoredVector>[];
      for (final source in _sources.values) {
        if (prefilter != null && !prefilter.allows(source.locator)) continue;
        final locatorJson = VectorIndex.jsonOf(source.locator);
        for (var chunk = 0; chunk < source.chunks.length; chunk++) {
          final content = source.chunks[chunk];
          // 测试替身按子串出现次数判断关键词相关度，与引擎按词频排序的口径
          // 接近；分词细节不必逐字一致。
          final overlap = terms.fold(
            0,
            (count, term) => count + _occurrences(content, term),
          );
          if (overlap == 0) continue;
          final match = StoredVector(
            sourceKey: source.locator.sourceKey,
            chunk: chunk,
            content: content,
            sourceVersion: source.version,
            locatorJson: locatorJson,
            distance: 0,
            score: overlap.toDouble(),
          );
          matches.add(match);
          byKey['${match.sourceKey}#${match.chunk}'] = match;
        }
      }
      matches.sort((left, right) {
        final byScore = right.score.compareTo(left.score);
        if (byScore != 0) return byScore;
        return _entryKey(left).compareTo(_entryKey(right));
      });
      for (var index = 0; index < matches.length; index++) {
        keywordRanks[_entryKey(matches[index])] = index + 1;
      }
    }
    final semanticRanks = <String, int>{};
    final query = vector;
    if (query != null && query.isNotEmpty) {
      final semantic = search(query, k: k * 4, prefilter: prefilter);
      for (var index = 0; index < semantic.length; index++) {
        final match = semantic[index];
        semanticRanks[_entryKey(match)] = index + 1;
        byKey.putIfAbsent(_entryKey(match), () => match);
      }
    }
    final fused = <StoredVector>[];
    for (final entry in byKey.entries) {
      final keywordRank = keywordRanks[entry.key];
      final semanticRank = semanticRanks[entry.key];
      var score = 0.0;
      if (keywordRank != null) score += 1 / (rankConstant + keywordRank);
      if (semanticRank != null) score += 1 / (rankConstant + semanticRank);
      final match = entry.value;
      fused.add(
        StoredVector(
          sourceKey: match.sourceKey,
          chunk: match.chunk,
          content: match.content,
          sourceVersion: match.sourceVersion,
          locatorJson: match.locatorJson,
          distance: 0,
          score: score,
        ),
      );
    }
    fused.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      return _entryKey(left).compareTo(_entryKey(right));
    });
    return fused.take(k).toList();
  }

  static String _entryKey(StoredVector match) =>
      '${match.sourceKey}#${match.chunk}';

  /// 子串 [term] 在 [content] 里出现的次数，用来近似引擎的词频。
  static int _occurrences(String content, String term) {
    var count = 0;
    var from = 0;
    while (true) {
      final at = content.indexOf(term, from);
      if (at < 0) return count;
      count++;
      from = at + 1;
    }
  }

  Float32List _prepareVector(List<double> vector) {
    if (vector.length != spec.dim) {
      throw ArgumentError.value(vector.length, 'dimension', '需要 ${spec.dim} 维');
    }
    return Float32List.fromList(normalizeVector(vector));
  }

  @override
  void clear() {
    _sources.clear();
    _metadata.remove('built_at');
    _metadata['source_count'] = '0';
  }

  @override
  void close() => clear();
}

class _MemorySource {
  const _MemorySource({
    required this.locator,
    required this.version,
    required this.chunks,
    required this.vectors,
  });

  final SemanticLocator locator;
  final String version;
  final List<String> chunks;
  final List<Float32List> vectors;
}
