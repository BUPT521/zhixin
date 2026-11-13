import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/llm_config.dart';

/// Android Keystore 的配置适配器；业务代码通过 SecretStore 接口访问它。
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
