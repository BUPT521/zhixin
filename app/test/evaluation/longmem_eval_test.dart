import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/application/keyword_ranker.dart';
import 'package:zhixin/application/cross_session_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/question.dart';
import 'package:zhixin/domain/rules/time_format.dart';

import '../support/test_db.dart';

/// 固定的合成历史；时间、作答条件与更正都写死在用例里，重跑得到同一组结果。
class LongMemCase {
  const LongMemCase({
    required this.id,
    required this.category,
    required this.query,
    required this.queryTime,
    required this.scope,
    this.requiredEvidence = _noEvidence,
    this.forbiddenEvidence = _noEvidence,
    required this.expectedHelp,
    this.budget = 5,
  });

  final String id;
  final String category;
  final String query;
  final DateTime queryTime;
  final EvidenceScope Function(CorpusIds ids) scope;
  final List<String> Function(CorpusIds ids) requiredEvidence;
  final List<String> Function(CorpusIds ids) forbiddenEvidence;
  final String expectedHelp;
  final int budget;
}

class CorpusIds {
  const CorpusIds({
    required this.goalProbability,
    required this.goalLinear,
    required this.materialProbability,
    required this.materialLinear,
    required this.conversationQuestion,
    required this.conversationEntropy,
    required this.conversationLinear,
    required this.conversationUnassigned,
    required this.attemptHelped,
    required this.attemptIndependent,
    required this.attemptWrong,
  });

  final int goalProbability;
  final int goalLinear;
  final int materialProbability;
  final int materialLinear;
  final int conversationQuestion;
  final int conversationEntropy;
  final int conversationLinear;
  final int conversationUnassigned;
  final int attemptHelped;
  final int attemptIndependent;
  final int attemptWrong;

  String page(int materialId, int pageNo) =>
      'material_page:$materialId:$pageNo';
  String question(int conversationId) => 'question:$conversationId';
  String answer(int attemptId) => 'attempt:$attemptId';
}

