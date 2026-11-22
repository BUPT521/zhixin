import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/application/embedding_settings.dart';
import 'package:zhixin/application/search_index_service.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/vector/embedding_config_store.dart';
import 'package:zhixin/data/vector/memory_vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/domain/rules/embedding.dart';

import '../support/test_db.dart';

/// 语义索引配置的入口：保存一次同时写入存储并换掉嵌入来源，页面不再分别调用
/// 数据层与 `AppScopeState`。
void main() {
  test('保存配置时写入存储并应用，停用后索引按未配置处理', () async {
    final db = await openTestDb();
    final spec = EmbeddingModelSpec(
      id: 'local-hash-v1',
      dim: 4,
      provider: 'local',
    );
    final index = SearchIndexService(
      repository: EvidenceRepository(db),
      indexPath: '',
      vectorStoreOpener: () async => DirectVectorStore(MemoryVectorIndex(spec)),
    );
    final service = EmbeddingSettingsService(
      store: EmbeddingConfigStore(_MemorySecrets()),
      index: index,
    );

    await service.save(
      const EmbeddingConfig(enabled: true, provider: 'local', dim: 4),
    );
    expect(service.current?.dim, 4);
    expect(service.configured, isTrue);
    expect((await service.read())?.provider, 'local');

    await service.save(
      const EmbeddingConfig(enabled: false, provider: 'local'),
    );
    expect(service.configured, isFalse);
    expect((await service.read())?.enabled, isFalse);

    await index.close();
    await db.close();
  });

  test('知新服务作为嵌入来源：只要模型名，地址与令牌运行时取，索引键单独区分', () async {
    const config = EmbeddingConfig(
      enabled: true,
      provider: 'server',
      model: 'bge-m3',
      dim: 4,
      shareScope: EmbeddingShareScope.all,
    );
    expect(config.usesServer, isTrue);
    expect(config.sendsText, isTrue);
    expect(config.usable, isTrue);
    expect(config.spec.indexKey, startsWith('server:bge-m3|4|'));
    // 模型名缺省时维度与来源照旧可读，但这一来源不可用。
    expect(
      const EmbeddingConfig(enabled: true, provider: 'server').usable,
      isFalse,
    );

    final restored = EmbeddingConfig.fromJson(config.toJson())!;
    expect(restored.provider, 'server');
    expect(restored.model, 'bge-m3');
    expect(restored.shareScope, EmbeddingShareScope.all);
    // 不认识的来源按知新服务处理，旧版本写下的自填接口配置也落到这一来源；
    // 地址与 key 不再保存，读出来自然丢掉。
    expect(
      EmbeddingConfig.fromJson({'provider': 'unknown'})!.provider,
      'server',
    );
    final legacy = EmbeddingConfig.fromJson({
      'enabled': true,
      'provider': 'remote',
      'base_url': 'https://embed.example.com/v1',
      'api_key': 'sk-legacy',
      'model': 'bge-m3',
      'dim': 4,
    })!;
    expect(legacy.provider, 'server');
    expect(legacy.toJson().containsKey('base_url'), isFalse);
    expect(legacy.toJson().containsKey('api_key'), isFalse);

    // 测试装配没有给账号服务时，知新服务按不可用处理，不会退回别的地址。
    expect(embeddingRuntime(config).client, isNull);

    var asked = 0;
    final runtime = embeddingRuntime(
      config,
      serverEndpoint: () async {
        asked++;
        return (endpoint: 'http://server.test/v1/llm', apiKey: 'token');
      },
    );
    expect(runtime.client, isA<RemoteEmbeddingClient>());
    expect(runtime.client!.spec.provider, 'server');
    expect(asked, 0, reason: '构造时不取令牌，请求时才取');
    runtime.client!.dispose();
  });
}

class _MemorySecrets implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
