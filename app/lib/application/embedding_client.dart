import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../domain/rules/embedding.dart';

/// 向量不可用：没有配置、请求超时、远端报错或维度不符都抛这个异常。
class EmbeddingUnavailable implements Exception {
  const EmbeddingUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 生成一段文本向量的来源；测试用固定向量，设备端没有配置时用本地哈希。
abstract class EmbeddingClient {
  EmbeddingModelSpec get spec;

  Future<List<double>> embed(String text);

  void dispose() {}
}

/// 测试与验收用：按文本查表返回预先准备好的向量，没准备就报不可用。
///
/// 固定向量只验证扩展注册、写入、查询与索引管理，不能说明真实语义效果。
class FixedEmbeddingClient implements EmbeddingClient {
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
  Future<List<double>> embed(String text) async {
    final vector = _vectors[text.trim()];
    if (vector == null) {
      throw EmbeddingUnavailable('没有为这段文本准备固定向量');
    }
    return vector;
  }

  @override
  void dispose() {}
}

/// 本地兜底：按字与二元组做特征哈希，不联网，也不需要模型文件。
///
/// 它只能把用词接近的文本放到一起，不能替代中文嵌入模型；没有配置远程嵌入
/// 时用它保持索引可用，界面与文档都按这个限制说明效果。
class HashingEmbeddingClient implements EmbeddingClient {
  HashingEmbeddingClient({this.dim = 256, String id = 'local-hash-v1'})
    : spec = EmbeddingModelSpec(id: id, dim: dim, provider: 'local');

  @override
  final EmbeddingModelSpec spec;
  final int dim;

  @override
  Future<List<double>> embed(String text) async {
    final vector = List<double>.filled(dim, 0);
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return vector;
    final chars = normalized.runes.toList(growable: false);
    for (var index = 0; index < chars.length; index++) {
      final rune = chars[index];
      _addFeature(vector, String.fromCharCode(rune), 1);
      if (index + 1 < chars.length) {
        _addFeature(
          vector,
          '${String.fromCharCode(rune)}${String.fromCharCode(chars[index + 1])}',
          1.5,
        );
      }
    }
    return normalizeVector(vector);
  }

  @override
  void dispose() {}

  void _addFeature(List<double> vector, String feature, double weight) {
    var hash = 2166136261;
    for (final byte in utf8.encode(feature)) {
      hash ^= byte;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    final slot = hash % dim;
    final sign = (hash >> 8) & 1 == 1 ? 1.0 : -1.0;
    vector[slot] += sign * weight;
  }
}

/// 远程嵌入：OpenAI 兼容的 `/embeddings` 接口，只有在用户明确配置并选定了
/// 可发送范围时才会被调用。
class RemoteEmbeddingClient implements EmbeddingClient {
  RemoteEmbeddingClient({
    required this.spec,
    required this.endpoint,
    required this.apiKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  }) : _http = httpClient ?? http.Client();

  @override
  final EmbeddingModelSpec spec;
  final String endpoint;
  final String apiKey;
  final Duration timeout;
  final http.Client _http;

  @override
  Future<List<double>> embed(String text) async {
    final uri = Uri.parse('$endpoint/embeddings');
    final response = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': spec.id,
            'input': [text],
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw EmbeddingUnavailable('嵌入服务返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const EmbeddingUnavailable('嵌入服务返回的格式不对');
    final data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw const EmbeddingUnavailable('嵌入服务没有返回向量');
    }
    final first = data.first;
    final raw = first is Map ? first['embedding'] : null;
    if (raw is! List) throw const EmbeddingUnavailable('嵌入服务没有返回向量');
    final vector = <double>[];
    for (final value in raw) {
      final number = value is num ? value.toDouble() : null;
      if (number == null) throw const EmbeddingUnavailable('向量里有非数字');
      vector.add(number);
    }
    if (vector.length != spec.dim) {
      throw EmbeddingUnavailable('向量维度为 ${vector.length}，配置的是 ${spec.dim}');
    }
    return normalizeVector(vector);
  }

  @override
  void dispose() => _http.close();
}

/// 固定向量里没有出现、也没有配置远程服务时的本地向量：只用于让索引保持
/// 可用，不承诺语义效果。
EmbeddingClient fallbackEmbeddingClient({int dim = 256}) =>
    HashingEmbeddingClient(dim: dim);

/// 把向量里最大的分量拉平，用于调试与打印；不参与检索。
String describeVector(List<double> vector, {int limit = 4}) {
  final values = vector.take(limit).map((value) => value.toStringAsFixed(3));
  return '[$values…]';
}

/// 距离比较：两个向量的余弦距离，测试与界面提示共用。
double vectorDistance(List<double> left, List<double> right) =>
    cosineDistance(left, right);

/// 取前 k 个候选的辅助函数；测试用它核对检索顺序。
List<int> nearestSlots(
  List<List<double>> vectors,
  List<double> query, {
  int k = 3,
}) {
  final distances = <(int, double)>[
    for (var index = 0; index < vectors.length; index++)
      (index, cosineDistance(query, vectors[index])),
  ]..sort((left, right) => left.$2.compareTo(right.$2));
  return distances
      .take(math.min(k, distances.length))
      .map((item) => item.$1)
      .toList();
}
