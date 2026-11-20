import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/vector/embedding_codec.dart';
import 'package:zhixin/data/vector/memory_vector_index.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/data/vector/zvec_vector_index.dart';
import 'package:zhixin/domain/rules/embedding.dart';

/// 语义索引的契约测试：同一组用例分别跑内存实现与 zvec 实现。
///
/// 用例范围见 ADR-0022 实施方案第 8 节。内存实现是服务层测试的替身，zvec 实现
/// 是运行时真正使用的索引；两者对同一个调用序列必须给出相同的可观察结果
/// （条数、来源状态、检索来源集合、统计），服务层才不需要区分引擎。
///
/// 关键词与向量拆成两个 collection（ADR-0030 决定第 4 条）：文本 collection
/// 用 [textOnlyModelSpec] 打开，只接受正文、提供 [VectorIndex.searchText]；
/// 向量 collection 用嵌入来源的 spec 打开，只接受向量与文本哈希、提供
/// [VectorIndex.search]。写入辅助函数同时给两套参数，各实现取自己那一组。
///
/// zvec 实现需要本机 C 库：设置 `ZVEC_LIBRARY_PATH` 指向 `zvec_c_api.dll`
/// （Linux 为 `libzvec_c_api.so`），并把它的目录加进 `PATH`；没有设置时
/// zvec 两组整体跳过，并打印原因。
const _spec = EmbeddingModelSpec(
  id: 'contract-embed',
  dim: 4,
  provider: 'test',
);

const _specB = EmbeddingModelSpec(
  id: 'contract-embed-b',
  dim: 8,
  provider: 'test',
);

const _createdAt = '2026-11-16 10:00:00';
const _builtAt = '2026-11-16 10:05:00';

const _pageA = SemanticLocator(
  kind: 'material_page',
  sourceKey: 'material_page:mat-a:1',
  materialId: 'mat-a',
  pageNo: 1,
);

const _pageB = SemanticLocator(
  kind: 'material_page',
  sourceKey: 'material_page:mat-b:1',
  materialId: 'mat-b',
  pageNo: 1,
);

const _message = SemanticLocator(
  kind: 'message',
  sourceKey: 'message:msg-1',
  conversationId: 'conv-1',
  messageId: 'msg-1',
);

const _attempt = SemanticLocator(
  kind: 'answer',
  sourceKey: 'attempt:att-1',
  conversationId: 'conv-2',
  attemptId: 'att-1',
);

final _unitVector = [1.0, 0.0, 0.0, 0.0];

/// 没有设置库路径时返回跳过原因；设置了但文件不存在也跳过，提示路径写错。
String? _zvecSkipReason() {
  final path = Platform.environment['ZVEC_LIBRARY_PATH'];
  if (path == null || path.trim().isEmpty) {
    return '没有设置 ZVEC_LIBRARY_PATH，跳过 zvec 索引实现；'
        '本机把它指向 sdk-windows-amd64/lib/zvec_c_api.dll，并把该 lib 目录加进 PATH';
  }
  if (!File(path).existsSync()) {
    return 'ZVEC_LIBRARY_PATH 指向的文件不存在：$path';
  }
  return null;
}

/// 写入一个来源的片段；与 `SearchIndexService` 的调用方式一致。
///
/// 文本 collection 取 [chunks]，向量 collection 取按正文算出的哈希与
/// [vectors]，一次调用同时覆盖两套参数。
void _replace(
  VectorIndex index,
  SemanticLocator locator, {
  required String version,
  required List<String> chunks,
  required List<List<double>> vectors,
}) {
  index.replaceSource(
    locator: locator,
    sourceVersion: version,
    chunks: chunks,
    hashes: [for (final chunk in chunks) embeddingTextHash(chunk)],
    vectors: vectors,
    createdAt: _createdAt,
  );
}

/// 检索结果的来源集合；片段也计入，覆盖与缩短片段之后能看出残留。
Set<String> _identities(List<StoredVector> matches) => {
  for (final match in matches) '${match.sourceKey}#${match.chunk}',
};

String _shortHash(EmbeddingModelSpec spec) =>
    sha256.convert(utf8.encode(spec.indexKey)).toString().substring(0, 16);

String _collectionPath(Directory root, EmbeddingModelSpec spec) =>
    p.join(root.path, _shortHash(spec));

String _statePath(Directory root, EmbeddingModelSpec spec) =>
    p.join(root.path, '${_shortHash(spec)}.json');

