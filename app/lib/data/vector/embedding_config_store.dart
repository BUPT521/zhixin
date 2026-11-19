import 'dart:convert';

import '../../ai/llm_config.dart';
import '../../domain/rules/embedding.dart';

/// 远程嵌入可以发送的原文范围；默认关闭，由用户明确选择。
enum EmbeddingShareScope {
  off('off', '不发送原文'),
  all('all', '本机全部记录'),
  selectedMaterials('materials', '仅选定的材料');

  const EmbeddingShareScope(this.value, this.label);

  final String value;
  final String label;

  static EmbeddingShareScope fromValue(String? value) {
    return EmbeddingShareScope.values.firstWhere(
      (scope) => scope.value == value,
      orElse: () => EmbeddingShareScope.off,
    );
  }
}

/// 嵌入来源：自填接口直连提供方、登录后走知新服务，或者本机哈希。
enum EmbeddingProvider {
  remote('remote'),
  server('server'),
  local('local');

  const EmbeddingProvider(this.value);

  final String value;

  /// 不认识的值按自填接口处理，与加入知新服务之前的读法一致。
  static EmbeddingProvider fromValue(Object? value) {
    for (final provider in values) {
      if (provider.value == value) return provider;
    }
    return EmbeddingProvider.remote;
  }
}

/// 语义索引的配置。
///
/// 远程嵌入必须由用户明确选择提供方、接口地址与可发送范围；没有配置或关闭
/// 时语义检索不可用，原文与关键词检索照常工作。业务库与向量库都保存在本机。
///
/// 选择知新服务时地址与凭据不存进配置，每次请求前由账号服务给出服务地址与
/// 当前访问令牌；原文经服务端转给后台配置的提供方，可发送范围同样生效。
class EmbeddingConfig {
  const EmbeddingConfig({
    required this.enabled,
    required this.provider,
    this.baseUrl = '',
    this.model = '',
    this.dim = 1024,
    this.apiKey = '',
    this.shareScope = EmbeddingShareScope.off,
    this.materialIds = const [],
    this.textVersion = semanticTextVersion,
  });

  final bool enabled;

  /// `remote`（自填 OpenAI 兼容接口）、`server`（知新服务）或 `local`（本机
  /// 哈希，不联网），取值见 [EmbeddingProvider]。
  final String provider;
  final String baseUrl;
  final String model;
  final int dim;
  final String apiKey;
  final EmbeddingShareScope shareScope;
  final List<String> materialIds;
  final String textVersion;

  EmbeddingProvider get source => EmbeddingProvider.fromValue(provider);

  /// 自填接口：地址与 key 都由用户填写。
  bool get usesRemote => source == EmbeddingProvider.remote;

  /// 知新服务：地址与令牌运行时由账号服务给出。
  bool get usesServer => source == EmbeddingProvider.server;

  /// 会把原文发出本机；可发送范围只对这两种来源生效。
  bool get sendsText => usesRemote || usesServer;

  bool get usable =>
      enabled &&
      switch (source) {
        EmbeddingProvider.local => true,
        EmbeddingProvider.remote =>
          baseUrl.trim().isNotEmpty && model.trim().isNotEmpty,
        EmbeddingProvider.server => model.trim().isNotEmpty,
      };

  EmbeddingModelSpec get spec => EmbeddingModelSpec(
    id: provider == 'local' ? 'local-hash-v1' : model.trim(),
    dim: dim,
    textVersion: textVersion,
    provider: provider,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'provider': provider,
    'base_url': baseUrl,
    'model': model,
    'dim': dim,
    'api_key': apiKey,
    'share_scope': shareScope.value,
    'material_ids': materialIds,
    'text_version': textVersion,
  };

  static EmbeddingConfig? fromJson(Object? value) {
    if (value is! Map) return null;
    final dim = value['dim'];
    return EmbeddingConfig(
      enabled: value['enabled'] == true,
      provider: EmbeddingProvider.fromValue(value['provider']).value,
      baseUrl: (value['base_url'] as String?) ?? '',
      model: (value['model'] as String?) ?? '',
      dim: dim is int && dim > 0 ? dim : 1024,
      apiKey: (value['api_key'] as String?) ?? '',
      shareScope: EmbeddingShareScope.fromValue(
        value['share_scope'] as String?,
      ),
      materialIds: [
        if (value['material_ids'] is List)
          for (final id in value['material_ids'] as List)
            if (id is String && id.isNotEmpty) id,
      ],
      textVersion: (value['text_version'] as String?) ?? semanticTextVersion,
    );
  }
}

/// 读写安全存储里的嵌入配置；读坏了按没有配置处理。
class EmbeddingConfigStore {
  EmbeddingConfigStore(this._secrets);

  static const String storageKey = 'zhixin.embedding.config.v1';

  final SecretStore _secrets;

  Future<EmbeddingConfig?> read() async {
    final String? raw;
    try {
      raw = await _secrets.read(storageKey);
    } catch (_) {
      return null;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return EmbeddingConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(EmbeddingConfig config) =>
      _secrets.write(storageKey, jsonEncode(config.toJson()));

  Future<void> clear() => _secrets.delete(storageKey);
}
