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

/// 语义索引的配置。
///
/// 远程嵌入必须由用户明确选择提供方、接口地址与可发送范围；没有配置或关闭
/// 时语义检索不可用，原文与关键词检索照常工作。业务库与向量库都保存在本机。
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

  /// `remote`（OpenAI 兼容接口）或 `local`（本机哈希，不联网）。
  final String provider;
  final String baseUrl;
  final String model;
  final int dim;
  final String apiKey;
  final EmbeddingShareScope shareScope;
  final List<int> materialIds;
  final String textVersion;

  bool get usesRemote => provider == 'remote';

  bool get usable =>
      enabled &&
      (provider == 'local' ||
          (usesRemote && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty));

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
    final provider = value['provider'];
    final dim = value['dim'];
    return EmbeddingConfig(
      enabled: value['enabled'] == true,
      provider: provider is String && provider == 'local' ? 'local' : 'remote',
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
            if (id is int) id,
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