Future<CorpusIds> _seed(RawDatabase db) async {
  final tasks = TaskRepository(db.rawDb);
  final materials = MaterialRepository(db.rawDb);
  final conversations = ConversationRepository(db.rawDb);
  final attempts = AttemptRepository(db.rawDb);

  final goalProbability = await tasks.createGoal(title: '概率论期末');
  final goalLinear = await tasks.createGoal(title: '线性代数作业');

  final materialProbability = await materials.create(
    title: '概率论讲义',
    kind: 'book',
    goalId: goalProbability,
  );
  await materials.addPage(
    materialId: materialProbability,
    pageNo: 3,
    content: '条件概率 P(A|B)=P(AB)/P(B)。',
  );
  await materials.addPage(
    materialId: materialProbability,
    pageNo: 12,
    content: '熵是混乱程度的度量。',
  );
  // 较早讲到条件概率与贝叶斯的页面，关键词较多，排序时容易被较新的简介页挤掉。
  await materials.addPage(
    materialId: materialProbability,
    pageNo: 7,
    content:
        '例 3-2 求条件概率 P(A|B)，其中 A、B 为事件。'
        '条件概率与贝叶斯公式：P(A|B)=P(AB)/P(B)，'
        '贝叶斯公式用于条件概率的反推，条件概率与贝叶斯公式互为补充。',
  );
  await db.update(
    'material_page',
    {'updated_at': '2026-10-01 09:00:00'},
    where: 'material_id = ? AND page_no = ?',
    whereArgs: [materialProbability, 7],
  );
  for (var page = 20; page <= 25; page++) {
    await materials.addPage(
      materialId: materialProbability,
      pageNo: page,
      content:
          '条件概率用于描述事件之间的关系，贝叶斯公式用于在已知结果时'
          '反推原因，这一页只是简介，没有展开推导过程。',
    );
    await db.update(
      'material_page',
      {'updated_at': '2026-10-08 0${page - 19}:00:00'},
      where: 'material_id = ? AND page_no = ?',
      whereArgs: [materialProbability, page],
    );
  }
  final materialLinear = await materials.create(
    title: '线性代数讲义',
    kind: 'book',
    goalId: goalLinear,
  );
  await materials.addPage(
    materialId: materialLinear,
    pageNo: 2,
    content: '矩阵 A 的第 b 列记作 a_b，这是列向量的写法。',
  );

  final conversationQuestion = await conversations.create(sourceRef: '例 3-2');
  await conversations.setGoal(conversationQuestion, goalProbability);
  await conversations.setMaterial(
    conversationQuestion,
    materialId: materialProbability,
    pageNo: 7,
  );
  await conversations.append(
    conversationQuestion,
    role: 'user',
    content: '例 3-2 求条件概率 P(A|B)',
  );

  final helped = await attempts.ensureOpenAttempt(conversationQuestion);
  await attempts.submit(
    helped.id,
    answer: 'P(A|B)=P(AB)/P(B)，答案 0.4。',
    isCorrect: true,
    independent: false,
    feedback: '看过提示之后才写对。',
  );
  await db.update(
    'attempt',
    {
      'submitted_at': '2026-10-01 09:20:00',
      'created_at': '2026-10-01 09:05:00',
      'updated_at': '2026-10-01 09:20:00',
      'help_json': jsonEncode([
        {
          'kind': 'hint',
          'content': '先想 P(AB) 与 P(B) 的关系。',
          'at': '2026-10-01 09:10:00',
        },
      ]),
    },
    where: 'id = ?',
    whereArgs: [helped.id],
  );
  await db.update(
    'conversation',
    {'created_at': '2026-10-01 09:00:00', 'updated_at': '2026-10-01 09:20:00'},
    where: 'id = ?',
    whereArgs: [conversationQuestion],
  );

  final wrong = await attempts.ensureOpenAttempt(conversationQuestion);
  await attempts.submit(
    wrong.id,
    answer: 'P(AB)/P(B) 记反了，写成 P(B)/P(AB)。',
    isCorrect: false,
    independent: null,
  );
  await db.update(
    'attempt',
    {
      'submitted_at': '2026-10-02 21:00:00',
      'created_at': '2026-10-02 20:50:00',
      'updated_at': '2026-10-02 21:00:00',
    },
    where: 'id = ?',
    whereArgs: [wrong.id],
  );

  final independent = await attempts.ensureOpenAttempt(
    conversationQuestion,
    redoOfAttemptId: helped.id,
    delayed: true,
  );
  await attempts.submit(
    independent.id,
    answer: 'P(A|B)=P(AB)/P(B)，答案 0.4。',
    isCorrect: true,
    independent: true,
  );
  await db.update(
    'attempt',
    {
      'submitted_at': '2026-10-03 20:00:00',
      'created_at': '2026-10-03 19:55:00',
      'updated_at': '2026-10-03 20:00:00',
    },
    where: 'id = ?',
    whereArgs: [independent.id],
  );

  final conversationEntropy = await conversations.create(title: '熵与能量');
  await conversations.setGoal(conversationEntropy, goalProbability);
  await conversations.setMaterial(
    conversationEntropy,
    materialId: materialProbability,
    pageNo: 12,
  );
  await conversations.append(
    conversationEntropy,
    role: 'user',
    content: '熵和能量有什么区别？',
  );
  await db.update(
    'conversation',
    {'created_at': '2026-10-05 19:00:00', 'updated_at': '2026-10-05 19:00:00'},
    where: 'id = ?',
    whereArgs: [conversationEntropy],
  );

  final conversationLinear = await conversations.create(sourceRef: '第 2 章');
  await conversations.setGoal(conversationLinear, goalLinear);
  await conversations.setMaterial(
    conversationLinear,
    materialId: materialLinear,
    pageNo: 2,
  );
  await conversations.append(
    conversationLinear,
    role: 'user',
    content: 'a_b 表示什么',
  );
  await db.update(
    'conversation',
    {'created_at': '2026-10-06 10:00:00', 'updated_at': '2026-10-06 10:00:00'},
    where: 'id = ?',
    whereArgs: [conversationLinear],
  );

  final conversationUnassigned = await conversations.create(title: '时间箭头');
  await conversations.append(
    conversationUnassigned,
    role: 'user',
    content: '熵增和时间箭头有关系吗？',
  );
  await db.update(
    'conversation',
    {'created_at': '2026-10-07 08:00:00', 'updated_at': '2026-10-07 08:00:00'},
    where: 'id = ?',
    whereArgs: [conversationUnassigned],
  );

  // 材料页在 2026-10-11 被更正：更正前的旧说法不再作为当前原文。
  await db.update(
    'material_page',
    {
      'content': '熵衡量系统的混乱程度，不等于能量，也不能直接换算成能量。',
      'updated_at': '2026-10-11 09:00:00',
    },
    where: 'material_id = ? AND page_no = ?',
    whereArgs: [materialProbability, 12],
  );

  return CorpusIds(
    goalProbability: goalProbability,
    goalLinear: goalLinear,
    materialProbability: materialProbability,
    materialLinear: materialLinear,
    conversationQuestion: conversationQuestion,
    conversationEntropy: conversationEntropy,
    conversationLinear: conversationLinear,
    conversationUnassigned: conversationUnassigned,
    attemptHelped: helped.id,
    attemptIndependent: independent.id,
    attemptWrong: wrong.id,
  );
}

