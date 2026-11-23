import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/domain/rules/embedding.dart';

/// 测试与验收用：按文本查表返回预先准备好的向量，没准备就报不可用。
///
/// 固定向量只验证扩展注册、写入、查询与索引管理，不能说明真实语义效果。
class FixedEmbeddingClient extends EmbeddingClient {
  FixedEmbeddingClient({
    required this.spec,
    required Map<String, List<double>> vectors,
  }) : _vectors = {
         for (final entry in vectors.entries)
           entry.key: normalizeVector(entry.value),
       };

  @override
  final EmbeddingModelSpec spec;
  final Map<String, List<double>> _vectors;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    final vector = _vectors[text.trim()];
    if (vector == null) {
      throw EmbeddingUnavailable('没有为这段文本准备固定向量');
    }
    return vector;
  }

  @override
  void dispose() {}
}
