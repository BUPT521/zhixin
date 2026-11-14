import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/data/vector/vector_store_isolate.dart';
import 'package:zhixin/domain/rules/embedding.dart';

const _spec = EmbeddingModelSpec(id: 'isolate-embed', dim: 4, provider: 'test');

const _locator = SemanticLocator(
  kind: 'message',
  sourceKey: 'message:1',
  conversationId: 1,
  messageId: 1,
);

/// 向量库整体在后台 isolate 里：界面侧只拿到句柄，打开、建表、写入与查询都
/// 不经过界面线程；打不开时把可捕获的异常交回调用方。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

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
    expect(await store.meta('model_key'), contains('isolate-embed'));
    final sources = await store.indexedSources();
    expect(sources['message:1']?.sourceVersion, 'v1');
    expect(sources['message:1']?.chunks, 1);

    final matches = await store.search([0.99, 0.05, 0, 0], k: 3);
    expect(matches, hasLength(1));
    expect(matches.single.sourceKey, 'message:1');
    expect(matches.single.locatorJson, contains('"source_key":"message:1"'));
    expect(matches.single.distance, lessThan(0.1));

    await store.close();
    expect(File('${directory.path}/index.db').existsSync(), isTrue);
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
