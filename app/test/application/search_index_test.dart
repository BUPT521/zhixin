import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/application/embedding_settings.dart';
import 'package:zhixin/application/search_index_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/data/vector/embedding_codec.dart';
import 'package:zhixin/data/vector/embedding_config_store.dart';
import 'package:zhixin/data/vector/memory_vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/embedding.dart';

import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

const _spec = EmbeddingModelSpec(id: 'test-embed', dim: 4, provider: 'test');

const _pageEntropy = '熵是系统混乱程度的度量。';
const _pageDerivative = 'f(x)=x² 的导数是 2x。';
const _pageLinear = '矩阵 A 的第 b 列记作 a_b。';
const _messageEntropy = '熵增与时间箭头有关系吗';
const _messageLinear = '矩阵的列向量怎么写';
const _answerProbability = '先求 P(A|B)=P(AB)/P(B)，答案是 0.4。';

Map<String, List<double>> _vectors() => {
  _pageEntropy: [1, 0, 0, 0],
  _pageDerivative: [0, 1, 0, 0],
  _pageLinear: [0.5, 0.5, 0, 0],
  _messageEntropy: [0, 0, 1, 0],
  _messageLinear: [0.4, 0.4, 0.2, 0],
  _answerProbability: [0, 0, 0, 1],
  '例 3-2 的解法': [0, 0.2, 0.8, 0],
  // 同义改写：与“熵是系统混乱程度的度量”意思相同，措辞不同。
  '系统混乱程度怎么衡量': [0.98, 0.1, 0, 0],
};

class _Corpus {
  _Corpus({
    required this.goalProbability,
    required this.goalLinear,
    required this.materialProbability,
    required this.materialLinear,
    required this.entropyPage,
  });

  final String goalProbability;
  final String goalLinear;
  final String materialProbability;
  final String materialLinear;

  /// 熵那一页的行标识，用于直接改写内容模拟更正。
  final String entropyPage;
}

Future<_Corpus> _seed(RawDatabase db) async {
  final tasks = TaskRepository(db);
  final materials = MaterialRepository(db);
  final conversations = ConversationRepository(db);
  final attempts = AttemptRepository(db);
  final probability = await tasks.createGoal(title: '概率论期末');
  final linear = await tasks.createGoal(title: '线性代数作业');
  final materialProbability = await materials.create(
    title: '概率论讲义',
    goalId: probability,
  );
  final entropyPage = await materials.addPage(
    materialId: materialProbability,
    pageNo: 1,
    content: _pageEntropy,
  );
  await materials.addPage(
    materialId: materialProbability,
    pageNo: 2,
    content: _pageDerivative,
  );
  final materialLinear = await materials.create(
    title: '线性代数讲义',
    goalId: linear,
  );
  await materials.addPage(
    materialId: materialLinear,
    pageNo: 1,
    content: _pageLinear,
  );

  final discussion = await conversations.create(title: '熵与时间');
  await conversations.setGoal(discussion, probability);
  await conversations.setMaterial(
    discussion,
    materialId: materialProbability,
    pageNo: 1,
  );
  await conversations.append(
    discussion,
    role: MessageRole.user,
    content: _messageEntropy,
  );

  final question = await conversations.create(sourceRef: '例 3-2');
  await conversations.setGoal(question, probability);
  await conversations.setMaterial(
    question,
    materialId: materialProbability,
    pageNo: 2,
  );
  await conversations.append(
    question,
    role: MessageRole.user,
    content: '例 3-2 的解法',
  );
  final attempt = await attempts.ensureOpenAttempt(question);
  await attempts.submit(
    attempt.id,
    answer: _answerProbability,
    isCorrect: true,
    independent: true,
  );

  final linearDiscussion = await conversations.create(title: '矩阵记号');
  await conversations.setGoal(linearDiscussion, linear);
  await conversations.setMaterial(
    linearDiscussion,
    materialId: materialLinear,
    pageNo: 1,
  );
  await conversations.append(
    linearDiscussion,
    role: MessageRole.user,
    content: _messageLinear,
  );

  return _Corpus(
    goalProbability: probability,
    goalLinear: linear,
    materialProbability: materialProbability,
    materialLinear: materialLinear,
    entropyPage: entropyPage,
  );
}

Future<
  ({
    RawDatabase db,
    EvidenceRepository repository,
    MemoryVectorIndex index,
    MemoryVectorIndex textIndex,
    SearchIndexService service,
    _Corpus corpus,
  })
>
_rig({
  EmbeddingClient Function(EmbeddingModelSpec)? clientFor,
  bool Function(SemanticSource source)? canSend,
  String Function()? epoch,
  Future<bool> Function()? cacheWrites,
}) async {
  final db = await openTestDb();
  final corpus = await _seed(db);
  final repository = EvidenceRepository(db);
  final index = MemoryVectorIndex(_spec);
  final textIndex = MemoryVectorIndex(textOnlyModelSpec);
  final client =
      clientFor?.call(_spec) ??
      FixedEmbeddingClient(spec: _spec, vectors: _vectors());
  final service = SearchIndexService(
    repository: repository,
    initialClient: client,
    indexPath: '',
    epoch: () async => epoch?.call() ?? '0',
    textStoreOpener: () async => DirectVectorStore(textIndex),
    vectorStoreOpener: () async => DirectVectorStore(index),
    initialShareFilter: canSend,
    queryTimeout: const Duration(seconds: 2),
    cacheWrites: cacheWrites,
  );
  return (
    db: db,
    repository: repository,
    index: index,
    textIndex: textIndex,
    service: service,
    corpus: corpus,
  );
}

class _SlowClient extends EmbeddingClient {
  _SlowClient(this.inner);

  final EmbeddingClient inner;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

class _MutatingClient extends EmbeddingClient {
  _MutatingClient({required this.inner, required this.onEmbed});

