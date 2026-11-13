import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/search_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/rules/query_shape.dart';

import '../support/test_db.dart';

class _Corpus {
  _Corpus({
    required this.goalProbability,
    required this.goalLinear,
    required this.materialProbability,
    required this.materialLinear,
    required this.discussion,
    required this.question,
    required this.noise,
    required this.draftAnswer,
  });

  final int goalProbability;
  final int goalLinear;
  final int materialProbability;
  final int materialLinear;
  final int discussion;
  final int question;
  final int noise;
  final int draftAnswer;
}

Future<_Corpus> _seed(RawDatabase db) async {
  final conversations = ConversationRepository(db.rawDb);
  final attempts = AttemptRepository(db.rawDb);
  final materials = MaterialRepository(db.rawDb);
  final tasks = TaskRepository(db.rawDb);

  final probability = await tasks.createGoal(title: '概率论期末');
  final linear = await tasks.createGoal(title: '线性代数作业');

  final probabilityMaterial = await materials.create(
    title: '概率论讲义',
    kind: 'book',
    goalId: probability,
  );
  await materials.addPage(
    materialId: probabilityMaterial,
    pageNo: 1,
    content: '热力学第二定律：孤立系统的熵不会减少，熵是状态函数。',
  );
  await materials.addPage(
    materialId: probabilityMaterial,
    pageNo: 2,
    content: '例 3-2 求条件概率 P(A|B)，其中 A、B 为两个事件。',
  );
  await materials.addPage(
    materialId: probabilityMaterial,
    pageNo: 3,
    content: '设 f(x)=x²，求 f(x) 的导数。',
  );
  await materials.addPage(
    materialId: probabilityMaterial,
    pageNo: 4,
    content: '例 3-20 是另一道题。',
  );
  await materials.addPage(
    materialId: probabilityMaterial,
    pageNo: 5,
    content: 'axb 只是字母连写，不是矩阵记号。',
  );

  final linearMaterial = await materials.create(
    title: '线性代数讲义',
    kind: 'book',
    goalId: linear,
  );
  await materials.addPage(
    materialId: linearMaterial,
    pageNo: 1,
    content: '矩阵 A 的第 b 列记作 a_b，这是列向量的写法。',
  );

  final discussion = await conversations.create(title: '熵与时间');
  await conversations.setGoal(discussion, probability);
  await conversations.append(discussion, role: 'user', content: '熵增和时间箭头有关系吗？');
  await conversations.append(
    discussion,
    role: 'assistant',
    content: '熵是状态函数，可逆过程才保持不变。',
  );

  final question = await conversations.create(sourceRef: '例 3-2');
  await conversations.setGoal(question, probability);
  await conversations.append(question, role: 'user', content: '例 3-2 的解法是什么');
  final attemptId = await attempts.ensureOpenAttempt(question);
  await attempts.submit(
    attemptId.id,
    answer: '先求 P(A|B)=P(AB)/P(B)，答案是 0.4。',
    isCorrect: true,
    independent: true,
  );

  // 没有归属的记录：普通问句里出现近似字符，用于确认字面查找不会误命中。
  final noise = await conversations.create(title: '符号写法');
  await conversations.append(
    noise,
    role: 'user',
    content: 'fx 与 f x 是两种写法，axb 也不是 a_b。',
  );
  final noiseAttempt = await attempts.ensureOpenAttempt(noise);
  await attempts.submit(
    noiseAttempt.id,
    answer: 'axb 和 a b 都写过，但不影响结论。',
    isCorrect: false,
    independent: null,
  );

  // 未提交草稿：作答查找只认已提交的作答。
  final draftConversation = await conversations.create(title: '草稿');
  await conversations.setGoal(draftConversation, probability);
  await conversations.append(draftConversation, role: 'user', content: '先写一半');
  final draft = await attempts.ensureOpenAttempt(draftConversation);
  await attempts.saveDraft(draft.id, answer: '熵，还没写完');

  return _Corpus(
    goalProbability: probability,
    goalLinear: linear,
    materialProbability: probabilityMaterial,
    materialLinear: linearMaterial,
    discussion: discussion,
    question: question,
    noise: noise,
    draftAnswer: draft.id,
  );
}

Future<
  ({
    RawDatabase db,
    EvidenceRepository repository,
    EvidenceService evidence,
    SearchService search,
    _Corpus corpus,
  })
