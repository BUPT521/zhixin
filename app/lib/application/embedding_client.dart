import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../data/vector/embedding_codec.dart';
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

/// 一次批量查找命中的向量：键是片段文本的 SHA-256，值已经归一化。
typedef EmbeddingLookup = Map<String, List<double>>;

/// 生成一段文本向量的来源；测试用固定向量，设备端没有配置时用本地哈希。
abstract class EmbeddingClient {
  /// 一次查找缓存的条数上限，与嵌入接口的单次输入上限一致。
  static const int lookupMaxHashes = 256;

  EmbeddingModelSpec get spec;

  /// 生成一段文本的向量。
  ///
  /// [writeCache] 为真时，知新服务会把这批向量写进这个账号的缓存；只有自动
  /// 同步开启时的索引刷新才这样请求，检索查询与同步关闭时不写。
  Future<List<double>> embed(String text, {bool writeCache = false});

  /// 一次生成多段文本的向量；默认逐条调用 [embed]，远程来源覆盖为一次请求。
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    final vectors = <List<double>>[];
    for (final text in texts) {
      vectors.add(await embed(text, writeCache: writeCache));
    }
    return vectors;
  }

  /// 按文本哈希查询服务端已经算过的向量；默认返回空。
  ///
  /// 默认实现表示这个来源没有查找接口，本地哈希、自填 key 直连与测试来源都按
  /// 全部未命中处理，调用方照常嵌入。只有知新服务的来源会真正发出请求；命中之
  /// 外的文本由调用方补算，服务端不提供“某段文本有没有算过”的另一个入口。
  Future<EmbeddingLookup> lookupVectors(List<String> hashes) async => const {};

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
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
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

  /// 服务端没有查找接口（旧版 404）之后，本次会话不再尝试查找。
  bool _lookupUnsupported = false;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    final vectors = await _embed([text], timeout, writeCache);
    return vectors.first;
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    if (texts.isEmpty) return const [];
    return _embed(texts, batchTimeout, writeCache);
  }

  /// 按哈希批量查询服务端缓存，只返回命中的条目。
  ///
  /// 只有通过 [credentials] 取地址与令牌的知新服务才查：自填 key 直连的提供方
  /// 没有这个接口。旧版服务端返回 404 之后本次会话不再尝试；网络失败、5xx 与
  /// 响应格式不对都按全部未命中处理，由调用方整批补算，索引更新照常完成。401、
  /// 403、429 说明整个来源暂时用不了，按 [EmbeddingSourceUnavailable] 抛出，
  /// 调用方据此停下本次剩余的请求。
  @override
  Future<EmbeddingLookup> lookupVectors(List<String> hashes) async {
    final source = credentials;
    if (source == null || hashes.isEmpty || _lookupUnsupported) return const {};
    final target = await source();
    final hits = <String, List<double>>{};
    for (
      var start = 0;
      start < hashes.length;
      start += EmbeddingClient.lookupMaxHashes
    ) {
      final end = math.min(
        start + EmbeddingClient.lookupMaxHashes,
        hashes.length,
      );
      final batch = hashes.sublist(start, end);
      final found = await _lookupBatch(target, batch);
      hits.addAll(found);
    }
    return hits;
  }

  Future<EmbeddingLookup> _lookupBatch(
    EmbeddingEndpoint target,
    List<String> hashes,
  ) async {
    final uri = Uri.parse('${target.endpoint}/embeddings/lookup');
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': spec.id, 'hashes': hashes});
    if (target.apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${target.apiKey}';
    }
    final http.Response response;
    try {
      response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on Object {
      // 网络失败退回整批嵌入；查询本身的失败不打断索引更新。
      return const {};
    }
    if (response.statusCode == 404) {
      _lookupUnsupported = true;
      return const {};
    }
    if (response.statusCode != 200) {
      final failure = _failure(response);
      if (failure is EmbeddingSourceUnavailable) throw failure;
      return const {};
    }
    return _decodeLookup(response);
  }

  /// 解析查找响应；条目格式不对时跳过这一条，由调用方补算这段文本。
  EmbeddingLookup _decodeLookup(http.Response response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    final raw = decoded['vectors'];
    if (raw is! List) return const {};
    final hits = <String, List<double>>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final hash = item['hash'];
      final encoded = item['embedding'];
      if (hash is! String || encoded is! String) continue;
      // 维度以配置为准：与配置不符的向量按未命中处理，这段文本重新嵌入。
      final vector = decodeEmbeddingVector(encoded, dim: spec.dim);
      if (vector == null) continue;
      hits[hash] = normalizeVector(vector);
    }
    return hits;
  }

  Future<List<List<double>>> _embed(
    List<String> texts,
    Duration wait,
    bool writeCache,
  ) async {
    final source = credentials;
    final target = source == null
        ? (endpoint: endpoint, apiKey: apiKey)
        : await source();
    final uri = Uri.parse('${target.endpoint}/embeddings');
    final request = http.Request('POST', uri)
      ..followRedirects = source == null
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': spec.id, 'input': texts});
    if (target.apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${target.apiKey}';
    }
    // 只有知新服务有缓存表；这个头只在自动同步开启时的索引刷新里加上。
    if (writeCache && source != null) {
      request.headers['X-Zhixin-Embedding-Cache'] = '1';
    }
    final response = await _http
        .send(request)
        .then(http.Response.fromStream)
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
    if (code == 'contact_unverified') {
      // 托管额度要求先确认一种登录方式；这条说明比“凭据被拒”更接近用户要做的事。
      return const EmbeddingSourceUnavailable('知新服务要求先确认一种登录方式，暂时不能使用托管嵌入');
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