  final EmbeddingClient inner;
  final Future<void> Function(String text) onEmbed;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    await onEmbed(text);
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

void main() {
  test('固定测试向量验证内存索引写入与查询', () {
    final spec = _spec;
    final index = MemoryVectorIndex(spec);
    addTearDown(index.close);
    final locator = const SemanticLocator(
      kind: 'material_page',
      sourceKey: 'material_page:mat-1:1',
      materialId: 'mat-1',
      pageNo: 1,
    );
    index.replaceSource(
      locator: locator,
      sourceVersion: 'v1',
      chunks: const [_pageEntropy],
      hashes: [embeddingTextHash(_pageEntropy)],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: '2026-11-12 10:00:00',
    );
    final matches = index.search([0.99, 0.05, 0, 0], k: 3);
    expect(matches, hasLength(1));
    expect(matches.single.sourceKey, 'material_page:mat-1:1');
    expect(matches.single.distance, lessThan(0.1));
    expect(index.entryCount, 1);
    expect(index.spec.indexKey, contains('test-embed'));
  });

  test('语义查询能找回同义改写的原文，并按需求合并后带回来源', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    expect(refresh.failure, IndexFailure.none);
    expect(refresh.embedded, 7);

    final result = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      limit: 3,
    );
    expect(result.usable, isTrue);
    expect(result.timings.embedMs, greaterThanOrEqualTo(0));
    expect(result.timings.candidates, greaterThan(0));
    expect(result.entries, 7);
    expect(result.hits, isNotEmpty);
    expect(
      result.hits.first.identity,
      'material_page:${rig.corpus.materialProbability}:1',
    );
    expect(result.hits.first.snippet, contains('熵'));

    final scoped = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalLinear),
      limit: 5,
    );
    expect(
      scoped.hits.any(
        (hit) =>
            hit.identity == 'material_page:${rig.corpus.materialProbability}:1',
      ),
      isFalse,
      reason: '其他目标的材料页不进入本次回答范围',
    );
    expect(
      scoped.hits.any(
        (hit) => hit.identity == 'material_page:${rig.corpus.materialLinear}:1',
      ),
      isTrue,
    );
  });

  test('索引按来源版本增量更新，重复执行不重复写入', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final first = await rig.service.refresh();
    expect(first.embedded, 7);

    final second = await rig.service.refresh();
    expect(second.embedded, 0);
    expect(second.skipped, 7);

    await updateRow(
      rig.db,
      'material_page',
      {'content': '熵衡量系统的混乱程度。', 'updated_at': '2026-11-12 11:00:00'},
      where: 'id = ?',
      whereArgs: [rig.corpus.entropyPage],
    );
    // 固定向量按整段文本匹配，改写后需要新的向量，这里替换客户端的向量表。
    rig.service.configure(
      client: FixedEmbeddingClient(
        spec: _spec,
        vectors: {
          ..._vectors(),
          '熵衡量系统的混乱程度。': [1, 0, 0, 0],
        },
      ),
    );
    final third = await rig.service.refresh();
    expect(third.embedded, 1);
    expect(third.skipped, 6);

    final stats = await rig.service.stats();
    expect(stats.entries, 7);
    expect(stats.sources, 7);
  });

  test('强制重写部分失败时保留旧来源的计数，清空时重置统计', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.service.close);
    expect((await rig.service.refresh()).embedded, 7);

    rig.service.configure(
      client: _MutatingClient(
        inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
        onEmbed: (text) async {
          if (text == _pageEntropy) {
            throw const EmbeddingUnavailable('测试里的嵌入失败');
          }
        },
      ),
    );
    final refresh = await rig.service.refresh(force: true);
    expect(refresh.failed, 1);
    expect(refresh.embedded, 6);
    final retained = await rig.service.stats();
    expect(retained.sources, 7);
    expect(retained.entries, 7);
    expect(retained.builtAt, isNotNull);

    await rig.service.clear();
    final cleared = await rig.service.stats();
    expect(cleared.sources, 0);
    expect(cleared.entries, 0);
    expect(cleared.builtAt, isNull);
  });

  test('清空全部记录前释放两份索引句柄，之后按同一路径重新打开', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    var textOpens = 0;
    var textCloses = 0;
    var vectorOpens = 0;
    var vectorCloses = 0;
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      indexPath: '',
      textStoreOpener: () async {
        textOpens++;
        return _TrackedStore(textIndex, () async => textCloses++);
      },
      vectorStoreOpener: () async {
        vectorOpens++;
        return _TrackedStore(
          MemoryVectorIndex(_spec),
          () async => vectorCloses++,
        );
      },
    );
    addTearDown(service.close);

    expect((await service.refresh()).embedded, 7);
    expect(textOpens, 1);
    expect(vectorOpens, 1);
    await service.release();
    expect(textCloses, 1);
    expect(vectorCloses, 1);
    expect(service.lastRefresh, isNull);

    expect((await service.refresh()).embedded, 7);
    expect(textOpens, 2);
    expect(vectorOpens, 2);
  });

  test('清空索引复用已经打开的句柄，不另开一份', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    var textOpens = 0;
    var vectorOpens = 0;
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    final vectorIndex = MemoryVectorIndex(_spec);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      indexPath: '',
      textStoreOpener: () async {
        textOpens++;
        return DirectVectorStore(textIndex);
      },
      vectorStoreOpener: () async {
        vectorOpens++;
        return DirectVectorStore(vectorIndex);
      },
    );
    addTearDown(service.close);
    await service.refresh();
    expect(textOpens, 1);
    expect(vectorOpens, 1);

    // 清空复用这两个句柄：同一个 collection 同时只允许一个句柄，另开一份会
    // 撞上“索引正被占用”，也会把旧句柄留在后台线程里。
    await service.clear();
    expect(textOpens, 1);
    expect(vectorOpens, 1);
    expect(textIndex.entryCount, 0);
    expect(vectorIndex.entryCount, 0);
  });

  test('限制更新来源数时保留批次以外已有的有效索引', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.service.close);
    expect((await rig.service.refresh()).embedded, 7);

    final refresh = await rig.service.refresh(force: true, maxSources: 1);
    expect(refresh.embedded, 1);
    expect(refresh.removed, 0);
    final stats = await rig.service.stats();
    expect(stats.sources, 7);
    expect(stats.entries, 7);
  });

  test('清空时取消等待嵌入的刷新，之后可重新建索引', () async {
    final embedding = Completer<void>();
    final release = Completer<void>();
    final rig = await _rig(
      clientFor: (spec) => _MutatingClient(
        inner: FixedEmbeddingClient(spec: spec, vectors: _vectors()),
        onEmbed: (_) async {
          if (!embedding.isCompleted) embedding.complete();
          await release.future;
        },
      ),
    );
    addTearDown(rig.db.close);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await rig.service.close();
    });

    final pending = rig.service.refresh();
    await embedding.future;
    final clearing = rig.service.clear();
    release.complete();
    await clearing;
    expect((await pending).failure, IndexFailure.cancelled);
    expect((await rig.service.stats()).entries, 0);
    expect((await rig.service.refresh()).embedded, 7);
    expect((await rig.service.stats()).sources, 7);
  });

  test('模型 A→B→A 等候旧句柄关闭和过期的打开完成', () async {
    const specB = EmbeddingModelSpec(id: 'another-embed', dim: 8);
    final db = await openTestDb();
    addTearDown(db.close);
    final closingA = Completer<void>();
    final releaseA = Completer<void>();
    final openingB = Completer<void>();
    final releaseB = Completer<void>();
    final transitions = <String>[];
    var requestedSpec = _spec;
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: {}),
      indexPath: '',
      textStoreOpener: () async =>
          DirectVectorStore(MemoryVectorIndex(textOnlyModelSpec)),
      vectorStoreOpener: () async {
        final spec = requestedSpec;
        transitions.add('open ${spec.id}');
        if (spec == specB) {
          openingB.complete();
          await releaseB.future;
        }
        return _TrackedStore(MemoryVectorIndex(spec), () async {
          transitions.add('close ${spec.id}');
          if (spec == _spec && !closingA.isCompleted) {
            closingA.complete();
            await releaseA.future;
          }
        });
      },
    );
    addTearDown(() async {
      if (!releaseA.isCompleted) releaseA.complete();
      if (!releaseB.isCompleted) releaseB.complete();
      await service.close();
    });

    // 打开用一次刷新驱动：没有来源时不调用嵌入，只打开两份句柄。
    expect((await service.refresh()).failure, IndexFailure.none);
    expect(transitions, ['open ${_spec.id}']);

    requestedSpec = specB;
    service.configure(
      client: FixedEmbeddingClient(spec: specB, vectors: {}),
    );
    final refreshB = service.refresh();
    await closingA.future;
    expect(openingB.isCompleted, isFalse);
    releaseA.complete();
    await openingB.future;

    requestedSpec = _spec;
    service.configure(
      client: FixedEmbeddingClient(spec: _spec, vectors: {}),
    );
    final refreshA = service.refresh();
    // 上一次的打开还在等 B 释放，A 的第二次打开要排在它后面。
    expect(
      transitions.where((event) => event == 'open ${_spec.id}'),
      hasLength(1),
    );
    releaseB.complete();

    expect((await refreshB).failure, IndexFailure.cancelled);
    expect((await refreshA).failure, IndexFailure.none);
    expect((await service.stats()).modelKey, _spec.indexKey);
    expect(transitions, [
      'open ${_spec.id}',
      'close ${_spec.id}',
      'open ${specB.id}',
      'close ${specB.id}',
      'open ${_spec.id}',
    ]);
  });

  test('查询嵌入期间切换模型时放弃旧查询', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final embedding = Completer<void>();
    final release = Completer<void>();
    const specB = EmbeddingModelSpec(id: 'another-embed', dim: 8);
    var opened = 0;
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: _MutatingClient(
        inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
        onEmbed: (_) async {
          embedding.complete();
          await release.future;
        },
      ),
      indexPath: '',
      textStoreOpener: () async =>
          DirectVectorStore(MemoryVectorIndex(textOnlyModelSpec)),
      vectorStoreOpener: () async {
        opened++;
        return DirectVectorStore(MemoryVectorIndex(specB));
      },
    );
    addTearDown(service.close);

    final search = service.search(
      '系统混乱程度怎么衡量',
      scope: const EvidenceScope.userAll(),
    );
    await embedding.future;
    service.configure(
      client: FixedEmbeddingClient(spec: specB, vectors: {}),
    );
    release.complete();
    expect((await search).failure, IndexFailure.cancelled);
    expect(opened, 0);
    expect((await service.stats()).modelKey, specB.indexKey);
  });

  test('等待嵌入期间来源被更正，迟到结果不写入索引', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final index = MemoryVectorIndex(_spec);
    addTearDown(index.close);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    addTearDown(textIndex.close);
    final client = _MutatingClient(
      inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      onEmbed: (text) async {
        if (text != _pageDerivative) return;
        await updateRow(
          db,
          'material_page',
          {'content': '导数的定义改写了。', 'updated_at': '2026-11-12 12:00:00'},
          where: 'material_id = ? AND page_no = ?',
          whereArgs: [corpus.materialProbability, 2],
        );
      },
    );
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: client,
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
      vectorStoreOpener: () async => DirectVectorStore(index),
    );

    final result = await service.refresh();
    expect(result.lateSkipped, greaterThanOrEqualTo(1));
    // 正文在等待嵌入之前已经写好，因此文本集合仍有这一条；向量因为迟到放弃。
    final stats = await service.stats();
    expect(stats.sources, 7);
    expect(index.sourceCount, 6);
  });

  test('更正后的来源版本与索引不一致时，语义候选不再进入回答', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();

    await updateRow(
      rig.db,
      'material_page',
      {'content': '熵的另一种表述。', 'updated_at': '2026-11-12 13:00:00'},
      where: 'id = ?',
      whereArgs: [rig.corpus.entropyPage],
    );
    final result = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      limit: 5,
    );
    expect(
      result.hits.any(
        (hit) =>
            hit.identity == 'material_page:${rig.corpus.materialProbability}:1',
      ),
      isFalse,
    );
    expect(result.timings.verifiedOut, greaterThanOrEqualTo(1));
  });

  test('查询超时与取消不阻断原文检索', () async {
    final rig = await _rig(
      clientFor: (spec) =>
          _SlowClient(FixedEmbeddingClient(spec: spec, vectors: _vectors())),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();

    final timedOut = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      timeout: const Duration(milliseconds: 30),
    );
    expect(timedOut.usable, isFalse);
    expect(timedOut.failure, IndexFailure.timeout);
    expect(timedOut.hits, isEmpty);
    expect(timedOut.entries, 0);

    final token = IndexCancelToken()..cancel();
    final cancelled = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      cancelToken: token,
    );
    expect(cancelled.failure, IndexFailure.cancelled);

    // 原文与关键词检索不经过嵌入，仍然可用。
    final evidence = await rig.repository.literal(
      '熵',
      scope: const EvidenceScope.userAll(),
    );
    expect(evidence, isNotEmpty);
  });

  test('没有配置嵌入来源时文本集合照常写入与检索，不标按意思', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final repository = EvidenceRepository(db);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    final service = SearchIndexService(
      repository: repository,
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
    );
    addTearDown(service.close);
    final refresh = await service.refresh();
    expect(refresh.failure, IndexFailure.none);
    expect(refresh.embedded, greaterThan(0));
    expect(refresh.textWritten, refresh.embedded);
    expect(textIndex.entryCount, 7);
    final result = await service.search(
      '熵',
      scope: const EvidenceScope.userAll(),
    );
    expect(result.usable, isTrue);
    expect(result.hits, isNotEmpty);
    expect(result.hits.every((hit) => !hit.semantic), isTrue);
    expect(result.entries, 7);
    expect((await service.stats()).configured, isFalse);
  });

  test('文本集合打不开时语义检索退回原文，刷新把异常交给调用方', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      indexPath: '',
      textStoreOpener: () async => throw const VectorStoreFailure('测试里文本索引打不开'),
      vectorStoreOpener: () async =>
          DirectVectorStore(MemoryVectorIndex(_spec)),
    );
    addTearDown(service.close);

    final result = await service.search(
      '系统混乱程度怎么衡量',
      scope: const EvidenceScope.userAll(),
    );
    expect(result.usable, isFalse);
    expect(result.failure, IndexFailure.error);
    expect(result.hits, isEmpty);
    await expectLater(service.refresh(), throwsA(isA<VectorStoreFailure>()));
  });

  test('向量集合打不开时关键词仍然可用，刷新把异常交给调用方', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
      vectorStoreOpener: () async =>
          throw const VectorStoreFailure('测试里向量索引打不开'),
    );
    addTearDown(service.close);

    // 先写正文，再打开向量集合；向量打不开时刷新失败，正文已经是最新的。
    await expectLater(service.refresh(), throwsA(isA<VectorStoreFailure>()));
    expect(textIndex.entryCount, 7);

    final result = await service.search(
      '系统混乱程度怎么衡量',
      scope: const EvidenceScope.userAll(),
    );
    expect(result.usable, isTrue);
    expect(result.failure, IndexFailure.none);
    expect(result.hits, isNotEmpty);
    expect(result.hits.every((hit) => !hit.semantic), isTrue);
  });

  test('数据代次变化后按当前数据重建索引', () async {
    var epoch = '1';
    final rig = await _rig(epoch: () => epoch);
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();
    expect(rig.index.entryCount, 7);

    epoch = '2';
    final rebuilt = await rig.service.refresh();
    expect(rebuilt.embedded, 7);
    expect(rig.index.meta('epoch'), '2');
  });

  test('回答前检索把语义候选与原文命中按来源标识合并', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();
    final evidence = EvidenceService(
      repository: rig.repository,
      index: rig.service,
    );

    final bundle = await evidence.forAnswer(
      query: '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      limit: 5,
      now: DateTime(2026, 11, 8),
    );
    expect(bundle.hits, isNotEmpty);
    expect(bundle.indexFailed, isFalse);
    expect(bundle.timings, isNotNull);
    expect(
      bundle.hits.any(
        (hit) =>
            hit.identity == 'material_page:${rig.corpus.materialProbability}:1',
      ),
      isTrue,
    );
    final identities = bundle.hits.map((hit) => hit.identity).toList();
    expect(identities.toSet().length, identities.length);
  });

  test('远程嵌入只发送用户选定范围内的原文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final index = MemoryVectorIndex(_spec);
    addTearDown(index.close);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    addTearDown(textIndex.close);
    final sent = <String>[];
    final config = EmbeddingConfig(
      enabled: true,
      provider: 'remote',
      baseUrl: 'https://embed.example.com/v1',
      model: _spec.id,
      dim: _spec.dim,
      shareScope: EmbeddingShareScope.selectedMaterials,
      materialIds: [corpus.materialProbability],
    );
    final runtime = embeddingRuntime(config);
    expect(runtime.client, isNotNull);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: _RecordingClient(
        inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
        sent: sent,
      ),
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
      vectorStoreOpener: () async => DirectVectorStore(index),
      initialShareFilter: runtime.canSend,
    );
    addTearDown(service.close);

    final refresh = await service.refresh();
    expect(refresh.failed, 0);
    expect(sent, isNotEmpty);
    // 没有选中材料归属的记录不发送原文。
    expect(sent.any((text) => text.contains('矩阵的列向量')), isFalse);
    // 正文不离开本机：文本集合收下全部来源，向量集合只收允许发送的来源。
    expect(refresh.textWritten, 7);
    expect(index.sourceCount, lessThan(6));
    expect(refresh.embedded, index.sourceCount);
  });

  test('远程嵌入按 OpenAI 兼容格式发送，并拒绝维度不符的响应', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'data': [
            {
              'embedding': [0.1, 0.2, 0.3, 0.4],
            },
          ],
        }),
        200,
      );
    });
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      endpoint: 'https://embed.example.com/v1',
      apiKey: 'test-key',
      httpClient: client,
    );
    final vector = await embedding.embed('熵');
    expect(vector, hasLength(4));
    expect(captured.url.toString(), 'https://embed.example.com/v1/embeddings');
    expect(captured.headers['Authorization'], 'Bearer test-key');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['model'], _spec.id);
    expect(body['input'], ['熵']);

    final wrongDim = RemoteEmbeddingClient(
      spec: const EmbeddingModelSpec(id: 'test-embed', dim: 8),
      endpoint: 'https://embed.example.com/v1',
      apiKey: '',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.1, 0.2, 0.3, 0.4],
              },
            ],
          }),
          200,
        ),
      ),
    );
    await expectLater(
      wrongDim.embed('熵'),
      throwsA(isA<EmbeddingUnavailable>()),
    );
  });

  test('远程批量嵌入按返回序号还原顺序，输入保持原顺序', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'data': [
            {
              'index': 1,
              'embedding': [0, 1, 0, 0],
            },
            {
              'index': 0,
              'embedding': [1, 0, 0, 0],
            },
          ],
        }),
        200,
      );
    });
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      endpoint: 'https://embed.example.com/v1',
      apiKey: '',
      httpClient: client,
    );

    final vectors = await embedding.embedBatch(['甲', '乙']);
    expect(vectors[0], orderedEquals([1, 0, 0, 0]));
    expect(vectors[1], orderedEquals([0, 1, 0, 0]));
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['input'], orderedEquals(['甲', '乙']));
  });

  test('远程批量嵌入返回的条数不足时报不可用', () async {
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      endpoint: 'https://embed.example.com/v1',
      apiKey: '',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [1, 0, 0, 0],
              },
            ],
          }),
          200,
        ),
      ),
    );

    await expectLater(
      embedding.embedBatch(['甲', '乙']),
      throwsA(isA<EmbeddingUnavailable>()),
    );
  });

  test('远程嵌入每次请求前取地址与凭据，额度用完与 key 被拒按来源不可用报出', () async {
    final seen = <String>[];
    var status = 200;
    var body = <String, Object?>{
      'data': [
        {
          'embedding': [1, 0, 0, 0],
        },
      ],
    };
    final client = MockClient((request) async {
      seen.add('${request.url} ${request.headers['Authorization']}');
      return http.Response(jsonEncode(body), status);
    });
    var token = 0;
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 'access-${++token}'),
      httpClient: client,
    );

    await embedding.embed('甲');
    await embedding.embed('乙');
    expect(seen, [
      'https://server.test/v1/llm/embeddings Bearer access-1',
      'https://server.test/v1/llm/embeddings Bearer access-2',
    ]);

    status = 429;
    body = {'code': 'quota_exceeded', 'title': 'quota exceeded'};
    await expectLater(
      embedding.embed('丙'),
      throwsA(
        isA<EmbeddingSourceUnavailable>().having(
          (error) => error.message,
          'message',
          contains('额度'),
        ),
      ),
    );

    status = 401;
    body = {
      'error': {'message': 'Incorrect API key provided: sk-ab****cd'},
    };
    await expectLater(
      embedding.embed('丁'),
      throwsA(
        isA<EmbeddingSourceUnavailable>().having(
          (error) => error.message,
          'message',
          isNot(contains('sk-')),
        ),
      ),
    );

    status = 500;
    await expectLater(
      embedding.embed('戊'),
      throwsA(
        allOf(
          isA<EmbeddingUnavailable>(),
          isNot(isA<EmbeddingSourceUnavailable>()),
        ),
      ),
    );
  });

  test('查找接口只对知新服务的来源发出，命中按 FP16 解码并归一化', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'model': _spec.id,
          'dimensions': 4,
          'vectors': [
            {'hash': 'aa', 'embedding': 'ADwAOADAAAA='},
          ],
        }),
        200,
      );
    });
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 'access-1'),
      httpClient: client,
    );

    final hits = await embedding.lookupVectors(['aa', 'bb']);
    expect(
      captured.url.toString(),
      'https://server.test/v1/llm/embeddings/lookup',
    );
    expect(captured.headers['Authorization'], 'Bearer access-1');
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['model'], _spec.id);
    expect(body['hashes'], ['aa', 'bb']);
    expect(hits.keys, ['aa']);
    // [1, 0.5, -2, 0] 归一化之后长度为一，与重新嵌入的向量按同一口径参与检索。
    final vector = hits['aa']!;
    expect(vector, hasLength(4));
    expect(vector[0], closeTo(0.4364357804719848, 1e-9));
    expect(vector[1], closeTo(0.2182178902359924, 1e-9));
    expect(vector[2], closeTo(-0.8728715609439696, 1e-9));
    expect(vector[3], 0);
  });

  test('旧服务端、网络失败与服务器错误都退回整批嵌入，认证与限流按来源不可用', () async {
    var calls = 0;
    final oldServer = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 404);
      }),
    );
    expect(await oldServer.lookupVectors(['aa']), isEmpty);
    expect(await oldServer.lookupVectors(['bb']), isEmpty);
    // 旧版服务端返回 404 之后，本次会话不再尝试查找。
    expect(calls, 1);

    final offline = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((_) async => throw http.ClientException('网络断了')),
    );
    expect(await offline.lookupVectors(['aa']), isEmpty);

    final broken = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((_) async => http.Response('{}', 503)),
    );
    expect(await broken.lookupVectors(['aa']), isEmpty);

    final denied = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient(
        (_) async => http.Response('{"code":"contact_unverified"}', 403),
      ),
    );
    await expectLater(
      denied.lookupVectors(['aa']),
      throwsA(
        isA<EmbeddingSourceUnavailable>().having(
          (error) => error.message,
          'message',
          contains('确认一种登录方式'),
        ),
      ),
    );

    final throttled = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((_) async => http.Response('{}', 429)),
    );
    await expectLater(
      throttled.lookupVectors(['aa']),
      throwsA(isA<EmbeddingSourceUnavailable>()),
    );
  });

  test('自填 key 直连不查缓存', () async {
    var calls = 0;
    final embedding = RemoteEmbeddingClient(
      spec: _spec,
      endpoint: 'https://embed.example.com/v1',
      apiKey: 'test-key',
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(await embedding.lookupVectors(['aa']), isEmpty);
    expect(calls, 0);
  });

  test('查找超过单次上限时分批请求，维度不符的条目按未命中处理', () async {
    final requests = <http.Request>[];
    final server = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((request) async {
        requests.add(request);
        final hashes = (jsonDecode(request.body) as Map)['hashes'] as List;
        // 每次只回这一批的第一个哈希：第一次给足维度，第二次少一个分量，
        // 后者按未命中处理，由调用方补算。
        final first = hashes.first as String;
        return http.Response(
          jsonEncode({
            'vectors': [
              {
                'hash': first,
                'embedding': requests.length == 1
                    ? base64Encode(const [0, 0x3c, 0, 0x38, 0, 0xc0, 0, 0])
                    : base64Encode(const [0, 0x3c, 0, 0x38, 0, 0x00]),
              },
            ],
          }),
          200,
        );
      }),
    );

    final hashes = [for (var index = 0; index < 300; index++) 'h$index'];
    final hits = await server.lookupVectors(hashes);
    expect(requests, hasLength(2));
    expect(
      ((jsonDecode(requests.first.body) as Map)['hashes'] as List),
      hasLength(256),
    );
    expect(
      ((jsonDecode(requests.last.body) as Map)['hashes'] as List),
      hasLength(44),
    );
    // 只有维度正确的那一条算命中。
    expect(hits.keys, ['h0']);
  });

  test('写缓存标记只加在知新服务的请求上，且只在要求写入时', () async {
    final seen = <http.Request>[];
    Future<http.Response> reply(http.Request request) async => http.Response(
      jsonEncode({
        'data': [
          {
            'embedding': [1, 0, 0, 0],
          },
        ],
      }),
      200,
    );

    final server = RemoteEmbeddingClient(
      spec: _spec,
      credentials: () async =>
          (endpoint: 'https://server.test/v1/llm', apiKey: 't'),
      httpClient: MockClient((request) {
        seen.add(request);
        return reply(request);
      }),
    );
    await server.embed('甲', writeCache: true);
    await server.embed('乙');
    expect(seen[0].headers['X-Zhixin-Embedding-Cache'], '1');
    expect(seen[1].headers.containsKey('X-Zhixin-Embedding-Cache'), isFalse);

    seen.clear();
    final direct = RemoteEmbeddingClient(
      spec: _spec,
      endpoint: 'https://embed.example.com/v1',
      apiKey: 'test-key',
      httpClient: MockClient((request) {
        seen.add(request);
        return reply(request);
      }),
    );
    await direct.embed('甲', writeCache: true);
    expect(
      seen.single.headers.containsKey('X-Zhixin-Embedding-Cache'),
      isFalse,
    );
  });

  test('嵌入来源整个用不了时停下本次更新，不再逐条重试', () async {
    late _SourceDownClient down;
    final rig = await _rig(clientFor: (spec) => down = _SourceDownClient(spec));
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    expect(refresh.failure, IndexFailure.error);
    expect(refresh.embedded, 0);
    expect(refresh.failed, 7);
    expect(refresh.sourceProblem, '还没有登录');
    // 每个并发最多发一次请求就停下，不会对每一块再逐条重发。
    expect(down.calls, lessThanOrEqualTo(4));
  });

  test('材料范围只保留这份材料的页，不带出其他材料', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();

    final result = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.userMaterial(rig.corpus.materialLinear),
      limit: 5,
    );
    expect(result.usable, isTrue);
    expect(
      result.hits.any(
        (hit) =>
            hit.identity == 'material_page:${rig.corpus.materialProbability}:1',
      ),
      isFalse,
      reason: '概率材料的页不属于线性材料范围',
    );
    expect(
      result.hits.any(
        (hit) => hit.identity == 'material_page:${rig.corpus.materialLinear}:1',
      ),
      isTrue,
    );
  });

  test('范围外向量占满候选时，目标范围仍找得到', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final conversations = ConversationRepository(db);
    final goal = await tasks.createGoal(title: '目标');
    final other = await tasks.createGoal(title: '其他目标');
    for (var index = 0; index < 10; index++) {
      final id = await conversations.create(title: '噪声 $index');
      await conversations.setGoal(id, other);
      await conversations.append(
        id,
        role: MessageRole.user,
        content: '噪声 $index',
      );
    }
    final target = await conversations.create(title: '目标记录');
    await conversations.setGoal(target, goal);
    await conversations.append(target, role: MessageRole.user, content: '目标记录');

    final vectors = <String, List<double>>{
      '熵': [1, 0, 0, 0],
      for (var index = 0; index < 10; index++)
        '噪声 $index': [1, 0.001 * (index + 1), 0, 0],
      '目标记录': [0.5, 0.5, 0, 0],
    };
    final index = MemoryVectorIndex(_spec);
    addTearDown(index.close);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    addTearDown(textIndex.close);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: vectors),
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
      vectorStoreOpener: () async => DirectVectorStore(index),
    );
    addTearDown(service.close);

    final refresh = await service.refresh();
    expect(refresh.embedded, 11);
    final result = await service.search(
      '熵',
      scope: EvidenceScope.userGoal(goal),
      limit: 1,
    );
    expect(result.usable, isTrue);
    expect(result.hits, hasLength(1));
    expect(result.hits.single.location.conversationId, target);
    expect(result.timings.verifiedOut, greaterThanOrEqualTo(10));
  });

  test('索引还没有内容时返回可用的空结果', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final result = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: const EvidenceScope.userAll(),
    );
    expect(result.usable, isTrue);
    expect(result.hits, isEmpty);
    expect(result.entries, 0);
  });

  test('并发刷新共用一次扫描', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final index = MemoryVectorIndex(_spec);
    addTearDown(index.close);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    addTearDown(textIndex.close);
    final client = _CountingClient(
      FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
    );
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: client,
      indexPath: '',
      textStoreOpener: () async => DirectVectorStore(textIndex),
      vectorStoreOpener: () async => DirectVectorStore(index),
    );
    addTearDown(service.close);

    final first = service.refresh();
    final second = service.refresh();
    final results = await Future.wait([first, second]);
    expect(identical(results.first, results.last), isTrue);
    expect(client.calls, 7);
  });

  test('一次刷新把多段正文合并成批量嵌入请求', () async {
    final rig = await _rig(
      clientFor: (spec) => _BatchCountingClient(
        FixedEmbeddingClient(spec: spec, vectors: _vectors()),
      ),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    expect(refresh.embedded, 7);
    final client = rig.service.client! as _BatchCountingClient;
    expect(client.batchCalls, 1);
    expect(client.chunkCalls, 7);
  });

  test('查找命中的片段不再嵌入，未命中的照常补算', () async {
    final rig = await _rig(
      clientFor: (spec) => _LookupClient(
        spec: spec,
        vectors: _vectors(),
        cached: {_pageEntropy, _messageEntropy},
      ),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    final client = rig.service.client! as _LookupClient;
    expect(refresh.cached, 2);
    expect(refresh.failed, 0);
    expect(client.lookedUp, hasLength(7));
    // 查找用的是片段正文的 SHA-256，与服务端的缓存键同一口径。
    expect(client.lookedUp, contains(embeddingTextHash(_pageEntropy)));
    expect(client.embedded, isNot(contains(_pageEntropy)));
    expect(client.embedded, isNot(contains(_messageEntropy)));
    expect(client.embedded, hasLength(5));
    // 命中的向量与重新嵌入的向量一样进索引。
    final result = await rig.service.search(
      '熵是系统混乱程度的度量。',
      scope: const EvidenceScope.userAll(),
      limit: 3,
    );
    expect(result.usable, isTrue);
  });

  test('同一段正文在一次刷新里只嵌入一次', () async {
    final rig = await _rig(
      clientFor: (spec) => _LookupClient(spec: spec, vectors: _vectors()),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await MaterialRepository(rig.db).addPage(
      materialId: rig.corpus.materialProbability,
      pageNo: 3,
      content: _pageEntropy,
    );

    final refresh = await rig.service.refresh();
    final client = rig.service.client! as _LookupClient;
    expect(refresh.failed, 0);
    expect(client.embedded.where((text) => text == _pageEntropy), hasLength(1));
  });

  test('只有自动同步开启时的索引刷新带写缓存标记', () async {
    var synced = true;
    final rig = await _rig(
      clientFor: (spec) => _LookupClient(spec: spec, vectors: _vectors()),
      cacheWrites: () async => synced,
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();
    final client = rig.service.client! as _LookupClient;
    expect(client.writeCacheFlags, isNotEmpty);
    expect(client.writeCacheFlags, everyElement(isTrue));

    // 同步关闭之后重新写入的部分不再带标记。
    synced = false;
    await rig.service.refresh(force: true);
    expect(client.writeCacheFlags, isNotEmpty);
    expect(client.writeCacheFlags.last, isFalse);
  });

  test('查找报来源不可用时停下本次更新，索引不写入', () async {
    final rig = await _rig(
      clientFor: (spec) => _LookupClient(
        spec: spec,
        vectors: _vectors(),
        lookupFailure: const EmbeddingSourceUnavailable('还没有登录'),
      ),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    final client = rig.service.client! as _LookupClient;
    expect(refresh.sourceProblem, '还没有登录');
    expect(refresh.failed, 7);
    expect(client.embedded, isEmpty);
    expect(rig.index.entryCount, 0);
  });

  test('查找报其他错误时按全部未命中处理，刷新照常完成', () async {
    final rig = await _rig(
      clientFor: (spec) => _LookupClient(
        spec: spec,
        vectors: _vectors(),
        lookupFailure: const EmbeddingUnavailable('查找接口返回了意外的结果'),
      ),
    );
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    final client = rig.service.client! as _LookupClient;
    expect(refresh.failed, 0);
    expect(refresh.sourceProblem, isNull);
    expect(client.embedded, hasLength(7));
    expect(rig.index.sourceCount, 7);
  });

  test('换模型只重建向量集合，文本集合的条目数不变', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    await _seed(db);
    final textIndex = MemoryVectorIndex(textOnlyModelSpec);
    var textOpens = 0;
    var requestedSpec = _spec;
    final vectorIndexes = <MemoryVectorIndex>[];
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      indexPath: '',
      textStoreOpener: () async {
        textOpens++;
        return DirectVectorStore(textIndex);
      },
      vectorStoreOpener: () async {
        final index = MemoryVectorIndex(requestedSpec);
        vectorIndexes.add(index);
        return DirectVectorStore(index);
      },
    );
    addTearDown(service.close);

    final first = await service.refresh();
    expect(first.embedded, 7);
    expect(first.textWritten, 7);
    expect(textIndex.entryCount, 7);
    expect(vectorIndexes.single.entryCount, 7);

    // 换一个维度不同的模型：向量集合关闭后按新 spec 重建；正文没有变化，
    // 文本集合只打开一次，也不重写。
    const specB = EmbeddingModelSpec(id: 'another-embed', dim: 8);
    requestedSpec = specB;
    service.configure(
      client: FixedEmbeddingClient(
        spec: specB,
        vectors: {
          for (final entry in _vectors().entries)
            entry.key: [...entry.value, 0, 0, 0, 0],
        },
      ),
    );
    final second = await service.refresh();
    expect(second.embedded, 7);
    expect(second.textWritten, 0);
    expect(second.skipped, 0);
    expect(textIndex.entryCount, 7);
    expect(textOpens, 1);
    expect(vectorIndexes, hasLength(2));
    expect(vectorIndexes.last.entryCount, 7);
  });

  test('只有向量一路命中的记录标按意思，两路都命中的不标', () async {
    final rig = await _twoRouteRig();
    final result = await rig.service.search(
      '矩阵',
      scope: const EvidenceScope.userAll(),
      limit: 5,
    );
    expect(result.usable, isTrue);
    final byIdentity = {for (final hit in result.hits) hit.identity: hit};
    expect(byIdentity[rig.textHit]!.semantic, isFalse, reason: '两路都命中');
    expect(byIdentity[rig.vectorHit]!.semantic, isTrue, reason: '只有向量一路命中');
    // 向量集合不存正文，摘要按当前记录重新计算，命中片段仍然显示得出来。
    expect(byIdentity[rig.vectorHit]!.snippet, contains('线性无关'));
  });

  test('两路融合按名次倒数相加，与拆分前的评测语义一致', () async {
    final rig = await _twoRouteRig();
    final result = await rig.service.search(
      '矩阵',
      scope: const EvidenceScope.userAll(),
      limit: 5,
    );
    // 关键词第一 + 向量第二的分数是 1/61+1/62，大于向量第一的 1/61：同一组
    // 候选在拆分前的引擎内融合（同样的名次倒数与常数 60）也是这个先后。
    expect(result.hits.map((hit) => hit.identity).toList(), [
      rig.textHit,
      rig.vectorHit,
    ]);
    expect(
      result.hits.first.score.value,
      greaterThan(result.hits.last.score.value),
    );
  });

  test('记忆索引按关键词相关性排序，改、删随之同步，不调用嵌入来源', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final memories = MemoryRepository(db);
    final memoryIndex = MemoryVectorIndex(textOnlyModelSpec);
    addTearDown(memoryIndex.close);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      indexPath: '',
      clock: () => DateTime(2026, 11, 12, 10),
      memoryStoreOpener: () async => DirectVectorStore(memoryIndex),
    );
    addTearDown(service.close);

    final root = await memories.create(
      kind: MemoryKind.difficulty,
      content: '解分式方程时忘记检验增根',
    );
    final example = await memories.create(
      kind: MemoryKind.preference,
      content: '讲解时先给一个例子',
    );
    final timeLimit = await memories.create(
      kind: MemoryKind.constraint,
      content: '这周晚上只有半小时',
    );
    final candidates = [root, example, timeLimit];

    final ordered = await service.rankMemories(
      query: '增根 检验',
      memories: await memories.list(),
      candidateIds: candidates,
    );
    expect(ordered, isNotNull);
    expect(ordered!.first, root);
    expect(memoryIndex.entryCount, 3);

    // 改写之后旧正文不再命中，新正文进索引。
    await memories.updateContent(
      root,
      content: '分式方程解完要把根代回原方程',
      kind: MemoryKind.difficulty,
    );
    final rewritten = await memories.list();
    expect(
      await service.rankMemories(
        query: '增根 检验',
        memories: rewritten,
        candidateIds: candidates,
      ),
      isNot(contains(root)),
    );
    expect(
      (await service.rankMemories(
        query: '代回原方程',
        memories: rewritten,
        candidateIds: candidates,
      ))!.first,
      root,
    );

    // 删除的记忆不再留在索引里。
    await memories.delete(example);
    await service.rankMemories(
      query: '例子',
      memories: await memories.list(),
      candidateIds: [root, timeLimit],
    );
    expect(memoryIndex.entryCount, 2);

    // 索引只排候选：候选之外的相关记忆不参与本次排序。
    expect(
      await service.rankMemories(
        query: '增根',
        memories: await memories.list(),
        candidateIds: [timeLimit],
      ),
      isEmpty,
    );
  });

  test('记忆索引打不开时返回空值，由调用方退回本机排序', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final service = SearchIndexService(
      repository: EvidenceRepository(db),
      indexPath: '',
      memoryStoreOpener: () async => throw const VectorStoreFailure('没有本机向量库'),
    );
    addTearDown(service.close);
    final memory = (
      id: 'memory-1',
      content: '解分式方程时忘记检验增根',
      kind: MemoryKind.difficulty,
    );
    final ordered = await service.rankMemories(
      query: '增根',
      memories: [
        Memory(id: memory.id, kind: memory.kind, content: memory.content),
      ],
      candidateIds: [memory.id],
    );
    expect(ordered, isNull);
  });
}

