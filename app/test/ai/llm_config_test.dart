import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_config_store.dart';

class _MemorySecrets implements SecretStore {
  String? value;
  bool failRead = false;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('keystore 暂时不可用');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }

  @override
  Future<void> delete(String key) async {
    value = null;
  }
}

void main() {
  test('模型上下文上限随配置保存，并约束请求的输出上限', () async {
    final store = LlmConfigStore(_MemorySecrets());
    await store.save(
      const LlmConfig(apiKey: 'test-key', contextWindowTokens: 8192),
    );
    final saved = (await store.read())!;
    expect(saved.contextWindowTokens, 8192);
    expect(saved.outputTokenLimit, 2048);
    expect(LlmConfig.fromJson(const {}).contextWindowTokens, 65536);
  });

  test('换了接口地址还沿用旧 Key 时可以被识别', () {
    const previous = LlmConfig(
      baseUrl: 'https://old.example.com/v1',
      model: 'm',
      apiKey: 'old-key',
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://new.example.com/v1',
        model: 'm',
        apiKey: 'old-key',
      ).reusesKeyFrom(previous),
      isTrue,
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://new.example.com/v1',
        model: 'm',
        apiKey: 'new-key',
      ).reusesKeyFrom(previous),
      isFalse,
    );
    expect(
      const LlmConfig(
        baseUrl: 'https://old.example.com/v1',
        model: 'm',
        apiKey: 'old-key',
      ).reusesKeyFrom(previous),
      isFalse,
    );
  });

  test('Keystore 读不出来时抛出读取失败，而不是当成没配置', () async {
    final secrets = _MemorySecrets()..failRead = true;
    final store = LlmConfigStore(secrets);
    await expectLater(store.read(), throwsA(isA<LlmConfigReadFailure>()));
  });

  test('配置读坏或为空时当作没配置', () async {
    final secrets = _MemorySecrets()..value = '不是 JSON';
    final store = LlmConfigStore(secrets);
    expect(await store.read(), isNull);

    secrets.value = '';
    expect(await store.read(), isNull);
  });

  test('一次读取失败沿用上一次读到的配置，删掉后仍返回空', () async {
    final secrets = _MemorySecrets();
    final service = AiChatService(store: LlmConfigStore(secrets));
    const config = LlmConfig(
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-flash',
      apiKey: 'sk-test',
    );
    await service.store.save(config);
    expect(await service.config(), isNotNull);
    expect((await service.config())!.apiKey, 'sk-test');

    secrets.failRead = true;
    expect((await service.config())!.apiKey, 'sk-test');

    secrets.failRead = false;
    await service.store.clear();
    expect(await service.config(), isNull);
  });
}
