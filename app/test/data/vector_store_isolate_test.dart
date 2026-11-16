import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

const _builtAt = '2026-11-16 10:00:00';

/// 没有设置库路径时返回跳过原因；zvec 实现打开索引需要本机 C 库。
String? _zvecSkipReason() {
  final path = Platform.environment['ZVEC_LIBRARY_PATH'];
  if (path == null || path.trim().isEmpty) {
    return '没有设置 ZVEC_LIBRARY_PATH，跳过真实 zvec 的后台 isolate 用例';
  }
  if (!File(path).existsSync()) {
    return 'ZVEC_LIBRARY_PATH 指向的文件不存在：$path';
  }
  return null;
}

/// 向量库整体在后台 isolate 里：界面侧只拿到句柄，打开、写入与查询都不经过
/// 界面线程；打不开时把可捕获的异常交回调用方。
///
/// zvec 的引擎按进程初始化一次，后台 isolate 退出时不调用 `Zvec.shutdown`：
/// 两个 isolate 先后打开、关闭之后，同一个进程里再开第三个仍然可用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _zvecSkipReason();
  if (skip != null) stdout.writeln(skip);

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-vec-iso-');
  });

  tearDown(() async {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录删不掉不影响测试结论。
    }
  });

  /// 索引根目录：`filesDir/vector_index/` 这一层，不是 collection 本身。
  String indexPath() => '${directory.path}/vector_index';

  test('后台 isolate 打开、写入与查询索引', () async {
    final store = await IsolateVectorStore.open(
      path: indexPath(),
      spec: _spec,
      logDirectory: '${directory.path}/zvec_logs',
    );
    addTearDown(store.close);

    expect(store.spec.indexKey, contains('isolate-embed'));
    await store.replaceSource(
      locator: _locator,
      sourceVersion: 'v1',
      chunks: const ['熵是系统混乱程度的度量。'],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: _builtAt,
    );

    expect(await store.entryCount(), 1);
    final sources = await store.indexedSources(['missing', _locator.sourceKey]);
    expect(sources.keys, [_locator.sourceKey]);
    expect(sources[_locator.sourceKey]!.sourceVersion, 'v1');
    expect(sources[_locator.sourceKey]!.chunks, 1);

    final matches = await store.search([0.99, 0.05, 0, 0], k: 3);
    expect(matches, hasLength(1));
    expect(matches.single.sourceKey, _locator.sourceKey);
    expect(matches.single.content, '熵是系统混乱程度的度量。');
    expect(
      matches.single.locatorJson,
      contains('"source_key":"message:msg-1"'),
    );
    expect(matches.single.distance, lessThan(0.1));

    await store.close();
    expect(Directory(indexPath()).existsSync(), isTrue);
  }, skip: skip);

  test('刷新统计随索引持久化，重启后仍在，清理后归零', () async {
    final first = await IsolateVectorStore.open(path: indexPath(), spec: _spec);
    await first.replaceSource(
      locator: _locator,
      sourceVersion: 'v1',
      chunks: const ['片段一', '片段二'],
      vectors: const [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
      ],
      createdAt: _builtAt,
    );
    await first.finishRefresh(
      builtAt: _builtAt,
      sourceCount: 1,
      writtenEntries: 2,
    );
    expect(await first.entryCount(), 2);
    expect(await first.sourceCount(), 1);
    expect(await first.meta('built_at'), _builtAt);
    await first.close();

    final reopened = await IsolateVectorStore.open(
      path: indexPath(),
      spec: _spec,
    );
    addTearDown(reopened.close);
    expect(await reopened.entryCount(), 2);
    expect(await reopened.sourceCount(), 1);
    expect(await reopened.meta('built_at'), _builtAt);
    expect(
      (await reopened.indexedSources([
        _locator.sourceKey,
      ]))[_locator.sourceKey]!.chunks,
      2,
    );

    expect(await reopened.pruneSources(const {}), 2);
    await reopened.clear();
    expect(await reopened.entryCount(), 0);
    expect(await reopened.sourceCount(), 0);
    expect(await reopened.meta('built_at'), isNull);
  }, skip: skip);

  test('两个 isolate 先后打开、关闭之后，引擎仍可再用', () async {
    final first = await IsolateVectorStore.open(path: indexPath(), spec: _spec);
    await first.replaceSource(
      locator: _locator,
      sourceVersion: 'v1',
      chunks: const ['熵增'],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: _builtAt,
    );
    await first.close();

    final second = await IsolateVectorStore.open(
      path: indexPath(),
      spec: _spec,
    );
    expect(await second.entryCount(), 1);
    expect(await second.search([1, 0, 0, 0], k: 3), hasLength(1));
    await second.close();

    // 前两个 isolate 都已退出；引擎没有被关掉，第三次打开仍然读到原来的内容。
    final third = await IsolateVectorStore.open(path: indexPath(), spec: _spec);
    addTearDown(third.close);
    expect(await third.entryCount(), 1);
    expect(
      (await third.indexedSources([
        _locator.sourceKey,
      ]))[_locator.sourceKey]!.sourceVersion,
      'v1',
    );
  }, skip: skip);

  test('索引路径被文件占住时把异常交回调用方', () async {
    final occupied = File(indexPath())..createSync(recursive: true);
    occupied.writeAsStringSync('不是目录');

    await expectLater(
      IsolateVectorStore.open(path: indexPath(), spec: _spec),
      throwsA(isA<VectorStoreFailure>()),
    );
    expect(occupied.existsSync(), isTrue);
  }, skip: skip);
}
