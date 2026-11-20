import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/application/search_index_service.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/data/revisions/revision_cursor.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/semantic_change.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/data/vector/memory_vector_index.dart';
import 'package:zhixin/data/vector/vector_store.dart';
import 'package:zhixin/domain/models/evidence_id.dart';
import 'package:zhixin/domain/rules/embedding.dart';

import '../support/test_db.dart';

/// 增量收新的用例：提交日志驱动、删除与范围变化、补齐与失败重试。
///
/// 这些用例用真实的 [RevisionEngine] 写入（每次写入形成一个提交），只把索引
/// 换成内存实现、嵌入换成固定向量。判断依据是两份集合里实际写下的条目与状态
/// 文件里的提交编号，不依赖等待时间。

const _spec = EmbeddingModelSpec(
  id: 'incremental-embed',
  dim: 4,
  provider: 'test',
);

const _pageEntropy = '熵是系统混乱程度的度量。';
const _pageDerivative = 'f(x)=x² 的导数是 2x。';
const _pageLinear = '矩阵 A 的第 b 列记作 a_b。';
const _messageEntropy = '熵增与时间箭头有关系吗';
const _messageLinear = '矩阵的列向量怎么写';
const _messageQuestion = '例 3-2 的解法';
const _answerProbability = '先求 P(A|B)=P(AB)/P(B)，答案是 0.4。';
const _revisedEntropy = '熵衡量系统的混乱程度。';
const _addedPage = '拉格朗日乘子法求极值。';
const _addedMessage = '时间箭头和熵增是一回事吗';
const _addedQuestion = '例 4-1 的条件是什么';
const _addedAnswer = '按全概率公式展开。';

/// 语义索引的来源表；与 `app_scope` 的筛选一致。
const _sourceTables = {'material_page', 'message', 'attempt'};

Map<String, List<double>> _vectors() => {
  _pageEntropy: [1, 0, 0, 0],
  _pageDerivative: [0, 1, 0, 0],
  _pageLinear: [0.5, 0.5, 0, 0],
  _messageEntropy: [0, 0, 1, 0],
  _messageLinear: [0.4, 0.4, 0.2, 0],
  _messageQuestion: [0, 0.2, 0.8, 0],
  _answerProbability: [0, 0, 0, 1],
  _revisedEntropy: [1, 0, 0, 0],
  _addedPage: [0.2, 0.2, 0.2, 0.8],
  _addedMessage: [0.1, 0.2, 0.9, 0],
  _addedQuestion: [0.3, 0.1, 0.5, 0],
  _addedAnswer: [0, 0.1, 0, 0.9],
};

class _Corpus {
  const _Corpus({
    required this.materialA,
    required this.materialB,
    required this.pageA1,
    required this.pageA2,
    required this.pageB1,
    required this.conversationA,
    required this.conversationB,
  });

  final String materialA;
  final String materialB;
  final String pageA1;
  final String pageA2;
  final String pageB1;
  final String conversationA;
  final String conversationB;
}

/// 与生产同一套写入路径：每次写入形成一个提交，`revision_change` 里有净变化。
Future<_Corpus> _seed(TestRig rig) async {
  final tasks = TaskRepository(rig.db);
  final materials = MaterialRepository(rig.db);
  final conversations = ConversationRepository(rig.db);
  final attempts = AttemptRepository(rig.db);
  final goal = await tasks.createGoal(title: '概率论期末');
  final materialA = await materials.create(title: '概率论讲义', goalId: goal);
  final pageA1 = await materials.addPage(
    materialId: materialA,
    pageNo: 1,
    content: _pageEntropy,
  );
  final pageA2 = await materials.addPage(
    materialId: materialA,
    pageNo: 2,
    content: _pageDerivative,
  );
  final materialB = await materials.create(title: '线性代数讲义');
  final pageB1 = await materials.addPage(
    materialId: materialB,
    pageNo: 1,
    content: _pageLinear,
  );
  final conversationA = await conversations.create(title: '熵与时间');
  await conversations.setMaterial(
    conversationA,
    materialId: materialA,
    pageNo: 1,
  );
  await conversations.append(
    conversationA,
    role: MessageRole.user,
    content: _messageEntropy,
  );
  final conversationB = await conversations.create(title: '矩阵记号');
  await conversations.setMaterial(
    conversationB,
    materialId: materialB,
    pageNo: 1,
  );
  await conversations.append(
    conversationB,
    role: MessageRole.user,
    content: _messageLinear,
  );
  final question = await conversations.create(sourceRef: '例 3-2');
  await conversations.setMaterial(question, materialId: materialA, pageNo: 2);
  await conversations.append(
    question,
    role: MessageRole.user,
    content: _messageQuestion,
  );
  final attempt = await attempts.ensureOpenAttempt(question);
  await attempts.submit(
    attempt.id,
    answer: _answerProbability,
    isCorrect: true,
    independent: true,
  );
  return _Corpus(
    materialA: materialA,
    materialB: materialB,
    pageA1: pageA1,
    pageA2: pageA2,
    pageB1: pageB1,
    conversationA: conversationA,
    conversationB: conversationB,
  );
}