/// 通用契约：内存实现与 zvec 实现都要满足。
///
/// [open] 收到一个已经存在的空目录，返回打开后的索引；实现可以忽略这个目录。
/// [openTextOnly] 按纯文本索引打开同一个目录，给出时补一条只走关键词的用例。
/// [supportsFilter] 为假时，预过滤用例只要求结果集合包含范围允许的来源
/// （预过滤可以更宽），为真时要求两者相等。
void runVectorIndexContract(
  String label,
  VectorIndex Function(Directory dir) open, {
  VectorIndex Function(Directory dir)? openTextOnly,
  bool supportsFilter = true,
  String? skip,
}) {
  group(label, () {
    late Directory root;
    VectorIndex? index;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('zhixin-vec-contract-');
    });

    tearDown(() async {
      try {
        index?.close();
      } on Object {
        // 用例中途已经关闭或已经失败，收尾不再报错。
      }
      index = null;
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉不影响测试结论。
      }
    });

    VectorIndex openIndex() => index = open(root);

    test('写入、覆盖与缩短片段', () {
      final index = openIndex();
      expect(index.spec.indexKey, _spec.indexKey);
      expect(index.entryCount, 0);

      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      expect(index.entryCount, 2);

      final first = index.search(_unitVector, k: 10);
      expect(_identities(first), {
        '${_pageA.sourceKey}#0',
        '${_pageA.sourceKey}#1',
      });
      // 向量 collection 不存正文，检索结果只带来源、片段号与版本。
      expect(first.first.content, isEmpty);
      expect(first.first.sourceVersion, 'v1');
      expect(first.first.chunk, 0);
      expect(first.first.distance, lessThan(0.001));
      expect(first.first.locatorJson, contains(_pageA.sourceKey));

      final indexed = index.indexedSources([
        _pageA.sourceKey,
        'material_page:missing:1',
      ]);
      expect(indexed.keys, [_pageA.sourceKey]);
      expect(indexed[_pageA.sourceKey]!.sourceVersion, 'v1');
      expect(indexed[_pageA.sourceKey]!.chunks, 2);

      // 同一个来源写入更少的片段：旧的多余片段必须被删掉。
      _replace(
        index,
        _pageA,
        version: 'v2',
        chunks: const ['乙-0'],
        vectors: const [
          [0, 1, 0, 0],
        ],
      );
      expect(index.entryCount, 1);
      final second = index.search(const [0, 1, 0, 0], k: 10);
      expect(second, hasLength(1));
      expect(second.single.content, isEmpty);
      expect(second.single.sourceVersion, 'v2');
      expect(second.single.chunk, 0);
      expect(
        index.indexedSources([_pageA.sourceKey])[_pageA.sourceKey]!.chunks,
        1,
      );
    }, skip: skip);

    test('片段清空即删除来源', () {
      final index = openIndex();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v1',
        chunks: const ['乙-0'],
        vectors: const [
          [0.8, 0.2, 0, 0],
        ],
      );
      expect(index.entryCount, 3);

      _replace(
        index,
        _pageA,
        version: 'v2',
        chunks: const [],
        vectors: const [],
      );
      expect(index.entryCount, 1);
      expect(index.indexedSources([_pageA.sourceKey]), isEmpty);
      expect(_identities(index.search(_unitVector, k: 10)), {
        '${_pageB.sourceKey}#0',
      });
    }, skip: skip);

    test('pruneSources 返回删除的向量条数', () {
      final index = openIndex();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v1',
        chunks: const ['乙-0', '乙-1', '乙-2'],
        vectors: const [
          [0, 0, 1, 0],
          [0, 0, 0, 1],
          [0.5, 0.5, 0, 0],
        ],
      );
      expect(index.entryCount, 5);

      // 删除 pageA 的两条，返回删除条数而不是来源数。
      expect(index.pruneSources({_pageB.sourceKey}), 2);
      expect(index.entryCount, 3);
      expect(_identities(index.search(_unitVector, k: 10)), {
        '${_pageB.sourceKey}#0',
        '${_pageB.sourceKey}#1',
        '${_pageB.sourceKey}#2',
      });

      // 没有可删的来源时返回 0。
      expect(index.pruneSources({_pageB.sourceKey}), 0);

      // keep 为空等同于清空，返回清空前的向量条数。
      expect(index.pruneSources(const {}), 3);
      expect(index.entryCount, 0);
      expect(index.search(_unitVector, k: 10), isEmpty);
    }, skip: skip);

    test('indexedSources 按 500 个键一批读取并忽略不存在的键', () {
      final index = openIndex();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v2',
        chunks: const ['乙-0', '乙-1', '乙-2'],
        vectors: const [
          [0, 1, 0, 0],
          [0, 0, 1, 0],
          [0, 0, 0, 1],
        ],
      );

      expect(index.indexedSources(const []), isEmpty);
      final keys = [
        _pageA.sourceKey,
        _pageB.sourceKey,
        for (var number = 0; number < 998; number++)
          'material_page:missing-$number:1',
      ];
      final indexed = index.indexedSources(keys);
      expect(indexed, hasLength(2));
      expect(indexed[_pageA.sourceKey]!.sourceVersion, 'v1');
      expect(indexed[_pageA.sourceKey]!.chunks, 2);
      expect(indexed[_pageB.sourceKey]!.sourceVersion, 'v2');
      expect(indexed[_pageB.sourceKey]!.chunks, 3);
    }, skip: skip);

    test('search 的无过滤与三种预过滤', () {
      final index = openIndex();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0'],
        vectors: const [
          [1, 0, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v1',
        chunks: const ['乙-0'],
        vectors: const [
          [0.8, 0.2, 0, 0],
        ],
      );
      _replace(
        index,
        _message,
        version: 'v1',
        chunks: const ['消息-0'],
        vectors: const [
          [0.6, 0.4, 0, 0],
        ],
      );
      _replace(
        index,
        _attempt,
        version: 'v1',
        chunks: const ['作答-0'],
        vectors: const [
          [0.4, 0.6, 0, 0],
        ],
      );

      final all = _identities(index.search(_unitVector, k: 10));
      expect(all, hasLength(4));

      // 材料范围：只排除其他材料的材料页，消息与作答放行。
      final material = _identities(
        index.search(
          _unitVector,
          k: 10,
          prefilter: const MaterialVectorPrefilter('mat-a'),
        ),
      );
      final allowedByMaterial = {
        '${_pageA.sourceKey}#0',
        '${_message.sourceKey}#0',
        '${_attempt.sourceKey}#0',
      };
      if (supportsFilter) {
        expect(material, allowedByMaterial);
      } else {
        expect(material.containsAll(allowedByMaterial), isTrue);
        expect(material.length, lessThanOrEqualTo(all.length));
      }

      // 回答前检索：当前讨论的来源与本轮带入的来源。
      final conversation = _identities(
        index.search(
          _unitVector,
          k: 10,
          prefilter: ConversationVectorPrefilter(
            conversationId: 'conv-1',
            sourceKeys: {_pageB.sourceKey},
          ),
        ),
      );
      final allowedByConversation = {
        '${_message.sourceKey}#0',
        '${_pageB.sourceKey}#0',
      };
      if (supportsFilter) {
        expect(conversation, allowedByConversation);
      } else {
        expect(conversation.containsAll(allowedByConversation), isTrue);
      }

      // 记忆召回：只放行给定的来源键，空集合一条也不放行。
      final bySourceKeys = _identities(
        index.search(
          _unitVector,
          k: 10,
          prefilter: SourceKeysVectorPrefilter([
            _attempt.sourceKey,
            _pageA.sourceKey,
          ]),
        ),
      );
      if (supportsFilter) {
        expect(bySourceKeys, {
          '${_attempt.sourceKey}#0',
          '${_pageA.sourceKey}#0',
        });
        expect(
          index.search(
            _unitVector,
            k: 10,
            prefilter: SourceKeysVectorPrefilter(const []),
          ),
          isEmpty,
        );
      } else {
        expect(bySourceKeys.containsAll({'${_attempt.sourceKey}#0'}), isTrue);
      }
    }, skip: skip);

    test('search 只走向量一路，关键词集合对它是空的', () {
      final index = openIndex();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['矩阵的秩'],
        vectors: const [
          [1, 0, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v1',
        chunks: const ['天气与出行'],
        vectors: const [
          [0.9, 0.1, 0, 0],
        ],
      );
      _replace(
        index,
        _message,
        version: 'v1',
        chunks: const ['线性代数'],
        vectors: const [
          [0, 1, 0, 0],
        ],
      );

      // 向量一路自己就能给出候选：查询向量接近哪一段，哪一段排在最前。
      final nearest = index.search(const [0, 1, 0, 0], k: 3);
      expect(nearest.first.sourceKey, _message.sourceKey);
      expect(
        nearest.map((match) => match.sourceKey),
        contains(_pageA.sourceKey),
      );

      // 向量 collection 不存正文，也没有全文索引，关键词一路对它没有结果。
      expect(index.searchText('矩阵', k: 10), isEmpty);
      expect(index.searchText('线性代数', k: 10), isEmpty);

      // 预过滤在向量一路同样生效。
      final filtered = index.search(
        const [0, 1, 0, 0],
        k: 10,
        prefilter: const MaterialVectorPrefilter('mat-b'),
      );
      final filteredKeys = {for (final match in filtered) match.sourceKey};
      expect(filteredKeys, isNot(contains(_pageA.sourceKey)));
      expect(filteredKeys, contains(_pageB.sourceKey));
    }, skip: skip);

    if (openTextOnly != null) {
      test('searchText 只走关键词一路，向量集合对它是空的', () {
        final textIndex = openTextOnly(root);
        addTearDown(textIndex.close);
        _replace(
          textIndex,
          _pageA,
          version: 'v1',
          chunks: const ['矩阵的秩'],
          vectors: const [],
        );
        _replace(
          textIndex,
          _pageB,
          version: 'v1',
          chunks: const ['天气与出行'],
          vectors: const [],
        );

        // 关键词检索走索引的全文子查询，不需要向量，分数越大越相关。
        final hits = textIndex.searchText('矩阵', k: 10);
        expect(hits.map((match) => match.sourceKey), [_pageA.sourceKey]);
        expect(hits.single.content, '矩阵的秩');
        expect(hits.single.score, greaterThan(0));
        // 没有向量字段时向量检索没有结果，正文里没有查询词时也不命中。
        expect(textIndex.search(_unitVector, k: 10), isEmpty);
        expect(textIndex.searchText('拓扑', k: 10), isEmpty);

        // 记忆召回按来源键把排序限制在本次候选里，空候选一条也不返回。
        final scoped = textIndex.searchText(
          '矩阵',
          k: 10,
          prefilter: SourceKeysVectorPrefilter([_pageA.sourceKey]),
        );
        expect(scoped.map((match) => match.sourceKey), [_pageA.sourceKey]);
        expect(
          textIndex.searchText(
            '矩阵',
            k: 10,
            prefilter: SourceKeysVectorPrefilter(const []),
          ),
          isEmpty,
        );
      }, skip: skip);
    }

    test('统计在 finishRefresh 之后写入，clear 之后归零', () {
      final index = openIndex();
      expect(index.sourceCount, 0);
      expect(index.meta('epoch'), '0');

      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      _replace(
        index,
        _pageB,
        version: 'v1',
        chunks: const ['乙-0'],
        vectors: const [
          [0, 1, 0, 0],
        ],
      );
      index.finishRefresh(builtAt: _builtAt, sourceCount: 2, writtenEntries: 3);
      expect(index.sourceCount, 2);
      expect(index.meta('built_at'), _builtAt);
      expect(index.meta('source_count'), '2');

      index.setMeta('epoch', '7');
      expect(index.meta('epoch'), '7');

      index.clear();
      expect(index.entryCount, 0);
      expect(index.sourceCount, 0);
      expect(index.meta('built_at'), isNull);
      expect(index.meta('source_count'), '0');
      expect(index.search(_unitVector, k: 10), isEmpty);
    }, skip: skip);

    test('元数据只接受规定的键', () {
      final index = openIndex();
      expect(() => index.meta('model_key'), throwsArgumentError);
      expect(() => index.setMeta('dim', '4'), throwsArgumentError);
    }, skip: skip);
  });
}

