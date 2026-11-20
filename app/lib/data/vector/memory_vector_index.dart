import 'dart:typed_data';

import '../../domain/rules/embedding.dart';
import '../../domain/rules/search_terms.dart';
import 'vector_index.dart';

/// 纯 Dart 的索引实现，供服务层测试使用；关键词匹配口径与 zvec 的实现一致。
///
/// 与 zvec 的实现一样按 spec 分成两种 collection：纯文本 spec 只接受正文、
/// 提供关键词检索；其余 spec 只接受向量与文本哈希、提供向量检索。
class MemoryVectorIndex implements VectorIndex {
  MemoryVectorIndex(this.spec);

  @override
  final EmbeddingModelSpec spec;

  final _metadata = <String, String>{'epoch': '0', 'source_count': '0'};
  final _sources = <String, _MemorySource>{};

  bool get _textOnly => spec.id == textOnlyModelSpec.id;

  @override
  int get entryCount =>
      _sources.values.fold(0, (count, source) => count + source.count);

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
        chunks: source.count,
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
    List<String> chunks = const [],
    List<String> hashes = const [],
    List<List<double>> vectors = const [],
    required String createdAt,
  }) {
    final sourceKey = locator.sourceKey;
    // 文本 collection 按正文条数写，向量 collection 按向量条数写；另一组参数
    // 在各自的实现里被忽略，与 zvec 实现的取舍一致。
    final count = _textOnly ? chunks.length : hashes.length;
    if (!_textOnly && hashes.length != vectors.length) {
      throw ArgumentError('片段数与向量数不一致');
    }
    if (count == 0) {
      _sources.remove(sourceKey);
      return;
    }
    _sources[sourceKey] = _MemorySource(
      locator: locator,
      version: sourceVersion,
      count: count,
      chunks: _textOnly ? List.of(chunks) : const [],
      vectors: _textOnly
          ? const []
          : [for (final vector in vectors) _prepareVector(vector)],
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
    if (_textOnly || k <= 0) return const [];
    final vector = _prepareVector(query);
    final matches = <StoredVector>[];
    for (final source in _sources.values) {
      if (prefilter != null && !prefilter.allows(source.locator)) continue;
      final locatorJson = VectorIndex.jsonOf(source.locator);
      for (var chunk = 0; chunk < source.vectors.length; chunk++) {
        matches.add(
          StoredVector(
            sourceKey: source.locator.sourceKey,
            chunk: chunk,
            // 向量 collection 不存正文，摘要由应用层按当前记录重新计算。
            content: '',
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

  /// 关键词检索：按查询二元组在正文里的出现次数排序，分数越大越相关。
  @override
  List<StoredVector> searchText(
    String text, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) {
    if (!_textOnly || k <= 0) return const [];
    final terms = bigrams(text.trim()).toSet();
    if (terms.isEmpty) return const [];
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
        matches.add(
          StoredVector(
            sourceKey: source.locator.sourceKey,
            chunk: chunk,
            content: content,
            sourceVersion: source.version,
            locatorJson: locatorJson,
            distance: 0,
            score: overlap.toDouble(),
          ),
        );
      }
    }
    matches.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      return _entryKey(left).compareTo(_entryKey(right));
    });
    return matches.take(k).toList();
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
    // 已处理到的提交编号不在状态里：它记在 `revision_cursor` 的非阻塞位置，
    // 清空时由检索索引服务把那个位置归零，下一次按全量扫描重建（方案 3.12）。
  }

  @override
  void close() => clear();
}

class _MemorySource {
  const _MemorySource({
    required this.locator,
    required this.version,
    required this.count,
    required this.chunks,
    required this.vectors,
  });

  final SemanticLocator locator;
  final String version;

  /// 片段条数；文本 collection 取正文条数，向量 collection 取向量条数。
  final int count;
  final List<String> chunks;
  final List<Float32List> vectors;
}