/// 记录全量扫描次数；增量刷新不应该再调用它。
class _CountingRepository extends EvidenceRepository {
  _CountingRepository(super._db);

  int fullScans = 0;

  @override
  Future<List<SemanticSource>> semanticSources({int? limit}) {
    fullScans++;
    return super.semanticSources(limit: limit);
  }
}

class _Rig {
  _Rig({
    required this.rig,
    required this.repository,
    required this.materials,
    required this.conversations,
    required this.attempts,
    required this.textIndex,
    required this.vectorIndex,
    required this.service,
    required this.corpus,
    required this.client,
  });

  final TestRig rig;
  final _CountingRepository repository;
  final MaterialRepository materials;
  final ConversationRepository conversations;
  final AttemptRepository attempts;
  final MemoryVectorIndex textIndex;
  final MemoryVectorIndex vectorIndex;
  final SearchIndexService service;
  final _Corpus corpus;
  final EmbeddingClient client;

  Future<void> close() async {
    await service.close();
    await rig.close();
  }
}

/// 读取某个提交之后的来源行变化；与 `app_scope` 的装配相同。
Future<SemanticChangeWindow> _changesAfter(TestRig rig, int after) async {
  if (await rig.engine.commitById(rig.raw, after) == null) {
    return SemanticChangeWindow.unavailable;
  }
  final changes = await rig.engine.changesAfter(
    rig.raw,
    after,
    tables: _sourceTables,
  );
  return SemanticChangeWindow(
    changes: [
      for (final change in changes)
        SemanticRowChange(
          table: change.table,
          rowKey: change.rowKey,
          removed: change.isDelete,
          removedRow: change.isDelete && change.before != null
              ? sqliteRow(change.before!)
              : null,
        ),
    ],
  );
}

Future<_Rig> _buildRig({
  EmbeddingClient Function(EmbeddingModelSpec spec)? clientFor,
  bool Function(SemanticSource source)? canSend,
  String Function()? shareSignature,
  Future<SemanticChangeWindow> Function(int after)? semanticChanges,
  Future<int> Function()? headCommit,
  RevisionEngine? engine,
}) async {
  final rig = await openTestRig(engine: engine);
  final corpus = await _seed(rig);
  final repository = _CountingRepository(rig.db);
  final textIndex = MemoryVectorIndex(textOnlyModelSpec);
  final vectorIndex = MemoryVectorIndex(_spec);
  final client =
      clientFor?.call(_spec) ??
      FixedEmbeddingClient(spec: _spec, vectors: _vectors());
  final service = SearchIndexService(
    repository: repository,
    initialClient: client,
    indexPath: '',
    epoch: () async => '${await rig.engine.currentGeneration(rig.raw)}',
    headCommit: headCommit ?? () => rig.engine.headId(rig.raw),
    semanticChanges: semanticChanges ?? (after) => _changesAfter(rig, after),
    shareSignature: shareSignature,
    initialShareFilter: canSend,
    indexCursors: () => RevisionCursors(rig.raw),
    textStoreOpener: () async => DirectVectorStore(textIndex),
    vectorStoreOpener: () async => DirectVectorStore(vectorIndex),
  );
  return _Rig(
    rig: rig,
    repository: repository,
    materials: MaterialRepository(rig.db),
    conversations: ConversationRepository(rig.db),
    attempts: AttemptRepository(rig.db),
    textIndex: textIndex,
    vectorIndex: vectorIndex,
    service: service,
    corpus: corpus,
    client: client,
  );
}

