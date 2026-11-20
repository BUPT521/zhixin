import 'dart:convert';

import '../../domain/rules/embedding.dart';

/// 记忆索引目录名；与语义索引目录同级，清空本机数据时一起删除。
///
/// 记忆按记忆表的有效性核对，与证据来源的核对规则不同，因此单独一个 collection。
const String memoryIndexDirectoryName = 'memory_index';

/// 语义索引拆成的两个 collection 的目录名；两者各有独立目录与状态文件。
///
/// 文本 collection 的 schema 固定，只存正文与全文索引；向量 collection 按嵌入
/// 模型键分目录，只存向量、来源键与文本哈希。见 ADR-0030 决定第 4 条。
const String textCollectionDirectoryName = 'text';
const String vectorCollectionDirectoryName = 'vector';

/// 名次融合的平滑常数：两路候选按 1/(常数 + 名次) 相加，名次越靠前贡献越大。
///
/// 文本 collection 的全文子查询与 `SearchIndexService` 的两路融合共用这个值，
/// 拆分前后的顺序差异只来自“两路各自排序”而不是常数变化。
const int vectorFusionRankConstant = 60;

/// 索引里的一条命中：来源、片段正文与写入时的版本。
class StoredVector {
  const StoredVector({
    required this.sourceKey,
    required this.chunk,
    required this.content,
    required this.sourceVersion,
    required this.locatorJson,
    required this.distance,
    this.score = 0,
  });

  final String sourceKey;
  final int chunk;

  /// 片段正文；只有文本 collection 保存正文，向量 collection 返回空串。
  final String content;
  final String sourceVersion;
  final String locatorJson;
  final double distance;

  /// 检索得分，越大越相关；文本 collection 的 [VectorIndex.searchText] 会填，
  /// 应用层按名次融合之后也由这里带出融合分。
  final double score;
}

/// 索引条目的当前状态：用于判断来源是否需要重写正文或重新嵌入。
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

/// 只保留给定的来源键；记忆召回用它把排序限制在本次候选之内。
final class SourceKeysVectorPrefilter extends VectorPrefilter {
  SourceKeysVectorPrefilter(Iterable<String> sourceKeys)
    : sourceKeys = Set.unmodifiable(sourceKeys);

  final Set<String> sourceKeys;

  @override
  bool allows(SemanticLocator locator) =>
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

  /// 写入一个来源的全部片段；片段数为零表示删除这个来源。
  ///
  /// 文本 collection 读 [chunks]（正文），向量 collection 读 [hashes] 与
  /// [vectors]；另一个参数在各自的实现里被忽略。写入顺序仍然是先写 1..n 号
  /// 片段、删除多余片段、最后写 0 号片段作为这个来源的提交记录。
  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    List<String> chunks = const [],
    List<String> hashes = const [],
    List<List<double>> vectors = const [],
    required String createdAt,
  });

  /// 删除未保留的来源，返回被删除的向量条数。
  int pruneSources(Set<String> keep);

  /// 向量检索；只有向量 collection 支持，文本 collection 返回空列表。
  List<StoredVector> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  });

  /// 关键词检索；只有文本 collection 支持，向量 collection 返回空列表。
  ///
  /// 返回值按相关度从高到低，[StoredVector.score] 已填。引擎要求多路查询至少
  /// 两路，实现把同一条全文查询发两次再按名次倒数相加融合，先后与单路全文
  /// 检索一致；两路结果在应用层再由 `SearchIndexService` 融合一次。
  List<StoredVector> searchText(
    String text, {
    int k = 20,
    VectorPrefilter? prefilter,
  });

  void clear();

  void close();

  static void validateMetaKey(String key) {
    const supportedKeys = {
      'epoch',
      'built_at',
      'source_count',
      // 可发送范围签名：范围变化时清空向量集合（ADR-0030 决定第 5 条）。
      // 已处理到的提交编号不在状态文件里，挪进了 `revision_cursor` 的非阻塞
      // 位置（方案 3.12），所以这里不再接受 `commit_id`。
      'share_signature',
    };
    if (!supportedKeys.contains(key)) {
      throw ArgumentError.value(key, 'key', '未知的向量索引元数据键');
    }
  }

  static String jsonOf(SemanticLocator locator) => jsonEncode(locator.toJson());
}