/// 两路各命中一条的固定装配：`矩阵的秩怎么求` 由关键词与向量两路命中，
/// `线性无关的行向量个数` 只由向量一路命中；查询向量更接近后者，关键词只命中前者。
Future<({SearchIndexService service, String textHit, String vectorHit})>
_twoRouteRig() async {
  final db = await openTestDb();
  addTearDown(db.close);
  final conversations = ConversationRepository(db);
  final textConversation = await conversations.create(title: '矩阵讨论');
  final textMessage = (await conversations.append(
    textConversation,
    role: MessageRole.user,
    content: '矩阵的秩怎么求',
  )).id;
  final vectorConversation = await conversations.create(title: '线性无关');
  final vectorMessage = (await conversations.append(
    vectorConversation,
    role: MessageRole.user,
    content: '线性无关的行向量个数',
  )).id;
  final service = SearchIndexService(
    repository: EvidenceRepository(db),
    initialClient: FixedEmbeddingClient(
      spec: _spec,
      vectors: {
        '矩阵': [1, 0, 0, 0],
        '矩阵的秩怎么求': [0.2, 0.9, 0, 0],
        '线性无关的行向量个数': [0.98, 0.1, 0, 0],
      },
    ),
    indexPath: '',
    textStoreOpener: () async =>
        DirectVectorStore(MemoryVectorIndex(textOnlyModelSpec)),
    vectorStoreOpener: () async => DirectVectorStore(MemoryVectorIndex(_spec)),
  );
  addTearDown(service.close);
  final refresh = await service.refresh();
  expect(refresh.failed, 0);
  expect(refresh.embedded, 2);
  return (
    service: service,
    textHit: 'message:$textMessage',
    vectorHit: 'message:$vectorMessage',
  );
}

