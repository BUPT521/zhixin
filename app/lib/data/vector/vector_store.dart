import '../../domain/rules/embedding.dart';
import 'vector_index.dart';

/// 语义索引的异步入口。
///
/// 界面线程只调用这些方法，索引的打开、建表、读写都由实现放到后台
/// isolate 里完成；句柄本身不含数据库连接，可以安全地留在界面侧。
abstract interface class VectorStore {
  EmbeddingModelSpec get spec;

  Future<int> entryCount();

  Future<int> sourceCount();

  Future<Map<String, IndexedSource>> indexedSources(List<String> keys);

  Future<String?> meta(String key);

  Future<void> setMeta(String key, String value);

  Future<void> finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  });

  /// 写入一个来源的全部片段；文本 collection 读 [chunks]，向量 collection 读
  /// [hashes] 与 [vectors]，片段数为零表示删除这个来源。
  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    List<String> chunks = const [],
    List<String> hashes = const [],
    List<List<double>> vectors = const [],
    required String createdAt,
  });

  Future<int> pruneSources(Set<String> keep);

  /// 向量检索；只有向量 collection 支持，文本 collection 返回空列表。
  Future<List<StoredVector>> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  });

  /// 关键词检索；只有文本 collection 支持，向量 collection 返回空列表。
  Future<List<StoredVector>> searchText(
    String text, {
    int k = 20,
    VectorPrefilter? prefilter,
  });

  Future<void> clear();

  Future<void> close();
}

/// 后台索引操作失败；异常原文与调用栈留在本机诊断记录里，界面只据此说明
/// 哪一步没有完成。
class VectorStoreFailure implements Exception {
  const VectorStoreFailure(this.message);

  final String message;

  @override
  String toString() => '向量索引操作失败：$message';
}

/// 索引已经关闭，之后的调用直接失败，不再发给后台线程。
class VectorStoreClosedException implements Exception {
  const VectorStoreClosedException();

  @override
  String toString() => '向量索引已经关闭';
}
