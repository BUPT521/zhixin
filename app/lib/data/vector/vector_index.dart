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

/// 只用写入后不变的定位信息筛选候选。
sealed class VectorPrefilter {
  const VectorPrefilter();

  bool allows(SemanticLocator locator);
}

/// 保留指定材料的页面和所有讨论级来源。
final class MaterialVectorPrefilter extends VectorPrefilter {
  const MaterialVectorPrefilter(this.materialId);

  final String materialId;

  @override
  bool allows(SemanticLocator locator) =>
      locator.kind != 'material_page' || locator.materialId == materialId;
}

/// 保留当前讨论中的来源和本轮带入的来源。
final class ConversationVectorPrefilter extends VectorPrefilter {
  ConversationVectorPrefilter({
    this.conversationId,
    required Set<String> sourceKeys,
  }) : sourceKeys = Set.unmodifiable(sourceKeys);

  final String? conversationId;
  final Set<String> sourceKeys;

  @override
  bool allows(SemanticLocator locator) =>
      (conversationId != null && locator.conversationId == conversationId) ||
      sourceKeys.contains(locator.sourceKey);
}

/// 在持有索引的 isolate 中同步执行的读写接口。
abstract interface class VectorIndex {
  EmbeddingModelSpec get spec;

  int get entryCount;

  /// 最近一次刷新后仍有索引的来源数。
  int get sourceCount;

  Map<String, IndexedSource> indexedSources(List<String> keys);

  String? meta(String key);

  void setMeta(String key, String value);

  /// 结算同一次刷新产生的统计，供实现按写入量处理持久化。
  void finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  });

  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  });

  /// 删除未保留的来源，返回被删除的向量条数。
  int pruneSources(Set<String> keep);

  List<StoredVector> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  });

  void clear();

  void close();

  static void validateMetaKey(String key) {
    const supportedKeys = {'epoch', 'built_at', 'source_count'};
    if (!supportedKeys.contains(key)) {
      throw ArgumentError.value(key, 'key', '未知的向量索引元数据键');
    }
  }

  static String jsonOf(SemanticLocator locator) => jsonEncode(locator.toJson());
}