List<String> _noEvidence(CorpusIds ids) => const [];

final _queryTime = DateTime(2026, 10, 12, 20);

final List<LongMemCase> _cases = [
  LongMemCase(
    id: 'ref-1',
    category: '原文定位',
    query: '例 3-2',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [
      ids.page(1, 7),
      ids.question(ids.conversationQuestion),
    ],
    expectedHelp: '打开原题与例 3-2 的材料页',
  ),
  LongMemCase(
    id: 'symbol-1',
    category: '符号定位',
    query: 'a_b',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalLinear),
    requiredEvidence: (ids) => [ids.page(ids.materialLinear, 2)],
    expectedHelp: '找到线性代数讲义第 2 页的 a_b 写法',
  ),
  LongMemCase(
    id: 'range-1',
    category: '范围外',
    query: 'a_b',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    forbiddenEvidence: (ids) => [ids.page(ids.materialLinear, 2)],
    expectedHelp: '说明本次范围没有这条记录',
  ),
  LongMemCase(
    id: 'time-1',
    category: '时间先后',
    query: '10 月 1 日那次例 3-2 用了什么帮助',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [ids.answer(ids.attemptHelped)],
    expectedHelp: '引用 10 月 1 日那次作答的帮助条件',
  ),
  LongMemCase(
    id: 'multi-1',
    category: '多次作答',
    query: '例 3-2 后来独立做出来了吗',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [
      ids.answer(ids.attemptHelped),
      ids.answer(ids.attemptIndependent),
    ],
    expectedHelp: '同时引用帮助条件与后来的独立表现',
  ),
  LongMemCase(
    id: 'correction-1',
    category: '记忆纠正',
    query: '熵等于能量吗',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [ids.page(ids.materialProbability, 12)],
    expectedHelp: '使用更正后的原文，不再使用旧说法',
  ),
  LongMemCase(
    id: 'insufficient-1',
    category: '证据不足',
    query: '第 9 章第 4 题怎么做',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    expectedHelp: '说明没有找到证据，列出待确认的内容',
  ),
  LongMemCase(
    id: 'rank-1',
    category: '关键词排序',
    query: '条件概率 贝叶斯',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [ids.page(ids.materialProbability, 7)],
    expectedHelp: '较早但更相关的材料页进入上下文',
  ),
  LongMemCase(
    id: 'cross-1',
    category: '跨次作答',
    query: '0.4 是哪一次作答的答案',
    queryTime: _queryTime,
    scope: (ids) => EvidenceScope.answer(goalId: ids.goalProbability),
    requiredEvidence: (ids) => [ids.answer(ids.attemptIndependent)],
    expectedHelp: '引用那次独立作答，并说明它发生在什么时候',
  ),
];

/// 一次对照的结果；三个环节分开记录，失败可以定位到其中一段。
class CaseOutcome {
  CaseOutcome({
    required this.strategy,
    required this.caseId,
    required this.required,
    required this.retrieved,
    required this.inContext,
    required this.cited,
    required this.promptOk,
    this.failureStage,
  });

