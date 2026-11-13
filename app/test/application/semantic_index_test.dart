import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/application/embedding_settings.dart';
import 'package:zhixin/application/semantic_index_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/data/vector/embedding_config_store.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/rules/embedding.dart';

import '../support/test_db.dart';

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

  final int goalProbability;
  final int goalLinear;
  final int materialProbability;
  final int materialLinear;

  /// 熵那一页的行标识，用于直接改写内容模拟更正。
  final int entropyPage;
}

Future<_Corpus> _seed(Database db) async {
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
    role: 'user',
    content: _messageEntropy,
  );

  final question = await conversations.create(sourceRef: '例 3-2');
  await conversations.setGoal(question, probability);
  await conversations.setMaterial(
    question,
    materialId: materialProbability,
    pageNo: 2,
  );
  await conversations.append(question, role: 'user', content: '例 3-2 的解法');
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
    role: 'user',
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
    Database db,
    EvidenceRepository repository,
    VectorIndex index,
    SemanticIndexService service,
    _Corpus corpus,
  })
>
_rig({
  EmbeddingClient Function(EmbeddingModelSpec)? clientFor,
  bool Function(SemanticSource source)? canSend,
  String Function()? epoch,
}) async {
  final db = await openTestDb();
  final corpus = await _seed(db);
  final repository = EvidenceRepository(db);
  final index = VectorIndex.open(inMemory: true, spec: _spec);
  final client =
      clientFor?.call(_spec) ??
      FixedEmbeddingClient(spec: _spec, vectors: _vectors());
  final service = SemanticIndexService(
    repository: repository,
    initialClient: client,
    indexPath: '',
    epoch: () async => epoch?.call() ?? '0',
    indexOpener: () => index,
    initialShareFilter: canSend,
    queryTimeout: const Duration(seconds: 2),
  );
  return (
    db: db,
    repository: repository,
    index: index,
    service: service,
    corpus: corpus,
  );
}

class _SlowClient implements EmbeddingClient {
  _SlowClient(this.inner);

  final EmbeddingClient inner;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

class _MutatingClient implements EmbeddingClient {
  _MutatingClient({required this.inner, required this.onEmbed});

