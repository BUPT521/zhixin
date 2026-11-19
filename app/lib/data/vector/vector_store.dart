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

/// 直接读写 [VectorIndex] 的适配器。
///
/// 只用在测试与需要同步检查的进程内索引上；应用运行时经
/// `IsolateVectorStore` 把同一组操作交给后台 isolate。
class DirectVectorStore implements VectorStore {
  DirectVectorStore(this.index);

  final VectorIndex index;

  @override
  EmbeddingModelSpec get spec => index.spec;

  @override
  Future<int> entryCount() async => index.entryCount;

  @override
  Future<int> sourceCount() async => index.sourceCount;

  @override
  Future<Map<String, IndexedSource>> indexedSources(List<String> keys) async =>
      index.indexedSources(keys);

  @override
  Future<String?> meta(String key) async => index.meta(key);

  @override
  Future<void> setMeta(String key, String value) async =>
      index.setMeta(key, value);

  @override
  Future<void> finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  }) async => index.finishRefresh(
    builtAt: builtAt,
    sourceCount: sourceCount,
    writtenEntries: writtenEntries,
  );

  @override
  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    List<String> chunks = const [],
    List<String> hashes = const [],
    List<List<double>> vectors = const [],
    required String createdAt,
  }) async {
    index.replaceSource(
      locator: locator,
      sourceVersion: sourceVersion,
      chunks: chunks,
      hashes: hashes,
      vectors: vectors,
      createdAt: createdAt,
    );
  }

  @override
  Future<int> pruneSources(Set<String> keep) async => index.pruneSources(keep);

  @override
  Future<List<StoredVector>> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) async => index.search(query, k: k, prefilter: prefilter);

  @override
  Future<List<StoredVector>> searchText(
    String text, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) async => index.searchText(text, k: k, prefilter: prefilter);

  @override
  Future<void> clear() async => index.clear();

  @override
  Future<void> close() async => index.close();
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
