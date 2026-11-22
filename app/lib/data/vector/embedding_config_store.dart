import 'dart:convert';

import '../../ai/llm_config.dart';
import '../../domain/rules/embedding.dart';

/// 向知新服务发送原文的范围；默认关闭，由用户明确选择。
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

/// 嵌入来源：登录后走知新服务，或者本机哈希。
enum EmbeddingProvider {
  server('server'),
  local('local');

  const EmbeddingProvider(this.value);

  final String value;

  /// 不认识的取值按知新服务处理：旧版本保存过的自填接口配置读到时也落到这一
  /// 来源，用户重新选择模型与可发送范围之后才继续发送原文。
  static EmbeddingProvider fromValue(Object? value) {
    for (final provider in values) {
      if (provider.value == value) return provider;
    }
    return EmbeddingProvider.server;
  }
}

/// 语义索引的配置。
///
/// 没有配置或关闭时语义检索不可用，原文与关键词检索照常工作。业务库与向量库
/// 都保存在本机。
///
/// 选择知新服务时只保存服务端的模型名、维度与可发送范围；地址与凭据不存进
/// 配置，每次请求前由账号服务给出服务地址与当前访问令牌，原文经服务端转给
/// 后台配置的提供方。
class EmbeddingConfig {
  const EmbeddingConfig({
    required this.enabled,
    required this.provider,
    this.model = '',
    this.dim = 1024,
    this.shareScope = EmbeddingShareScope.off,
    this.materialIds = const [],
    this.textVersion = semanticTextVersion,
  });

  final bool enabled;

  /// `server`（知新服务）或 `local`（本机哈希，不联网），取值见
  /// [EmbeddingProvider]。
  final String provider;
  final String model;
  final int dim;
  final EmbeddingShareScope shareScope;
  final List<String> materialIds;
  final String textVersion;

  EmbeddingProvider get source => EmbeddingProvider.fromValue(provider);

  /// 知新服务：地址与令牌运行时由账号服务给出。
  bool get usesServer => source == EmbeddingProvider.server;

  /// 会把原文发出本机；可发送范围只对知新服务生效。
  bool get sendsText => usesServer;

  bool get usable =>
      enabled &&
      switch (source) {
        EmbeddingProvider.local => true,
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
    'model': model,
    'dim': dim,
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
      model: (value['model'] as String?) ?? '',
      dim: dim is int && dim > 0 ? dim : 1024,
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
