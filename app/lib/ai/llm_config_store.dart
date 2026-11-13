import 'dart:convert';

import 'llm_config.dart';

/// 读写安全存储中的一条 JSON；读坏了就当没配置，不让应用起不来。
class LlmConfigStore {
  LlmConfigStore(this._secrets);

  static const String storageKey = 'zhixin.llm.config.v1';

  final SecretStore _secrets;

  Future<LlmConfig?> read() async {
    final String? raw;
    try {
      raw = await _secrets.read(storageKey);
    } catch (error) {
      throw LlmConfigReadFailure(error);
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return LlmConfig.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LlmConfig config) {
    return _secrets.write(storageKey, jsonEncode(config.toJson()));
  }

  Future<void> clear() => _secrets.delete(storageKey);
}
