import 'dart:convert';

import '../../ai/llm_config.dart';
import '../../domain/models/embedding_config.dart';

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