class _TrackedStore extends DirectVectorStore {
  _TrackedStore(super.index, this.onClose);

  final Future<void> Function() onClose;

  @override
  Future<void> close() async {
    await onClose();
    await super.close();
  }
}

class _CountingClient extends EmbeddingClient {
  _CountingClient(this.inner);

  final EmbeddingClient inner;
  int calls = 0;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) {
    calls++;
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

class _BatchCountingClient extends EmbeddingClient {
  _BatchCountingClient(this.inner);

  final EmbeddingClient inner;
  int batchCalls = 0;
  int chunkCalls = 0;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) {
    chunkCalls++;
    return inner.embed(text);
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    batchCalls++;
    chunkCalls += texts.length;
    return [for (final text in texts) await inner.embed(text)];
  }

  @override
  void dispose() {}
}

class _RecordingClient extends EmbeddingClient {
  _RecordingClient({required this.inner, required this.sent});

  final EmbeddingClient inner;
  final List<String> sent;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    sent.add(text);
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

/// 每次请求都报来源不可用，记录被调用的次数。
class _SourceDownClient extends EmbeddingClient {
  _SourceDownClient(this.spec);

  @override
  final EmbeddingModelSpec spec;
  int calls = 0;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    calls++;
    throw const EmbeddingSourceUnavailable('还没有登录');
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    calls++;
    throw const EmbeddingSourceUnavailable('还没有登录');
  }