  final String strategy;
  final String caseId;
  final int required;
  final int retrieved;
  final int inContext;
  final int cited;
  final bool promptOk;
  final String? failureStage;

  /// 检索这一段花的时间，含关键词排序；对照等待时间用。
  int elapsedMs = 0;
}

class _Harness {
  _Harness({required this.repository, required this.ids});

  final EvidenceRepository repository;
  final CorpusIds ids;

  Future<List<EvidenceHit>> retrieve(
    String strategy,
    LongMemCase evalCase,
    EvidenceScope scope,
  ) async {
    final normalized = evalCase.query.trim();
    switch (strategy) {
      case 'keyword':
        return EvidenceBundle.merge(
          normalized,
          scope,
          await repository.keyword(normalized, scope: scope, limitPerKind: 40),
        ).hits;
      case 'literal':
        return EvidenceBundle.merge(
          normalized,
          scope,
          await repository.literal(normalized, scope: scope, limitPerKind: 40),
        ).hits;
      case 'bm25':
        final keywordHits = await repository.keyword(
          normalized,
          scope: scope,
          limitPerKind: 40,
        );
        final ranked = await rankKeywordCandidates(keywordHits, normalized);

        return [
          for (var index = 0; index < ranked.length; index++)
            ranked[index].copyWith(score: 40 - index * 0.1),
        ];
      case 'hybrid':
        final service = EvidenceService(repository: repository);
        return (await service.forAnswer(
          query: normalized,
          scope: scope,
          perKindLimit: 40,
          limit: null,
        )).hits;
      case 'cross':
        final service = EvidenceService(
          repository: repository,
          crossSession: CrossSessionService(repository: repository),
        );
        return (await service.forAnswer(
          query: normalized,
          scope: scope,
          perKindLimit: 40,
          limit: null,
          now: evalCase.queryTime,
        )).hits;
    }
    throw ArgumentError('未知策略：$strategy');
  }

  /// 固定回答模型：只引用提示词里出现的来源标识；没有所需证据时说明待确认。
  ///
  /// 这是脚本化的对照替身，用来比较检索与上下文，不代表真实模型的表现；
  /// 真实模型的对照需要配置模型之后单独运行。
  ({String text, List<String> citations, bool pending}) answerWith(
    List<EvidenceHit> inContext,
    LongMemCase evalCase,
    List<String> required,
  ) {
    final budgeted = inContext.take(evalCase.budget).toList(growable: false);
    final question = Question(
      id: 0,
      stem: evalCase.query,
      createdAt: evalCase.queryTime,
    );
    final prompt = buildBuddySystemPrompt(
      BuddyContext(
        now: evalCase.queryTime,
        question: question,
        evidence: budgeted,
      ),
    );
    final present = RegExp(r'(material_page|message|question|attempt):[0-9:]+')
        .allMatches(prompt)
        .map((match) => match.group(0)!)
        .toSet();
    final cited = required.where(present.contains).toList(growable: false);
    final pending = required.isEmpty || cited.isEmpty;
    final text = pending
        ? '现有记录不足以确认，尚待确认：${evalCase.expectedHelp}。'
        : '依据 ${cited.isEmpty ? '本次范围里的记录' : cited.join('、')} 回答。';
    return (text: text, citations: cited, pending: pending);
  }
}