>
_rig() async {
  final db = await openTestDb();
  final corpus = await _seed(db);
  final repository = EvidenceRepository(db.rawDb);
  final evidence = EvidenceService(repository: repository);
  return (
    db: db,
    repository: repository,
    evidence: evidence,
    search: SearchService(evidence: evidence),
    corpus: corpus,
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('查询形态：题号、公式与带下划线的名称按原样查找', () {
    expect(shapeQuery('例 3-2').literal, isTrue);
    expect(shapeQuery('例 3-2').terms, isEmpty);
    expect(shapeQuery('f(x)').literal, isTrue);
    expect(shapeQuery('a_b').literal, isTrue);
    expect(shapeQuery('"熵是状态函数"').literal, isTrue);
    expect(shapeQuery('"熵是状态函数"').text, '熵是状态函数');
    expect(shapeQuery('矩阵的秩是怎么定义的').literal, isFalse);
    expect(shapeQuery('矩阵的秩是怎么定义的').terms, isNotEmpty);
    expect(shapeQuery('   ').isEmpty, isTrue);
  });

  test('单字术语、题号与公式能按字面定位，并带回原记录位置', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final entropy = await rig.evidence.userSearch('熵');
    expect(entropy.hits, isNotEmpty);
    final page = entropy.hits.firstWhere(
      (hit) => hit.kind == EvidenceKind.materialPage,
    );
    expect(page.title, '《概率论讲义》第 1 页');
    expect(page.location.materialId, rig.corpus.materialProbability);
    expect(page.location.pageNo, 1);
    expect(page.literal, isTrue);
    expect(page.matchedText, contains('熵'));

    final message = entropy.hits.firstWhere(
      (hit) => hit.kind == EvidenceKind.message,
    );
    expect(message.location.conversationId, rig.corpus.discussion);
    expect(message.location.messageId, isNotNull);
    expect(message.opensDiscussion, isTrue);

    final reference = await rig.evidence.userSearch('例 3-2');
    final labels = reference.hits.map((hit) => hit.identity).toList();
    // 命中第 2 页与题目本身，但不命中「例 3-20」。
    expect(reference.hits.any((hit) => hit.location.pageNo == 2), isTrue);
    expect(reference.hits.any((hit) => hit.location.pageNo == 4), isFalse);
    expect(
      reference.hits.any(
        (hit) =>
            hit.kind == EvidenceKind.question &&
            hit.location.conversationId == rig.corpus.question,
      ),
      isTrue,
    );
    expect(labels, isNotEmpty);

    final formula = await rig.evidence.userSearch('f(x)');
    expect(formula.hits.any((hit) => hit.location.pageNo == 3), isTrue);
    expect(
      formula.hits.any(
        (hit) =>
            hit.location.conversationId == rig.corpus.noise &&
            hit.kind == EvidenceKind.message,
      ),
      isFalse,
    );

    final underscore = await rig.evidence.userSearch('a_b');
    expect(
      underscore.hits.any(
        (hit) => hit.location.materialId == rig.corpus.materialLinear,
      ),
      isTrue,
    );
    // `a_b` 不能按 LIKE 通配符命中 `axb`（第 5 页与噪声记录）。
    expect(underscore.hits.any((hit) => hit.location.pageNo == 5), isFalse);
  });

  test('已提交作答可以按原文找到，未提交草稿不进入结果', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final results = await rig.search.search('P(A|B)');
    final answer = results.entries
        .expand((entry) => entry.hits)
        .singleWhere((hit) => hit.kind == EvidenceKind.answer);
    expect(answer.location.conversationId, rig.corpus.question);
    expect(answer.location.attemptId, isNotNull);
    expect(answer.opensLearning, isTrue);
    expect(answer.snippet, contains('P(A|B)'));

    final drafts = await rig.evidence.userSearch('还没写完');
    expect(
      drafts.hits.any((hit) => hit.kind == EvidenceKind.answer),
      isFalse,
      reason: '未提交草稿不应作为已提交作答进入查找结果',
    );
  });

  test('空查询、无结果与范围外记录的行为明确', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final empty = await rig.evidence.userSearch('   ');
    expect(empty.isEmpty, isTrue);
    expect(empty.hits, isEmpty);

    final nothing = await rig.evidence.userSearch('量子纠缠');
    expect(nothing.isEmpty, isTrue);

    // 用户选定一个目标，结果不包含其他目标与未归属记录。
    final goalScoped = await rig.evidence.userSearch(
      'a_b',
      scope: EvidenceScope.userGoal(rig.corpus.goalProbability),
    );
    expect(goalScoped.isEmpty, isTrue);

    final materialScoped = await rig.evidence.userSearch(
      'a_b',
      scope: EvidenceScope.userMaterial(rig.corpus.materialLinear),
    );
    expect(materialScoped.hits, isNotEmpty);
    expect(
      materialScoped.hits.every(
        (hit) => hit.location.materialId == rig.corpus.materialLinear,
      ),
      isTrue,
    );

    final all = await rig.evidence.userSearch('a_b');
    expect(
      all.hits.any(
        (hit) => hit.location.materialId == rig.corpus.materialLinear,
      ),
      isTrue,
    );
    expect(
      all.hits.any((hit) => hit.location.conversationId == rig.corpus.noise),
      isTrue,
    );
  });

  test('有目标时取同目标或无归属，没有目标时只读当前讨论与带入来源', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final scoped = await rig.evidence.forAnswer(
      query: 'a_b',
      scope: EvidenceScope.answer(goalId: rig.corpus.goalLinear),
    );
    expect(
      scoped.hits.any(
        (hit) => hit.location.materialId == rig.corpus.materialLinear,
      ),
      isTrue,
    );
    expect(
      scoped.hits.any((hit) => hit.location.conversationId == rig.corpus.noise),
      isTrue,
      reason: '有目标时仍保留同样无归属的记录',
    );
    expect(
      scoped.hits.any(
        (hit) => hit.location.conversationId == rig.corpus.question,
      ),
      isFalse,
      reason: '其他目标的题目不进入本次回答范围',
    );

    // 没有目标也没有带入来源：只读当前这条讨论，其他无归属记录不进入候选。
    final withoutGoal = await rig.evidence.forAnswer(
      query: 'a_b',
      scope: const EvidenceScope.answer(),
    );
    expect(withoutGoal.hits, isEmpty);

    final currentRecord = await rig.evidence.forAnswer(
      query: 'a_b',
      scope: EvidenceScope.answer(conversationId: rig.corpus.noise),
    );
    expect(
      currentRecord.hits.every(
        (hit) =>
            hit.location.conversationId == rig.corpus.noise ||
            hit.location.conversationId == null,
      ),
      isTrue,
    );
    expect(
      currentRecord.hits.any(
        (hit) => hit.location.conversationId == rig.corpus.discussion,
      ),
      isFalse,
      reason: '无归属求助不读另一条无归属讨论',
    );

    // 本轮带入的来源按标识放行，但不因此读取它所在的整条讨论。
    final brought = await rig.evidence.forAnswer(
      query: 'a_b',
      scope: EvidenceScope.answer(
        broughtIdentities: {'material_page:${rig.corpus.materialLinear}:1'},
      ),
    );
    expect(
      brought.hits.any(
        (hit) =>
            hit.location.materialId == rig.corpus.materialLinear &&
            hit.location.pageNo == 1,
      ),
      isTrue,
    );
    expect(
      brought.hits.any((hit) => hit.kind != EvidenceKind.materialPage),
      isFalse,
      reason: '只带入一页材料时，不连带读取其他来源',
    );
  });

  test('断网或没有模型时查找仍可完成', () async {
    // 查找服务只读取业务库；这里没有配置回答模型，也没有任何网络客户端。
    final rig = await _rig();
    addTearDown(rig.db.close);

    final results = await rig.search.search('例 3-2');
    expect(results.isEmpty, isFalse);
    expect(
      results.entries.map((entry) => entry.key),
      contains('conversation:${rig.corpus.question}'),
    );
  });

  test('核对当前记录：更正后的版本与改变归属之后不再使用旧命中', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final hit = (await rig.evidence.userSearch('熵')).hits
        .firstWhere((hit) => hit.kind == EvidenceKind.materialPage);
    final current = await rig.repository.current(hit);
    expect(current, isNotNull);
    expect(current!.sourceVersion, hit.sourceVersion);

    await rig.db.update(
      'material_page',
      {'content': '熵的另一种表述：混乱程度的度量。', 'updated_at': '2026-11-12 09:00:00'},
      where: 'material_id = ? AND page_no = ?',
      whereArgs: [rig.corpus.materialProbability, 1],
    );
    final changed = await rig.repository.current(hit);
    expect(changed, isNotNull);
    expect(changed!.sourceVersion, isNot(hit.sourceVersion));
    expect(
      await rig.repository.inScope(hit, const EvidenceScope.userAll()),
      isTrue,
    );

    final conversationHit = (await rig.evidence.userSearch('熵增')).hits
        .firstWhere((hit) => hit.kind == EvidenceKind.message);
    expect(
      await rig.repository.inScope(
        conversationHit,
        EvidenceScope.answer(goalId: rig.corpus.goalLinear),
      ),
      isFalse,
    );

    await rig.db.delete(
      'material_page',
      where: 'material_id = ? AND page_no = ?',
      whereArgs: [rig.corpus.materialProbability, 3],
    );
    final removed = (await rig.evidence.userSearch('f(x)')).hits
        .where((hit) => hit.kind == EvidenceKind.materialPage)
        .toList();
    expect(removed.any((hit) => hit.location.pageNo == 3), isFalse);
  });

  test('同一来源重复命中只保留一条，字面命中排在关键词命中之前', () async {
    final rig = await _rig();
    addTearDown(rig.db.close);

    final bundle = await rig.evidence.userSearch('熵');
    final identities = bundle.hits.map((hit) => hit.identity).toList();
    expect(identities.toSet().length, identities.length);

    final first = bundle.hits.first;
    expect(first.literal, isTrue);
  });
}
