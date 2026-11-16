import 'dart:convert';

import '../../domain/rules/embedding.dart';

/// 语义索引里的一条向量。
class StoredVector {
  const StoredVector({
    required this.sourceKey,
    required this.chunk,
    required this.content,
    required this.sourceVersion,
    required this.locatorJson,
    required this.distance,
  });

  final String sourceKey;
  final int chunk;
  final String content;
  final String sourceVersion;
  final String locatorJson;
  final double distance;
}

/// 索引条目的当前状态：用于判断来源是否需要重新嵌入。
class IndexedSource {
  const IndexedSource({required this.sourceVersion, required this.chunks});

  final String sourceVersion;
  final int chunks;
}

/// 在持有索引的 isolate 中同步执行的读写接口。
abstract interface class VectorIndex {
  EmbeddingModelSpec get spec;

  int get entryCount;

  int get sourceCount;

  Map<String, IndexedSource> indexedSources();

  String? meta(String key);

  void setMeta(String key, String value);

  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  });

  int pruneSources(Set<String> keep);

  List<StoredVector> search(List<double> query, {int k = 20});

  void clear();

  void close();

  static String jsonOf(SemanticLocator locator) => jsonEncode(locator.toJson());
}
