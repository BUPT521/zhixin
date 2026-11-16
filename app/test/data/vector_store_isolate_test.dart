import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/vector/sqlite_vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/data/vector/vector_store_isolate.dart';
import 'package:zhixin/domain/rules/embedding.dart';

const _spec = EmbeddingModelSpec(id: 'isolate-embed', dim: 4, provider: 'test');

const _locator = SemanticLocator(
  kind: 'message',
  sourceKey: 'message:msg-1',
  conversationId: 'conv-1',
  messageId: 'msg-1',
);

/// 向量库整体在后台 isolate 里：界面侧只拿到句柄，打开、建表、写入与查询都
/// 不经过界面线程；打不开时把可捕获的异常交回调用方。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('后台 isolate 打开、写入与查询索引', () async {
    final directory = await Directory.systemTemp.createTemp('zhixin-vec-iso-');
    addTearDown(() => directory.delete(recursive: true));
    final store = await IsolateVectorStore.open(
      path: '${directory.path}/index.db',
      spec: _spec,
    );
    addTearDown(store.close);

    await store.replaceSource(
      locator: _locator,
      sourceVersion: 'v1',
      chunks: const ['熵是系统混乱程度的度量。'],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: '2026-11-14 10:00:00',
    );

    expect(await store.entryCount(), 1);
    expect(store.spec.indexKey, contains('isolate-embed'));
    final sources = await store.indexedSources(['missing', _locator.sourceKey]);
    expect(sources.keys, [_locator.sourceKey]);
    expect(sources['message:msg-1']?.sourceVersion, 'v1');
    expect(sources['message:msg-1']?.chunks, 1);

    final matches = await store.search([0.99, 0.05, 0, 0], k: 3);
    expect(matches, hasLength(1));
    expect(matches.single.sourceKey, 'message:msg-1');
    expect(
      matches.single.locatorJson,
      contains('"source_key":"message:msg-1"'),
    );
    expect(matches.single.distance, lessThan(0.1));

    await store.close();
    expect(File('${directory.path}/index.db').existsSync(), isTrue);
  });

  test('切换嵌入模型与维度时清空旧索引并重建结构', () {
    final dir = Directory.systemTemp.createTempSync('zhixin_vec_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/index.db';

    final first = SqliteVectorIndex.open(path: path, spec: _spec);
    first.replaceSource(
      locator: const SemanticLocator(
        kind: 'message',
        sourceKey: 'message:msg-1',
        conversationId: 'conv-1',
        messageId: 'msg-1',
      ),
      sourceVersion: 'v1',
      chunks: const ['熵增'],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: '2026-11-12 10:00:00',
    );
    expect(first.entryCount, 1);
    first.close();

    final second = SqliteVectorIndex.open(
      path: path,
      spec: const EmbeddingModelSpec(id: 'another-embed', dim: 8),
    );
    addTearDown(second.close);
    expect(second.entryCount, 0);
    expect(second.spec.indexKey, contains('another-embed'));
    second.replaceSource(
      locator: const SemanticLocator(
        kind: 'message',
        sourceKey: 'message:msg-1',
        conversationId: 'conv-1',
        messageId: 'msg-1',
      ),
      sourceVersion: 'v2',
      chunks: const ['熵增'],
      vectors: const [
        [1, 0, 0, 0, 0, 0, 0, 0],
      ],
      createdAt: '2026-11-12 10:00:00',
    );
    expect(second.search([1, 0, 0, 0, 0, 0, 0, 0], k: 1), hasLength(1));
  });

  test('刷新统计随索引持久化，清理返回向量数', () async {
    final directory = await Directory.systemTemp.createTemp('zhixin-vec-iso-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/index.db';
    final store = await IsolateVectorStore.open(path: path, spec: _spec);
    addTearDown(store.close);

    const builtAt = '2026-11-16 10:00:00';
    await store.replaceSource(
      locator: _locator,
      sourceVersion: 'v1',
      chunks: const ['片段一', '片段二'],
      vectors: const [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
      ],
      createdAt: builtAt,
    );
    await store.finishRefresh(
      builtAt: builtAt,
      sourceCount: 1,
      writtenEntries: 2,
    );
    await store.close();

    final reopened = await IsolateVectorStore.open(path: path, spec: _spec);
    addTearDown(reopened.close);
    expect(await reopened.sourceCount(), 1);
    expect(await reopened.meta('built_at'), builtAt);
    expect(await reopened.pruneSources({}), 2);
    await reopened.clear();
    expect(await reopened.entryCount(), 0);
    expect(await reopened.sourceCount(), 0);
    expect(await reopened.meta('built_at'), isNull);
  });

  test('索引打不开时把异常交回调用方', () async {
    final directory = await Directory.systemTemp.createTemp('zhixin-vec-fail-');
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      IsolateVectorStore.open(
        path: '${directory.path}/missing/index.db',
        spec: _spec,
      ),
      throwsA(isA<VectorStoreFailure>()),
    );
  });
}