  final EmbeddingClient inner;
  final Future<void> Function(String text) onEmbed;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text) async {
    await onEmbed(text);
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('固定测试向量验证扩展注册、写入与查询', () {
    final spec = _spec;
    final index = VectorIndex.open(inMemory: true, spec: spec);
    addTearDown(index.close);
    final locator = const SemanticLocator(
      kind: 'material_page',
      sourceKey: 'material_page:1:1',
      materialId: 1,
      pageNo: 1,
    );
    index.replaceSource(
      locator: locator,
      sourceVersion: 'v1',
      chunks: const [_pageEntropy],
      vectors: const [
        [1, 0, 0, 0],
      ],
      createdAt: '2026-11-12 10:00:00',
    );
    final matches = index.search([0.99, 0.05, 0, 0], k: 3);
    expect(matches, hasLength(1));
    expect(matches.single.sourceKey, 'material_page:1:1');
    expect(matches.single.distance, lessThan(0.1));
    expect(index.entryCount, 1);
    expect(index.meta('model_key'), contains('test-embed'));
  });

  test('语义查询能找回同义改写的原文，并按需求合并后带回来源', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);

    final refresh = await rig.service.refresh();
    expect(refresh.failure, SemanticFailure.none);
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
    expect(result.hits.first.identity, 'material_page:1:1');
    expect(result.hits.first.snippet, contains('熵'));

    final scoped = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalLinear),
      limit: 5,
    );
    expect(
      scoped.hits.any((hit) => hit.identity == 'material_page:1:1'),
      isFalse,
      reason: '其他目标的材料页不进入本次回答范围',
    );
    expect(
      scoped.hits.any((hit) => hit.identity == 'material_page:2:1'),
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

    await rig.db.update(
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

  test('等待嵌入期间来源被更正，迟到结果不写入索引', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final index = VectorIndex.open(inMemory: true, spec: _spec);
    addTearDown(index.close);
    final client = _MutatingClient(
      inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      onEmbed: (text) async {
        if (text != _pageDerivative) return;
        await db.update(
          'material_page',
          {'content': '导数的定义改写了。', 'updated_at': '2026-11-12 12:00:00'},
          where: 'material_id = ? AND page_no = ?',
          whereArgs: [corpus.materialProbability, 2],
        );
      },
    );
    final service = SemanticIndexService(
      repository: EvidenceRepository(db),
      initialClient: client,
      indexPath: '',
      indexOpener: () => index,
    );

    final result = await service.refresh();
    expect(result.lateSkipped, greaterThanOrEqualTo(1));
    final stats = await service.stats();
    expect(stats.sources, 6);
  });

  test('更正后的来源版本与索引不一致时，语义候选不再进入回答', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();

    await rig.db.update(
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
      result.hits.any((hit) => hit.identity == 'material_page:1:1'),
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
    expect(timedOut.failure, SemanticFailure.timeout);
    expect(timedOut.hits, isEmpty);
    expect(timedOut.entries, 0);

    final token = SemanticCancelToken()..cancel();
    final cancelled = await rig.service.search(
      '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      cancelToken: token,
    );
    expect(cancelled.failure, SemanticFailure.cancelled);

    // 原文与关键词检索不经过嵌入，仍然可用。
    final evidence = await rig.repository.literal(
      '熵',
      scope: const EvidenceScope.userAll(),
    );
    expect(evidence, isNotEmpty);
  });

  test('没有配置嵌入来源时按不可用处理', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repository = EvidenceRepository(db);
    final service = SemanticIndexService(repository: repository, indexPath: '');
    final refresh = await service.refresh();
    expect(refresh.failure, SemanticFailure.notConfigured);
    final result = await service.search(
      '熵',
      scope: const EvidenceScope.userAll(),
    );
    expect(result.failure, SemanticFailure.notConfigured);
    expect((await service.stats()).configured, isFalse);
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

  test('切换嵌入模型与维度时清空旧索引并重建结构', () {
    final dir = Directory.systemTemp.createTempSync('zhixin_vec_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/index.db';

    final first = VectorIndex.open(path: path, spec: _spec);
    first.replaceSource(
      locator: const SemanticLocator(
        kind: 'message',
        sourceKey: 'message:1',
        conversationId: 1,
        messageId: 1,
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

    final second = VectorIndex.open(
      path: path,
      spec: const EmbeddingModelSpec(id: 'another-embed', dim: 8),
    );
    addTearDown(second.close);
    expect(second.entryCount, 0);
    expect(second.meta('model_key'), contains('another-embed'));
    second.replaceSource(
      locator: const SemanticLocator(
        kind: 'message',
        sourceKey: 'message:1',
        conversationId: 1,
        messageId: 1,
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

  test('回答前检索把语义候选与原文命中按来源标识合并', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);
    addTearDown(rig.index.close);
    await rig.service.refresh();
    final evidence = EvidenceService(
      repository: rig.repository,
      semantic: rig.service,
    );

    final bundle = await evidence.forAnswer(
      query: '系统混乱程度怎么衡量',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalProbability),
      limit: 5,
    );
    expect(bundle.hits, isNotEmpty);
    expect(bundle.semanticFailed, isFalse);
    expect(bundle.timings, isNotNull);
    expect(
      bundle.hits.any((hit) => hit.identity == 'material_page:1:1'),
      isTrue,
    );
    final identities = bundle.hits.map((hit) => hit.identity).toList();
    expect(identities.toSet().length, identities.length);
  });

  test('远程嵌入只发送用户选定范围内的原文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final index = VectorIndex.open(inMemory: true, spec: _spec);
    addTearDown(index.close);
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
    final service = SemanticIndexService(
      repository: EvidenceRepository(db),
      initialClient: _RecordingClient(
        inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
        sent: sent,
      ),
      indexPath: '',
      indexOpener: () => index,
      initialShareFilter: runtime.canSend,
    );

    final refresh = await service.refresh();
    expect(refresh.failed, 0);
    expect(sent, isNotEmpty);
    // 没有选中材料归属的记录不发送原文。
    expect(sent.any((text) => text.contains('矩阵的列向量')), isFalse);
    expect(refresh.skipped, greaterThanOrEqualTo(1));
    expect((await service.stats()).sources, lessThan(6));
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
      result.hits.any((hit) => hit.identity == 'material_page:1:1'),
      isFalse,
      reason: '概率材料的页不属于线性材料范围',
    );
    expect(
      result.hits.any((hit) => hit.identity == 'material_page:2:1'),
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
      await conversations.append(id, role: 'user', content: '噪声 $index');
    }
    final target = await conversations.create(title: '目标记录');
    await conversations.setGoal(target, goal);
    await conversations.append(target, role: 'user', content: '目标记录');

    final vectors = <String, List<double>>{
      '熵': [1, 0, 0, 0],
      for (var index = 0; index < 10; index++)
        '噪声 $index': [1, 0.001 * (index + 1), 0, 0],
      '目标记录': [0.5, 0.5, 0, 0],
    };
    final index = VectorIndex.open(inMemory: true, spec: _spec);
    addTearDown(index.close);
    final service = SemanticIndexService(
      repository: EvidenceRepository(db),
      initialClient: FixedEmbeddingClient(spec: _spec, vectors: vectors),
      indexPath: '',
      indexOpener: () => index,
    );

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
    final index = VectorIndex.open(inMemory: true, spec: _spec);
    addTearDown(index.close);
    final client = _CountingClient(
      FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
    );
    final service = SemanticIndexService(
      repository: EvidenceRepository(db),
      initialClient: client,
      indexPath: '',
      indexOpener: () => index,
    );

    final first = service.refresh();
    final second = service.refresh();
    final results = await Future.wait([first, second]);
    expect(identical(results.first, results.last), isTrue);
    expect(client.calls, 7);
  });
}

class _CountingClient implements EmbeddingClient {
  _CountingClient(this.inner);

  final EmbeddingClient inner;
  int calls = 0;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text) {
    calls++;
    return inner.embed(text);
  }

  @override
  void dispose() {}
}

class _RecordingClient implements EmbeddingClient {
  _RecordingClient({required this.inner, required this.sent});

  final EmbeddingClient inner;
  final List<String> sent;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text) async {
    sent.add(text);
    return inner.embed(text);
  }

  @override
  void dispose() {}
}
