import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/embedding_settings.dart';
import 'package:zhixin/application/semantic_index_service.dart';
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
    final semantic = SemanticIndexService(
      repository: EvidenceRepository(db),
      indexPath: '',
      vectorStoreOpener: () async => DirectVectorStore(MemoryVectorIndex(spec)),
    );
    final service = EmbeddingSettingsService(
      store: EmbeddingConfigStore(_MemorySecrets()),
      semantic: semantic,
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

    await semantic.close();
    await db.close();
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