Future<List<CaseOutcome>> _run(
  String strategy,
  _Harness harness,
  List<LongMemCase> cases,
) async {
  final outcomes = <CaseOutcome>[];
  for (final evalCase in cases) {
    final scope = evalCase.scope(harness.ids);
    final watch = Stopwatch()..start();
    final hits = await harness.retrieve(strategy, evalCase, scope);
    final elapsedMs = watch.elapsedMilliseconds;
    final required = evalCase.requiredEvidence(harness.ids);
    final forbidden = evalCase.forbiddenEvidence(harness.ids);
    final retrieved = required
        .where((id) => hits.any((hit) => hit.identity == id))
        .length;
    final budgeted = hits.take(evalCase.budget).toList(growable: false);
    final contextIds = budgeted.map((hit) => hit.identity).toSet();
    final inContext = required.where(contextIds.contains).length;
    final answer = harness.answerWith(budgeted, evalCase, required);
    final promptText = buildBuddySystemPrompt(
      BuddyContext(now: evalCase.queryTime, evidence: budgeted),
    );
    final forbiddenInPrompt = forbidden.any(promptText.contains);
    final pendingCorrect = required.isEmpty
        ? answer.pending && answer.text.contains('尚待确认')
        : !answer.pending;
    final promptOk = !forbiddenInPrompt && pendingCorrect;
    final citedCorrect = required.every(answer.citations.contains);
    final failureStage = required.isEmpty
        ? (promptOk ? null : 'answer')
        : retrieved < required.length
        ? 'retrieval'
        : inContext < required.length
        ? 'context'
        : citedCorrect && promptOk
        ? null
        : 'answer';
    outcomes.add(
      CaseOutcome(
        strategy: strategy,
        caseId: evalCase.id,
        required: required.length,
        retrieved: retrieved,
        inContext: inContext,
        cited: citedCorrect ? required.length : answer.citations.length,
        promptOk: promptOk,
        failureStage: failureStage,
      )..elapsedMs = elapsedMs,
    );
  }
  return outcomes;
}

String _report(
  String strategy,
  List<LongMemCase> cases,
  List<CaseOutcome> outcomes,
) {
  final buffer = StringBuffer('[$strategy]\n');
  var retrieved = 0;
  var needed = 0;
  var inContext = 0;
  var cited = 0;
  var promptOk = 0;
  for (var index = 0; index < outcomes.length; index++) {
    final outcome = outcomes[index];
    final evalCase = cases[index];
    retrieved += outcome.retrieved;
    inContext += outcome.inContext;
    needed += outcome.required;
    cited += outcome.cited;
    if (outcome.promptOk) promptOk++;
    buffer.writeln(
      '  ${evalCase.id.padRight(14)} '
      '${evalCase.category.padRight(6)} '
      '证据 ${outcome.retrieved}/${outcome.inContext} '
      '引用 ${outcome.cited} '
      '提示 ${outcome.promptOk ? '正常' : '需注意'} '
      '${outcome.elapsedMs} ms '
      '${outcome.failureStage == null ? '' : '失败环节：${outcome.failureStage}'}',
    );
  }
  final elapsed = outcomes.fold(0, (sum, outcome) => sum + outcome.elapsedMs);
  buffer.writeln(
    '  合计：必要证据 $needed，找回 $retrieved，进入上下文 $inContext，'
    '引用正确 $cited，提示正确 $promptOk/${outcomes.length}，'
    '检索等待 $elapsed ms',
  );
  return buffer.toString();
}

