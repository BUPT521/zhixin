import 'dart:convert';

import '../domain/models/result.dart';
import 'llm_config.dart';

/// 读写安全存储中的一条 JSON；读坏了按“可预期的读取失败”交回，不让应用起不来。
///
/// 读出来是空串或没有这一项时返回 [Success] 里的空值，表示“还没有配置”；
/// Keystore 读失败或内容解析不了时返回 [Failure]，调用方据此说明原因，不再用
/// 异常区分这两种情况。
class LlmConfigStore {
  LlmConfigStore(this._secrets);

  static const String storageKey = 'zhixin.llm.config.v1';

  final SecretStore _secrets;

  Future<Result<LlmConfig?>> read() async {
    final String? raw;
    try {
      raw = await _secrets.read(storageKey);
    } catch (error) {
      return Failure(FailureReason('读取模型配置失败', detail: error.toString()));
    }
    if (raw == null || raw.trim().isEmpty) return const Success(null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return const Failure(FailureReason('保存的模型配置格式不对'));
      }
      return Success(LlmConfig.fromJson(decoded));
    } catch (error) {
      return Failure(FailureReason('保存的模型配置读不出来', detail: error.toString()));
    }
  }

  Future<void> save(LlmConfig config) {
    return _secrets.write(storageKey, jsonEncode(config.toJson()));
  }

  Future<void> clear() => _secrets.delete(storageKey);
}
