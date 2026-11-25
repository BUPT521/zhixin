import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_config_store.dart';
import 'package:zhixin/ai/llm_protocol.dart';
import 'package:zhixin/domain/models/result.dart';

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
    await store.save(const LlmConfig(contextWindowTokens: 8192));
    final saved = (await store.read()).valueOrNull!;
    expect(saved.contextWindowTokens, 8192);
    expect(saved.outputTokenLimit, 2048);
    expect(LlmConfig.fromJson(const {}).contextWindowTokens, 65536);
    // 上下文上限统一为 65536，读回旧配置时超出上限的值被夹回，复制时同样。
    expect(
      LlmConfig.fromJson(const {'context_window_tokens': '1000000'})
          .contextWindowTokens,
      LlmConfig.maxContextWindowTokens,
    );
    expect(
      const LlmConfig(contextWindowTokens: 1000000)
          .copyWith(model: 'zhixin-chat')
          .contextWindowTokens,
      LlmConfig.maxContextWindowTokens,
    );
  });

  // 项目技术审查 API-06：服务端只接受 16 到 32768，客户端算出的上限必须落在这个
  // 区间里。上下文上限配得很小时，按四分之一算会得到个位数，改前服务端必然回 400。
  test('输出上限始终落在服务端接受的 16 到 32768 之间', () {
    for (final window in [1, 4, 15, 63, 64, 100, 8192, 65536, 1000000]) {
      final limit = LlmConfig(contextWindowTokens: window).outputTokenLimit;
      expect(
        limit,
        inInclusiveRange(buddyMinOutputTokens, buddyMaxOutputTokens),
        reason: '上下文上限 $window 算出的输出上限是 $limit',
      );
    }
    expect(const LlmConfig(contextWindowTokens: 1).outputTokenLimit, 16);
    expect(const LlmConfig(contextWindowTokens: 64).outputTokenLimit, 16);
    expect(const LlmConfig(contextWindowTokens: 8192).outputTokenLimit, 2048);
    expect(
      const LlmConfig(contextWindowTokens: 1000000).outputTokenLimit,
      buddyMaxOutputTokens,
    );
  });

  test('协议请求里的输出上限与配置算出的值一致', () {
    final body = responsesBody(
      config: const LlmConfig(model: 'zhixin-chat', contextWindowTokens: 8192),
      system: '',
      messages: const [LlmMessage(role: 'user', content: '在吗')],
      tools: const [],
      forceTool: null,
      allowToolCalls: true,
      stream: false,
    );
    expect(body['max_output_tokens'], 2048);
  });

  test('填了模型名才算配置好，令牌与地址不随配置保存', () {
    const opened = LlmConfig(
      apiKey: 'access-test',
      endpoint: 'https://x/v1/llm',
    );
    expect(opened.isConfigured, isTrue);
    expect(
      opened.toJson().keys,
      unorderedEquals(['model', 'allow_images', 'context_window_tokens']),
    );
    expect(LlmConfig.fromJson(opened.toJson()).apiKey, isEmpty);
    expect(LlmConfig.fromJson(opened.toJson()).endpoint, isEmpty);

    const blank = LlmConfig(model: '  ');
    expect(blank.isConfigured, isFalse);
    expect(LlmConfig.fromJson(const {'model': ''}).isConfigured, isFalse);
  });

  test('Keystore 读不出来时返回读取失败，而不是当成没配置', () async {
    final secrets = _MemorySecrets()..failRead = true;
    final store = LlmConfigStore(secrets);
    final read = await store.read();
    expect(read, isA<Failure<LlmConfig?>>());
    expect(read.failureOrNull!.message, '读取模型配置失败');
  });

  test('配置读坏时按读取失败交回，没有配置时返回空值', () async {
    final secrets = _MemorySecrets()..value = '不是 JSON';
    final store = LlmConfigStore(secrets);
    expect(await store.read(), isA<Failure<LlmConfig?>>());

    secrets.value = '';
    final empty = await store.read();
    expect(empty.isSuccess, isTrue);
    expect(empty.valueOrNull, isNull);
  });

  test('一次读取失败沿用上一次读到的配置，删掉后仍返回空', () async {
    final secrets = _MemorySecrets();
    final service = AiChatService(store: LlmConfigStore(secrets));
    const config = LlmConfig(model: 'zhixin-chat');
    await service.store.save(config);
    expect((await service.config()).valueOrNull, isNotNull);
    expect((await service.config()).valueOrNull!.model, 'zhixin-chat');

    secrets.failRead = true;
    final failed = await service.config();
    expect(failed, isA<Failure<LlmConfig?>>());
    // 失败的那一次不再交出配置，回答路径用失败前的快照兜底。
    expect(failed.valueOrNull, isNull);
    expect(service.configSnapshot!.model, 'zhixin-chat');

    secrets.failRead = false;
    await service.store.clear();
    expect((await service.config()).valueOrNull, isNull);
  });
}
