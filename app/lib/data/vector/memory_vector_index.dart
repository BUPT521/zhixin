import 'dart:typed_data';

import '../../domain/rules/embedding.dart';
import 'vector_index.dart';

/// 纯 Dart 的语义索引，供服务层测试使用。
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
    if (chunks.length != vectors.length) {
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