/// zvec 独占的用例：磁盘布局、生命周期与损坏恢复在内存实现里没有对应概念。
void _runZvecOnlyTests(String? skip) {
  group('zvec 磁盘与生命周期', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('zhixin-vec-zvec-');
    });

    tearDown(() {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉不影响测试结论。
      }
    });

    ZvecVectorIndex openZvec({
      EmbeddingModelSpec spec = _spec,
      void Function(String reason)? onRebuild,
    }) => ZvecVectorIndex.open(
      rootPath: root.path,
      spec: spec,
      onRebuild: onRebuild,
    );

    /// 打开、写入两段并结算统计；返回关闭前的索引。
    ZvecVectorIndex writeAndClose() {
      final index = openZvec();
      _replace(
        index,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      index.finishRefresh(builtAt: _builtAt, sourceCount: 1, writtenEntries: 2);
      index.close();
      return index;
    }

    test('关闭后重开，已写入的来源与统计仍在', () {
      writeAndClose();
      final reasons = <String>[];
      final reopened = openZvec(onRebuild: reasons.add);
      addTearDown(reopened.close);

      expect(reasons, isEmpty);
      expect(reopened.entryCount, 2);
      expect(reopened.sourceCount, 1);
      expect(reopened.meta('built_at'), _builtAt);
      expect(
        reopened.indexedSources([
          _pageA.sourceKey,
        ])[_pageA.sourceKey]!.sourceVersion,
        'v1',
      );
      expect(_identities(reopened.search(_unitVector, k: 10)), {
        '${_pageA.sourceKey}#0',
        '${_pageA.sourceKey}#1',
      });
    }, skip: skip);

    test('旧状态文件里的已处理提交编号仍能读，重写时不再带它', () {
      // 迁移之前的状态文件里有 `commit_id`：同一版本内产生的旧文件要能继续读，
      // 多出来的键被忽略；已处理到的提交编号改记在 `revision_cursor` 的非阻塞
      // 位置，所以任意一次状态写入都按当前字段重写（方案 3.12）。
      writeAndClose();
      final stateFile = File(_statePath(root, _spec));
      final legacy =
          jsonDecode(stateFile.readAsStringSync()) as Map<String, Object?>;
      legacy['commit_id'] = '12';
      stateFile.writeAsStringSync(jsonEncode(legacy));

      final reopened = openZvec();
      addTearDown(reopened.close);
      expect(reopened.sourceCount, 1);
      expect(reopened.meta('built_at'), _builtAt);
      expect(() => reopened.meta('commit_id'), throwsArgumentError);

      reopened.setMeta('epoch', '3');
      final rewritten =
          jsonDecode(stateFile.readAsStringSync()) as Map<String, Object?>;
      expect(rewritten.containsKey('commit_id'), isFalse);
      expect(rewritten['epoch'], '3');
    }, skip: skip);

    test('模型 A→B→A 快速切换后 A 的内容还在', () {
      // 顺序按实施方案第 2 节：A 开着的时候打开 B，B 打开时删不掉 A 的目录；
      // 之后关闭 A 再打开 A，A 的 collection 与状态文件应当完整。
      final a = openZvec();
      addTearDown(a.close);
      _replace(
        a,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0', '甲-1'],
        vectors: const [
          [1, 0, 0, 0],
          [0, 1, 0, 0],
        ],
      );
      a.finishRefresh(builtAt: _builtAt, sourceCount: 1, writtenEntries: 2);

      final b = openZvec(spec: _specB);
      addTearDown(b.close);
      _replace(
        b,
        _pageB,
        version: 'v1',
        chunks: const ['乙-0'],
        vectors: const [
          [1, 0, 0, 0, 0, 0, 0, 0],
        ],
      );

      a.close();
      final reopenedA = openZvec();
      addTearDown(reopenedA.close);
      expect(reopenedA.entryCount, 2);
      expect(reopenedA.sourceCount, 1);
      expect(_identities(reopenedA.search(_unitVector, k: 10)), {
        '${_pageA.sourceKey}#0',
        '${_pageA.sourceKey}#1',
      });
      b.close();
    }, skip: skip);

    test('同一目录被另一个句柄占用时报“索引正被占用”且目录还在', () {
      final first = openZvec();
      addTearDown(first.close);
      _replace(
        first,
        _pageA,
        version: 'v1',
        chunks: const ['甲-0'],
        vectors: const [
          [1, 0, 0, 0],
        ],
      );
      final collectionPath = _collectionPath(root, _spec);
      expect(Directory(collectionPath).existsSync(), isTrue);

      final stopwatch = Stopwatch()..start();
      expect(
        () => openZvec(),
        throwsA(
          isA<VectorStoreFailure>().having(
            (error) => error.toString(),
            'toString',
            contains('索引正被占用'),
          ),
        ),
      );
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        greaterThan(const Duration(milliseconds: 2000)),
        reason: '占用时按退避重试约 3 秒',
      );
      // 被占用不是损坏：目录不能被删掉，否则下一次刷新要全部重新嵌入。
      expect(Directory(collectionPath).existsSync(), isTrue);
      expect(first.entryCount, 1);
      expect(_identities(first.search(_unitVector, k: 10)), {
        '${_pageA.sourceKey}#0',
      });
    }, skip: skip);

    test('删掉 manifest.1 后打开得到空索引并通知重建一次', () {
      writeAndClose();
      final manifest = File(p.join(_collectionPath(root, _spec), 'manifest.1'));
      expect(manifest.existsSync(), isTrue);
      manifest.deleteSync();

      final reasons = <String>[];
      final rebuilt = openZvec(onRebuild: reasons.add);
      addTearDown(rebuilt.close);
      expect(reasons, hasLength(1));
      expect(reasons.single, isNotEmpty);
      expect(rebuilt.entryCount, 0);
      expect(rebuilt.search(_unitVector, k: 10), isEmpty);
      expect(Directory(_collectionPath(root, _spec)).existsSync(), isTrue);
    }, skip: skip);

    test('删掉段目录 0/ 后打开得到空索引并通知重建一次', () {
      writeAndClose();
      final segment = Directory(p.join(_collectionPath(root, _spec), '0'));
      expect(segment.existsSync(), isTrue);
      segment.deleteSync(recursive: true);

      final reasons = <String>[];
      final rebuilt = openZvec(onRebuild: reasons.add);
      addTearDown(rebuilt.close);
      expect(reasons, hasLength(1));
      expect(reasons.single, isNotEmpty);
      expect(rebuilt.entryCount, 0);
      expect(rebuilt.search(_unitVector, k: 10), isEmpty);
    }, skip: skip);

    test('状态文件写成非法 JSON 后打开得到空索引并通知重建一次', () {
      writeAndClose();
      final stateFile = File(_statePath(root, _spec));
      expect(stateFile.existsSync(), isTrue);
      stateFile.writeAsStringSync('{ 这不是 JSON');

      final reasons = <String>[];
      final rebuilt = openZvec(onRebuild: reasons.add);
      addTearDown(rebuilt.close);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('状态文件'));
      expect(rebuilt.entryCount, 0);
      expect(rebuilt.search(_unitVector, k: 10), isEmpty);
      // 重建之后状态文件恢复成可解析的内容。
      expect(() => jsonDecode(stateFile.readAsStringSync()), returnsNormally);
    }, skip: skip);

    test('两种实现的检索来源集合一致', () {
      final memory = MemoryVectorIndex(_spec);
      addTearDown(memory.close);
      final zvec = openZvec();
      addTearDown(zvec.close);

      for (final index in [memory, zvec]) {
        _replace(
          index,
          _pageA,
          version: 'v1',
          chunks: const ['甲-0'],
          vectors: const [
            [1, 0, 0, 0],
          ],
        );
        _replace(
          index,
          _pageB,
          version: 'v1',
          chunks: const ['乙-0'],
          vectors: const [
            [0.8, 0.2, 0, 0],
          ],
        );
        _replace(
          index,
          _message,
          version: 'v1',
          chunks: const ['消息-0'],
          vectors: const [
            [0.6, 0.4, 0, 0],
          ],
        );
        _replace(
          index,
          _attempt,
          version: 'v1',
          chunks: const ['作答-0'],
          vectors: const [
            [0.4, 0.6, 0, 0],
          ],
        );
      }

      final prefilters = <String, VectorPrefilter?>{
        '无过滤': null,
        '材料范围': const MaterialVectorPrefilter('mat-a'),
        '回答前检索': ConversationVectorPrefilter(
          conversationId: 'conv-1',
          sourceKeys: {_pageB.sourceKey},
        ),
        '记忆候选': SourceKeysVectorPrefilter([
          _pageA.sourceKey,
          _attempt.sourceKey,
        ]),
      };
      for (final entry in prefilters.entries) {
        final expected = _identities(
          memory.search(_unitVector, k: 10, prefilter: entry.value),
        );
        final actual = _identities(
          zvec.search(_unitVector, k: 10, prefilter: entry.value),
        );
        expect(actual, unorderedEquals(expected), reason: entry.key);
      }
    }, skip: skip);
  });
}

void main() {
  final reason = _zvecSkipReason();
  if (reason != null) {
    // 跳过时也把原因打印出来，看输出就知道是环境没配好还是用例真的失败了。
    stdout.writeln(reason);
  }

  runVectorIndexContract(
    '内存索引',
    (dir) => MemoryVectorIndex(_spec),
    openTextOnly: (dir) => MemoryVectorIndex(textOnlyModelSpec),
  );

  runVectorIndexContract(
    'zvec 索引',
    (dir) => ZvecVectorIndex.open(rootPath: dir.path, spec: _spec),
    openTextOnly: (dir) =>
        ZvecVectorIndex.open(rootPath: dir.path, spec: textOnlyModelSpec),
    skip: reason,
  );

  _runZvecOnlyTests(reason);
}
