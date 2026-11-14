import '../../domain/rules/embedding.dart';
import 'vector_index.dart';

/// 语义索引的异步入口。
///
/// 界面线程只调用这些方法，SQLite 的打开、建表、读写都由实现放到后台
/// isolate 里完成；句柄本身不含数据库连接，可以安全地留在界面侧。
abstract interface class VectorStore {
  EmbeddingModelSpec get spec;

  Future<int> entryCount();

  Future<Map<String, IndexedSource>> indexedSources();

  Future<String?> meta(String key);

  Future<void> setMeta(String key, String value);

  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  });

  Future<int> pruneSources(Set<String> keep);

  Future<List<StoredVector>> search(List<double> query, {int k = 20});

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
  Future<Map<String, IndexedSource>> indexedSources() async =>
      index.indexedSources();

  @override
  Future<String?> meta(String key) async => index.meta(key);

  @override
  Future<void> setMeta(String key, String value) async =>
      index.setMeta(key, value);

  @override
  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  }) async {
    index.replaceSource(
      locator: locator,
      sourceVersion: sourceVersion,
      chunks: chunks,
      vectors: vectors,
      createdAt: createdAt,
    );
  }

  @override
  Future<int> pruneSources(Set<String> keep) async => index.pruneSources(keep);

  @override
  Future<List<StoredVector>> search(List<double> query, {int k = 20}) async =>
      index.search(query, k: k);

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