String _pageKey(String materialId, int pageNo) =>
    EvidenceId.materialPage(materialId, pageNo).value;

/// 检索索引的读取位置：写在 `revision_cursor` 的非阻塞位置里，不再写在各份
/// 状态文件的 `commit_id` 上（方案 3.12）。
Future<int> _searchPosition(TestRig rig) =>
    RevisionCursors(rig.raw).indexPosition(IndexCursorNames.search);

/// 固定向量来源外加失败集合：出现在失败集合里的正文按不可用抛出。
class _FailableClient extends EmbeddingClient {
  _FailableClient(this.inner);

  final EmbeddingClient inner;
  final failing = <String>{};
  final embedded = <String>[];

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    if (failing.contains(text.trim())) {
      throw const EmbeddingUnavailable('测试里这一段没有算出来');
    }
    embedded.add(text.trim());
    return inner.embed(text, writeCache: writeCache);
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    for (final text in texts) {
      if (failing.contains(text.trim())) {
        throw const EmbeddingUnavailable('测试里这一段没有算出来');
      }
    }
    embedded.addAll([for (final text in texts) text.trim()]);
    return [for (final text in texts) await inner.embed(text)];
  }

  @override
  void dispose() {}
}

/// 嵌入时顺带写入一份新数据：用来制造“刷新期间又有提交”的情形。
class _LateWriteClient extends EmbeddingClient {
  _LateWriteClient({required this.inner, required this.onEmbed});

  final EmbeddingClient inner;
  final Future<void> Function(String text) onEmbed;

  @override
  EmbeddingModelSpec get spec => inner.spec;

  @override
  Future<List<double>> embed(String text, {bool writeCache = false}) async {
    await onEmbed(text.trim());
    return inner.embed(text);
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool writeCache = false,
  }) async {
    for (final text in texts) {
      await onEmbed(text.trim());
    }
    return [for (final text in texts) await inner.embed(text)];
  }

  @override
  void dispose() {}
}

