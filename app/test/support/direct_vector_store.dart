import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/domain/rules/embedding.dart';

/// 直接读写 [VectorIndex] 的适配器，只给测试用：应用运行时经
/// `IsolateVectorStore` 把同一组操作交给后台 isolate，生产代码不经过这里。
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