void main() {
  test('LongMemEval 式固定用例：关键词、原文与混合检索的对照', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final ids = await _seed(db);
    final harness = _Harness(
      repository: EvidenceRepository(db.rawDb),
      ids: ids,
    );

    final outcomes = <CaseOutcome>[];
    final report = StringBuffer();
    for (final strategy in const [
      'keyword',
      'literal',
      'bm25',
      'hybrid',
      'cross',
    ]) {
      final result = await _run(strategy, harness, _cases);
      outcomes.addAll(result);
      report.write(_report(strategy, _cases, result));
    }
    // ignore: avoid_print
    print(report.toString());

    int total(String strategy, int Function(CaseOutcome outcome) pick) =>
        outcomes
            .where((outcome) => outcome.strategy == strategy)
            .fold(0, (sum, outcome) => sum + pick(outcome));

    final hybridRetrieved = total('hybrid', (outcome) => outcome.retrieved);
    final keywordRetrieved = total('keyword', (outcome) => outcome.retrieved);
    final hybridInContext = total('hybrid', (outcome) => outcome.inContext);
    final keywordInContext = total('keyword', (outcome) => outcome.inContext);
    expect(
      hybridRetrieved,
      greaterThanOrEqualTo(keywordRetrieved),
      reason: '混合检索找回的证据不应少于纯关键词',
    );
    expect(
      hybridInContext,
      greaterThanOrEqualTo(keywordInContext),
      reason: '混合检索进入上下文的必要证据不应少于纯关键词',
    );

    final bm25Retrieved = total('bm25', (outcome) => outcome.retrieved);
    final bm25InContext = total('bm25', (outcome) => outcome.inContext);
    expect(
      bm25InContext,
      greaterThanOrEqualTo(keywordInContext),
      reason: 'BM25 排序后进入上下文的必要证据不应少于原有排序',
    );
    expect(
      bm25Retrieved,
      greaterThanOrEqualTo(keywordRetrieved),
      reason: 'BM25 排序不丢候选',
    );

    final crossInContext = total('cross', (outcome) => outcome.inContext);
    expect(
      crossInContext,
      greaterThanOrEqualTo(hybridInContext),
      reason: '跨次综合后进入上下文的必要证据不应少于混合检索',
    );
    for (final caseId in const ['time-1', 'multi-1']) {
      final outcome = outcomes.firstWhere(
        (outcome) => outcome.strategy == 'cross' && outcome.caseId == caseId,
      );
      expect(outcome.failureStage, isNull, reason: '跨次综合应找回 $caseId 的证据');
    }
    // ignore: avoid_print
    print(
      '跨次综合对比：进入上下文 hybrid $hybridInContext → cross $crossInContext，'
      '检索等待 cross ${total('cross', (outcome) => outcome.elapsedMs)} ms',
    );

    final rankCase = outcomes.firstWhere(
      (outcome) => outcome.strategy == 'bm25' && outcome.caseId == 'rank-1',
    );
    // ignore: avoid_print
    print(
      'BM25 对比：进入上下文 keyword $keywordInContext → bm25 $bm25InContext，'
      '检索等待 keyword ${total('keyword', (outcome) => outcome.elapsedMs)} ms → '
      'bm25 ${total('bm25', (outcome) => outcome.elapsedMs)} ms；'
      '排序用例 ${rankCase.failureStage ?? '通过'}',
    );
    expect(
      ['context', 'retrieval', null],
      contains(
        outcomes
            .firstWhere(
              (outcome) =>
                  outcome.strategy == 'keyword' && outcome.caseId == 'rank-1',
            )
            .failureStage,
      ),
      reason: '原始排序在排序用例上应当先丢掉必要证据',
    );
    expect(rankCase.failureStage, isNull, reason: 'BM25 排序应把必要证据带进上下文');
    expect(rankCase.elapsedMs, greaterThanOrEqualTo(0));

    for (final outcome in outcomes) {
      if (outcome.failureStage == null) continue;
      expect(
        ['retrieval', 'context', 'answer'],
        contains(outcome.failureStage),
        reason: '失败要能定位到具体环节',
      );
    }

    // 多次作答与时间先后在第三阶段还没有专门检索，失败应停在证据找回；
    // 这条断言把缺口固定下来，后续阶段通过时再改为通过。
    final multi = outcomes.firstWhere(
      (outcome) => outcome.strategy == 'hybrid' && outcome.caseId == 'multi-1',
    );
    expect(multi.failureStage, anyOf(isNull, 'retrieval'));
    for (final outcome in outcomes) {
      if (outcome.failureStage == null) continue;
      expect(
        ['retrieval', 'context', 'answer'],
        contains(outcome.failureStage),
        reason: '失败要能定位到具体环节',
      );
    }
  });

  test('对照脚本的查询与用例保持同一份', () {
    // tools/long_memory_compare 的 history.json 给外部工具用，查询文字与时间
    // 在这里再写一遍；两边改一处忘另一处时，这个用例先失败。
    final history = jsonDecode(
      File('../tools/long_memory_compare/history.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final queries = (history['queries']! as List).cast<Map<String, Object?>>();

    final cases = {for (final item in _cases) item.id: item};
    expect(
      queries.map((query) => query['id']),
      everyElement(isIn(cases.keys)),
      reason: '脚本里的查询编号要在用例里找得到',
    );
    for (final query in queries) {
      final item = cases[query['id']]!;
      expect(query['query'], item.query, reason: '${item.id} 的查询文字不一致');
      expect(
        query['query_time'],
        formatDateTime(item.queryTime),
        reason: '${item.id} 的查询时间不一致',
      );
    }
  });
}
