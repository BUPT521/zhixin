import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/rules/embedding.dart';

/// 向量不可用：没有配置、请求超时、远端报错或维度不符都抛这个异常。
class EmbeddingUnavailable implements Exception {
  const EmbeddingUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 整个嵌入来源暂时用不了：没有登录、key 被拒（401、403）或者限流与额度用完
/// （429）。这时换一段文本重发也只会得到同样的结果，索引更新据此停下本次
/// 剩余的请求，不再逐条重试。
class EmbeddingSourceUnavailable extends EmbeddingUnavailable {
  const EmbeddingSourceUnavailable(super.message);
}

/// 一次嵌入请求要用的接口地址与凭据。
typedef EmbeddingEndpoint = ({String endpoint, String apiKey});

/// 生成一段文本向量的来源；测试用固定向量，设备端没有配置时用本地哈希。
abstract class EmbeddingClient {
  EmbeddingModelSpec get spec;

  Future<List<double>> embed(String text);

  /// 一次生成多段文本的向量；默认逐条调用 [embed]，远程来源覆盖为一次请求。
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final vectors = <List<double>>[];
    for (final text in texts) {
      vectors.add(await embed(text));
    }
    return vectors;
  }

  void dispose() {}
}

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
class HashingEmbeddingClient extends EmbeddingClient {
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
///
/// 自填 Key 时地址与 key 固定；选择知新服务时传 [credentials]，每次请求前
/// 取一次服务地址与当前访问令牌，令牌轮换之后不需要重建客户端。
class RemoteEmbeddingClient extends EmbeddingClient {
  RemoteEmbeddingClient({
    required this.spec,
    this.endpoint = '',
    this.apiKey = '',
    this.credentials,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
    this.batchTimeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client();

  @override
  final EmbeddingModelSpec spec;
  final String endpoint;
  final String apiKey;

  /// 每次请求前取地址与凭据；为空时用 [endpoint] 与 [apiKey]。
  ///
  /// 取不到时（例如还没有登录）应抛 [EmbeddingSourceUnavailable]。
  final Future<EmbeddingEndpoint> Function()? credentials;
  final Duration timeout;

  /// 一次多段请求的等待上限；批量请求的计算时间比单条长。
  final Duration batchTimeout;
  final http.Client _http;

  @override
  Future<List<double>> embed(String text) async {
    final vectors = await _embed([text], timeout);
    return vectors.first;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    return _embed(texts, batchTimeout);
  }

  Future<List<List<double>>> _embed(List<String> texts, Duration wait) async {
    final source = credentials;
    final target = source == null
        ? (endpoint: endpoint, apiKey: apiKey)
        : await source();
    final uri = Uri.parse('${target.endpoint}/embeddings');
    final response = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (target.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${target.apiKey}',
          },
          body: jsonEncode({'model': spec.id, 'input': texts}),
        )
        .timeout(wait);
    if (response.statusCode != 200) {
      throw _failure(response);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const EmbeddingUnavailable('嵌入服务返回的格式不对');
    final data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw const EmbeddingUnavailable('嵌入服务没有返回向量');
    }
    if (data.length != texts.length) {
      throw const EmbeddingUnavailable('嵌入服务返回的向量条数不对');
    }
    final vectors = List<List<double>?>.filled(texts.length, null);
    var next = 0;
    for (final item in data) {
      if (item is! Map) {
        throw const EmbeddingUnavailable('嵌入服务返回的格式不对');
      }
      final raw = item['embedding'];
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
      final index = item['index'];
      final slot = index is num && index >= 0 && index < texts.length
          ? index.toInt()
          : next;
      next = slot + 1;
      if (vectors[slot] != null) {
        throw const EmbeddingUnavailable('嵌入服务返回了重复的序号');
      }
      vectors[slot] = normalizeVector(vector);
    }
    if (vectors.any((vector) => vector == null)) {
      throw const EmbeddingUnavailable('嵌入服务没有返回全部向量');
    }
    return [for (final vector in vectors) vector!];
  }

  /// 非 200 的响应：401、403、429 说明整个来源暂时用不了，其余只算这一次失败。
  ///
  /// 知新服务的拒绝是 problem+json，只读 `code` 区分额度用完；提供方的错误体
  /// 可能带着打码的 key，不放进异常信息。
  static EmbeddingUnavailable _failure(http.Response response) {
    final status = response.statusCode;
    String? code;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['code'] is String) code = body['code'] as String;
    } catch (_) {
      // 错误体不是 JSON 时只按状态码判断。
    }
    if (code == 'quota_exceeded') {
      return const EmbeddingSourceUnavailable('今天的嵌入额度已经用完，次日重置');
    }
    return switch (status) {
      401 || 403 => EmbeddingSourceUnavailable('嵌入服务拒绝了凭据（$status）'),
      429 => const EmbeddingSourceUnavailable('嵌入服务限流（429），请稍后再试'),
      _ => EmbeddingUnavailable('嵌入服务返回 $status'),
    };
  }

  @override
  void dispose() => _http.close();
}