  @override
  void dispose() {}
}

/// 查找与嵌入都记录下来：命中的片段由查找直接给出，未命中的才嵌入。
class _LookupClient extends EmbeddingClient {
  _LookupClient({
    required this.spec,
    required this.vectors,
    this.cached = const {},
    this.lookupFailure,
  });

  @override
  final EmbeddingModelSpec spec;

  /// 正文到固定向量；测试里的正文都很短，一段正文只有一个片段。
  final Map<String, List<double>> vectors;

  /// 由服务端缓存直接命中的正文。
  final Set<String> cached;

  /// 查找直接报出的错误；给出时不再嵌入。
  final EmbeddingUnavailable? lookupFailure;

  final List<String> lookedUp = [];
  final List<String> embedded = [];
  final List<bool> writeCacheFlags = [];

  @override
  Future<EmbeddingLookup> lookupVectors(List<String> hashes) async {
    final failure = lookupFailure;
    if (failure != null) throw failure;
    lookedUp.addAll(hashes);
    return {
      for (final text in cached)
        if (vectors[text] != null)
          embeddingTextHash(text): normalizeVector(vectors[text]!),
    };
  }

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    embedded.add(text);
    writeCacheFlags.add(writeCache);
    final vector = vectors[text];
    if (vector == null) throw const EmbeddingUnavailable('没有为这段文本准备固定向量');
    return normalizeVector(vector);
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    embedded.addAll(texts);
    writeCacheFlags.add(writeCache);
    return [for (final text in texts) normalizeVector(vectors[text]!)];
  }

  @override
  void dispose() {}
}