void main() {
  test('第一次刷新全量扫描并记录提交，第二次没有变化时不再读全部来源', () async {
    final r = await _buildRig();
    addTearDown(r.close);

    final first = await r.service.refresh();
    expect(first.failure, IndexFailure.none);
    expect(first.total, 7);
    expect(r.repository.fullScans, 1);
    final head = await r.rig.engine.headId(r.rig.raw);
    expect(head, greaterThan(0));
    expect(await _searchPosition(r.rig), head);
    // 状态文件里不再记已处理到的提交编号：读取位置统一写在 revision_cursor，
    // 两份 collection 的状态文件只留模型键、维度与代次（方案 3.12）。
    expect(() => r.textIndex.meta('commit_id'), throwsArgumentError);
    expect(() => r.vectorIndex.meta('commit_id'), throwsArgumentError);
    final cursor = await RevisionCursors(r.rig.raw)
        .read(IndexCursorNames.search);
    expect(cursor, isNotNull);
    expect(cursor!.blocking, isFalse, reason: '索引只登记位置，不阻止裁剪');
    expect(cursor.scope, isNull);

    final second = await r.service.refresh();
    expect(second.total, 0);
    expect(second.textWritten, 0);
    expect(second.embedded, 0);
    expect(r.repository.fullScans, 1, reason: '没有变化时不再读全部来源');
  });

  test('改一页材料只处理这一页', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();

    await r.materials.correctPage(
      pageId: r.corpus.pageA1,
      content: _revisedEntropy,
    );
    final refresh = await r.service.refresh();

    expect(refresh.total, 1);
    expect(refresh.textWritten, 1);
    expect(refresh.embedded, 1);
    expect(r.repository.fullScans, 1, reason: '增量刷新不再读全部来源');
    final key = _pageKey(r.corpus.materialA, 1);
    final source = await r.repository.semanticSourceOfRow(
      'material_page',
      r.corpus.pageA1,
    );
    expect(source, isNotNull);
    expect(
      (r.textIndex.indexedSources([key]))[key]!.sourceVersion,
      source!.sourceVersion,
    );
    expect(
      (r.vectorIndex.indexedSources([key]))[key]!.sourceVersion,
      source.sourceVersion,
    );
  });

  test('删除一页时两份集合都不再命中，向量删除条数计入 removed', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();
    final key = _pageKey(r.corpus.materialA, 1);

    await r.rig.db.command((txn) async {
      await deleteRows(
        txn,
        'material_page',
        where: 'id = ?',
        whereArgs: [r.corpus.pageA1],
      );
    }, label: '删除一页材料');

    final refresh = await r.service.refresh();
    expect(refresh.total, 1);
    expect(refresh.removed, 1);
    expect(refresh.textWritten, 0);
    expect(refresh.embedded, 0);
    expect(r.textIndex.indexedSources([key]), isEmpty);
    expect(r.vectorIndex.indexedSources([key]), isEmpty);
    expect(r.textIndex.entryCount, 6);
    expect(r.vectorIndex.entryCount, 6);
    expect(r.repository.fullScans, 1);
  });

  test('起点提交被历史裁剪时退回全量扫描，索引按当前数据重建', () async {
    var trimmed = false;
    late final _Rig r;
    r = await _buildRig(
      semanticChanges: (after) async => trimmed
          ? SemanticChangeWindow.unavailable
          : _changesAfter(r.rig, after),
    );
    addTearDown(r.close);
    await r.service.refresh();

    await r.materials.correctPage(
      pageId: r.corpus.pageA1,
      content: _revisedEntropy,
    );
    trimmed = true;
    final refresh = await r.service.refresh();

    // 全量扫描读全部来源，但只有变化的那一页需要重写。
    expect(refresh.total, 7);
    expect(refresh.textWritten, 1);
    expect(refresh.embedded, 1);
    expect(r.repository.fullScans, 2);
    final key = _pageKey(r.corpus.materialA, 1);
    final source = await r.repository.semanticSourceOfRow(
      'material_page',
      r.corpus.pageA1,
    );
    expect(
      (r.textIndex.indexedSources([key]))[key]!.sourceVersion,
      source!.sourceVersion,
    );
  });

  test('嵌入失败时不推进向量集合的提交，下一次刷新重试同一批来源', () async {
    final client = _FailableClient(
      FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
    );
    final r = await _buildRig(clientFor: (_) => client);
    addTearDown(r.close);
    await r.service.refresh();
    final beforeHead = await r.rig.engine.headId(r.rig.raw);

    await r.materials.correctPage(
      pageId: r.corpus.pageA1,
      content: _revisedEntropy,
    );
    final newHead = await r.rig.engine.headId(r.rig.raw);
    client.failing.add(_revisedEntropy);
    final refresh = await r.service.refresh();

    expect(refresh.failed, 1);
    expect(await _searchPosition(r.rig), beforeHead, reason: '向量失败时位置不前进');
    final key = _pageKey(r.corpus.materialA, 1);
    final stale = r.vectorIndex.indexedSources([key])[key]!;
    final source = await r.repository.semanticSourceOfRow(
      'material_page',
      r.corpus.pageA1,
    );
    expect(stale.sourceVersion, isNot(source!.sourceVersion));
    // 正文一路不受嵌入失败影响，已经按新版本写好；下一次只补向量。
    expect(
      r.textIndex.indexedSources([key])[key]!.sourceVersion,
      source.sourceVersion,
    );

    client.failing.remove(_revisedEntropy);
    final retry = await r.service.refresh();
    expect(retry.embedded, 1);
    expect(retry.failed, 0);
    expect(await _searchPosition(r.rig), newHead);
    expect(
      (r.vectorIndex.indexedSources([key]))[key]!.sourceVersion,
      source.sourceVersion,
    );
  });

  test('刷新期间又有提交时，结束后自动补跑一次', () async {
    final catchUpStarted = Completer<void>();
    var catchUpFrom = -1;
    var added = false;
    late final _Rig r;
    final client = _LateWriteClient(
      inner: FixedEmbeddingClient(spec: _spec, vectors: _vectors()),
      onEmbed: (text) async {
        if (added || text != _revisedEntropy) return;
        added = true;
        await r.materials.addPage(
          materialId: r.corpus.materialA,
          pageNo: 3,
          content: _addedPage,
        );
      },
    );
    r = await _buildRig(
      clientFor: (_) => client,
      semanticChanges: (after) async {
        final window = await _changesAfter(r.rig, after);
        // 上一次刷新处理到 catchUpFrom 为止，补跑从那里开始读变更。
        if (after == catchUpFrom && !catchUpStarted.isCompleted) {
          catchUpStarted.complete();
        }
        return window;
      },
    );
    addTearDown(r.close);
    await r.service.refresh();

    await r.materials.correctPage(
      pageId: r.corpus.pageA1,
      content: _revisedEntropy,
    );
    catchUpFrom = await r.rig.engine.headId(r.rig.raw);
    await r.service.refresh();
    // 第一次刷新处理到更正为止，期间新增的一页要等补跑。
    expect(added, isTrue);
    await catchUpStarted.future;
    // 补跑可能已经开始；再调用一次刷新只会等这次补跑，不会另起一次扫描。
    await r.service.refresh();

    final head = await r.rig.engine.headId(r.rig.raw);
    expect(head, greaterThan(catchUpFrom));
    expect(await _searchPosition(r.rig), head);
    final addedKey = _pageKey(r.corpus.materialA, 3);
    expect(r.textIndex.indexedSources([addedKey]), isNotEmpty);
    expect(r.vectorIndex.indexedSources([addedKey]), isNotEmpty);
  });

  test('可发送范围签名变化时向量集合清空重建，文本集合保留', () async {
    var signature = 'all';
    late final _Rig r;
    r = await _buildRig(shareSignature: () => signature);
    addTearDown(r.close);
    final first = await r.service.refresh();
    expect(first.failed, 0);
    expect(r.vectorIndex.sourceCount, 7);
    expect(r.textIndex.entryCount, 7);

    // 可发送范围缩小到材料 A：向量集合整份重建，旧的向量不能再命中。
    signature = 'materials';
    r.service.configure(
      client: r.client,
      canSend: (source) => source.locator.materialId == r.corpus.materialA,
    );
    final second = await r.service.refresh();
    expect(second.textWritten, 0);
    expect(second.embedded, 5);
    expect(r.textIndex.entryCount, 7);
    expect(r.vectorIndex.sourceCount, 5);
    expect(r.vectorIndex.meta('share_signature'), 'materials');
    final bPage = _pageKey(r.corpus.materialB, 1);
    expect(r.vectorIndex.indexedSources([bPage]), isEmpty);
    expect(r.repository.fullScans, 2);
  });

  test('提交日志里的行变化覆盖材料页、消息与作答三种来源', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();

    final addedPage = await r.materials.addPage(
      materialId: r.corpus.materialB,
      pageNo: 2,
      content: _addedPage,
    );
    final message = await r.conversations.append(
      r.corpus.conversationA,
      role: MessageRole.user,
      content: _addedMessage,
    );
    final question = await r.conversations.create(sourceRef: '例 4-1');
    await r.conversations.setMaterial(
      question,
      materialId: r.corpus.materialA,
      pageNo: 2,
    );
    await r.conversations.append(
      question,
      role: MessageRole.user,
      content: _addedQuestion,
    );
    final attempt = await r.attempts.ensureOpenAttempt(question);
    await r.attempts.submit(
      attempt.id,
      answer: _addedAnswer,
      isCorrect: true,
      independent: true,
    );

    final refresh = await r.service.refresh();
    expect(refresh.total, 4);
    expect(refresh.failed, 0);
    final materialPage = await r.repository.semanticSourceOfRow(
      'material_page',
      addedPage,
    );
    final messageSource = await r.repository.semanticSourceOfRow(
      'message',
      message.id,
    );
    final attemptSource = await r.repository.semanticSourceOfRow(
      'attempt',
      attempt.id,
    );
    expect(materialPage, isNotNull);
    expect(messageSource, isNotNull);
    expect(attemptSource, isNotNull);
    for (final source in [materialPage!, messageSource!, attemptSource!]) {
      final key = source.locator.sourceKey;
      expect(
        (r.textIndex.indexedSources([key]))[key]!.sourceVersion,
        source.sourceVersion,
        reason: '文本集合按当前来源版本写入：$key',
      );
      expect(
        (r.vectorIndex.indexedSources([key]))[key]!.sourceVersion,
        source.sourceVersion,
        reason: '向量集合按当前来源版本写入：$key',
      );
    }
    expect(r.repository.fullScans, 1);
  });

  test('数据代次变化时读取位置归零，索引按当前数据全量重建', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();
    final before = await _searchPosition(r.rig);
    expect(before, greaterThan(0));

    // 清理历史推进代次：索引里的内容对不上当前数据，读取位置先归零再清空。
    await r.rig.engine.clearHistory(r.rig.raw);

    final refresh = await r.service.refresh();
    expect(refresh.failed, 0);
    expect(r.repository.fullScans, 2, reason: '代次变化之后退回全量扫描');
    expect(
      await _searchPosition(r.rig),
      await r.rig.engine.headId(r.rig.raw),
      reason: '重建完成之后位置推进到当前 HEAD',
    );
    expect(r.textIndex.entryCount, 7);
    expect(r.vectorIndex.sourceCount, 7);
  });

  test('索引读取位置丢失时按全量扫描重建，位置随后重新登记', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();
    final head = await r.rig.engine.headId(r.rig.raw);
    expect(await _searchPosition(r.rig), head);

    // 位置被清掉（换库、恢复旧备份或旧版本状态文件没有登记位置）：按全量扫描
    // 重建，不能把“没有登记过”当成“已经处理到 HEAD”。
    await RevisionCursors(r.rig.raw).delete(IndexCursorNames.search);
    await r.materials.correctPage(
      pageId: r.corpus.pageA1,
      content: _revisedEntropy,
    );

    final refresh = await r.service.refresh();
    expect(r.repository.fullScans, 2);
    expect(refresh.textWritten, 1);
    expect(refresh.embedded, 1);
    expect(await _searchPosition(r.rig), await r.rig.engine.headId(r.rig.raw));
  });

  test('索引被重建成空集合之后位置归零并按全量重建，不从旧位置接着读', () async {
    final r = await _buildRig();
    addTearDown(r.close);
    await r.service.refresh();
    expect(r.textIndex.entryCount, 7);
    expect(r.vectorIndex.sourceCount, 7);

    // 模拟结构损坏被重建：两份集合都是空的，状态文件里没有刷新记录，读取位置
    // 却还停在旧提交。下一次刷新必须从头重建，否则空集合会一直空着。
    r.textIndex.clear();
    r.vectorIndex.clear();

    final refresh = await r.service.refresh();
    expect(r.repository.fullScans, 2, reason: '空集合要从头重建');
    expect(refresh.failed, 0);
    expect(refresh.textWritten, 7);
    expect(refresh.embedded, 7);
    expect(r.textIndex.entryCount, 7);
    expect(r.vectorIndex.sourceCount, 7);
    expect(await _searchPosition(r.rig), await r.rig.engine.headId(r.rig.raw));
  });

  test('非阻塞的索引读取位置不阻止裁剪与清理历史', () async {
    final clock = MutableTestClock(DateTime(2026, 1, 1, 9));
    final r = await _buildRig(engine: RevisionEngine(clock: clock.call));
    addTearDown(r.close);
    await r.service.refresh();
    final indexedAt = await _searchPosition(r.rig);
    expect(indexedAt, greaterThan(0));

    // 索引之后又有提交：位置落后于 HEAD，但它是非阻塞位置，不能挡住裁剪。
    clock.advance(const Duration(days: 30));
    await r.materials.addPage(
      materialId: r.corpus.materialA,
      pageNo: 3,
      content: _addedPage,
    );
    final head = await r.rig.engine.headId(r.rig.raw);
    expect(head, greaterThan(indexedAt));
    expect(await RevisionCursors(r.rig.raw).minimumBlockingPosition(), isNull);
    expect(await r.rig.revisions.historyBlockers(clearing: true), isEmpty);

    final pruned = await r.rig.engine.prune(
      r.rig.raw,
      retentionDays: 0,
      maxBytes: 1,
    );
    expect(pruned.removedCommits, greaterThan(0));
    // 位置行本身保留：它是下一次增量刷新的起点，不被裁剪清掉。
    expect(await _searchPosition(r.rig), indexedAt);
  });
}
