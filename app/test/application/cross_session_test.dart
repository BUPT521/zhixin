import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/cross_session_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/rules/time_condition.dart';

import '../support/test_db.dart';

class _Corpus {
  _Corpus({
    required this.goal,
    required this.material,
    required this.conversationA,
    required this.conversationB,
    required this.conversationC,
    required this.conversationSameQuestion,
    required this.attemptHelped,
    required this.attemptIndependent,
    required this.attemptOtherGoalConversation,
  });

  final int goal;
  final int material;
  final int conversationA;
  final int conversationB;
  final int conversationC;
  final int conversationSameQuestion;
  final int attemptHelped;
  final int attemptIndependent;
  final int attemptOtherGoalConversation;
}

Future<_Corpus> _seed(RawDatabase db) async {
  final tasks = TaskRepository(db.rawDb);
  final materials = MaterialRepository(db.rawDb);
  final conversations = ConversationRepository(db.rawDb);
  final attempts = AttemptRepository(db.rawDb);
  final goal = await tasks.createGoal(title: '概率论期末');
  final material = await materials.create(title: '概率论讲义', goalId: goal);
  await materials.addPage(materialId: material, pageNo: 7, content: '例 3-2。');
  await materials.addPage(materialId: material, pageNo: 1, content: '条件概率。');

  Future<int> conversation({required String stem, int pageNo = 7}) async {
    final id = await conversations.create();
    await conversations.setGoal(id, goal);
    await conversations.setMaterial(id, materialId: material, pageNo: pageNo);
    await conversations.append(id, role: 'user', content: stem);
    return id;
  }

  final conversationA = await conversation(stem: '例 3-2 求条件概率');
  final helped = await attempts.ensureOpenAttempt(conversationA);
  await attempts.submit(
    helped.id,
    answer: '看过提示才写对。',
    isCorrect: true,
    independent: false,
  );
  await db.update(
    'attempt',
    {
      'submitted_at': '2026-10-01 09:20:00',
      'created_at': '2026-10-01 09:05:00',
      'updated_at': '2026-10-01 09:20:00',
      'help_json':
          '[{"kind":"hint","content":"先想 P(AB)","at":"2026-10-01 09:10:00"}]',
    },
    where: 'id = ?',
    whereArgs: [helped.id],
  );
  final independent = await attempts.ensureOpenAttempt(
    conversationA,
    redoOfAttemptId: helped.id,
    delayed: true,
  );
  await attempts.submit(
    independent.id,
    answer: 'P(A|B)=P(AB)/P(B)',
    isCorrect: true,
    independent: true,
    delayed: true,
  );
  await db.update(
    'attempt',
    {'submitted_at': '2026-10-03 20:00:00'},
    where: 'id = ?',
    whereArgs: [independent.id],
  );

  // 同一目标下无关的记录，范围里不应被带进来。
  final conversationB = await conversation(stem: '熵与能量');
  final other = await attempts.ensureOpenAttempt(conversationB);
  await attempts.submit(
    other.id,
    answer: '熵不等于能量。',
    isCorrect: false,
    independent: null,
  );
  await db.update(
    'attempt',
    {'submitted_at': '2026-10-05 19:00:00'},
    where: 'id = ?',
    whereArgs: [other.id],
  );

  final conversationC = await conversation(stem: '同一道题的另一个讨论');
  final sameQuestionAttempt = await attempts.ensureOpenAttempt(conversationC);
  await attempts.submit(
    sameQuestionAttempt.id,
    answer: '后来自己算出来了。',
    isCorrect: true,
    independent: true,
    delayed: true,
  );
  await db.update(
    'attempt',
    {'submitted_at': '2026-10-10 20:00:00'},
    where: 'id = ?',
    whereArgs: [sameQuestionAttempt.id],
  );

  // 与 A 同题的另一条记录：该题只能沿“同一道题”扩到 A。
  final conversationSameQuestion = await conversation(stem: '例 3-2 求条件概率');
  final sameQuestion = await attempts.ensureOpenAttempt(
    conversationSameQuestion,
  );
  await attempts.submit(
    sameQuestion.id,
    answer: '又做了一次。',
    isCorrect: true,
    independent: null,
  );
  await db.update(
    'attempt',
    {'submitted_at': '2026-10-08 20:00:00'},
    where: 'id = ?',
    whereArgs: [sameQuestion.id],
  );

  // 另一页的作答，用来验证“这份材料页”只取当前页。
  final pageOne = await conversation(stem: '条件概率定义', pageNo: 1);
  final pageOneAttempt = await attempts.ensureOpenAttempt(pageOne);
  await attempts.submit(
    pageOneAttempt.id,
    answer: 'P(A|B)=P(AB)/P(B)',
    isCorrect: true,
    independent: true,
  );
  await db.update(
    'attempt',
    {'submitted_at': '2026-10-02 10:00:00'},
    where: 'id = ?',
    whereArgs: [pageOneAttempt.id],
  );

  return _Corpus(
    goal: goal,
    material: material,
    conversationA: conversationA,
    conversationB: conversationB,
    conversationC: conversationC,
    conversationSameQuestion: conversationSameQuestion,
    attemptHelped: helped.id,
    attemptIndependent: independent.id,
    attemptOtherGoalConversation: other.id,
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('时间条件解析：完整日期、月日、今天与没有日期', () {
    final now = DateTime(2026, 10, 12, 20);
    final full = TimeCondition.parse('2026-10-01 那次的作答', now)!;
    expect(full.from, DateTime(2026, 10, 1));
    expect(full.to, DateTime(2026, 10, 2));
    final monthDay = TimeCondition.parse('10 月 1 日用了什么帮助', now)!;
    expect(monthDay.from, DateTime(2026, 10, 1));
    expect(TimeCondition.parse('昨天做对了吗', now)!.from, DateTime(2026, 10, 11));
    expect(TimeCondition.parse('今天复习了吗', now)!.from, DateTime(2026, 10, 12));
    expect(TimeCondition.parse('例 3-2 怎么做', now), isNull);
    expect(TimeCondition.hasTemporalCue('后来独立做出来了吗'), isTrue);
    expect(TimeCondition.hasTemporalCue('例 3-2 怎么做'), isFalse);
  });

  test('当前讨论够用时只取这条记录，不混入同目标的其他作答', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );

    final summary = await service.resolve(
      query: '上次用了什么帮助',
      scope: EvidenceScope.answer(
        goalId: corpus.goal,
        materialId: corpus.material,
        pageNo: 7,
        conversationId: corpus.conversationA,
      ),
      now: DateTime(2026, 10, 12, 20),
    );
    expect(summary.attempts, hasLength(2));
    expect(summary.threadLabel, '当前讨论');
    expect(
      summary.attempts.every(
        (entry) => entry.conversationId == corpus.conversationA,
      ),
      isTrue,
    );
    expect(
      summary.attempts.any(
        (entry) => entry.conversationId == corpus.conversationB,
      ),
      isFalse,
    );
  });

  test('当前作答排除在外，线索不够时沿同题与材料页逐层扩大', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );

    final restricted = await service.resolve(
      query: '那次用了什么帮助',
      scope: EvidenceScope.answer(
        conversationId: corpus.conversationA,
        goalId: corpus.goal,
      ),
      now: DateTime(2026, 10, 12, 20),
      excludeAttemptId: corpus.attemptHelped,
    );
    expect(
      restricted.attempts.any(
        (entry) => entry.attempt.id == corpus.attemptHelped,
      ),
      isFalse,
      reason: '当前这次作答已经在上下文里，不重复列入跨次结果',
    );

    // 同题的另一条记录只有一次作答，需要扩到同题的 A 才能看到后来的独立表现。
    final summary = await service.resolve(
      query: '例 3-2 后来独立做出来了吗',
      scope: EvidenceScope.answer(
        conversationId: corpus.conversationSameQuestion,
        goalId: corpus.goal,
      ),
      now: DateTime(2026, 10, 12, 20),
      stem: '例 3-2 求条件概率',
    );
    expect(summary.threadLabel, '当前讨论');
    expect(
      summary.attempts.any(
        (entry) => entry.conversationId == corpus.conversationA,
      ),
      isTrue,
      reason: '当前讨论只有一次作答时，沿同一道题继续找',
    );
    expect(summary.attempts.length, greaterThanOrEqualTo(2));
    final times = summary.attempts
        .map((entry) => entry.attempt.submittedAt)
        .whereType<DateTime>()
        .toList();
    for (var index = 1; index < times.length; index++) {
      expect(times[index].isBefore(times[index - 1]), isFalse);
    }
  });

  test('显式日期只取当天的作答，并说明时间范围', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );

    final summary = await service.resolve(
      query: '10 月 1 日那次例 3-2 用了什么帮助',
      scope: EvidenceScope.answer(
        conversationId: corpus.conversationA,
        goalId: corpus.goal,
      ),
      now: DateTime(2026, 10, 12, 20),
    );
    expect(summary.timeLabel, '10 月 1 日');
    expect(summary.attempts, hasLength(1));
    expect(summary.attempts.single.attempt.id, corpus.attemptHelped);
    expect(summary.pendingNotes, isEmpty);
  });

  test('按材料页找作答时不带出其他页的记录', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );

    final summary = await service.resolve(
      query: '上次复习到哪一步',
      scope: EvidenceScope.answer(
        materialId: corpus.material,
        pageNo: 1,
        goalId: corpus.goal,
      ),
      now: DateTime(2026, 10, 12, 20),
    );
    expect(summary.attempts, isNotEmpty);
    expect(
      summary.attempts.every((entry) => entry.pageNo == 1),
      isTrue,
      reason: '沿这份材料页找作答时只取第 1 页',
    );
  });

  test('没有时间条件与回看意图时不读取历史', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final corpus = await _seed(db);
    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );

    final summary = await service.resolve(
      query: '例 3-2 怎么做',
      scope: EvidenceScope.answer(
        conversationId: corpus.conversationA,
        goalId: corpus.goal,
      ),
      now: DateTime(2026, 10, 12, 20),
    );
    expect(summary.isEmpty, isTrue);
  });

  test('同一道题六次作答时取最近几次，上次与后来的独立表现都进入上下文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final goal = await tasks.createGoal(title: '概率论期末');
    final conversation = await conversations.create(sourceRef: '例 3-2');
    await conversations.setGoal(conversation, goal);
    await conversations.append(
      conversation,
      role: 'user',
      content: '例 3-2 求条件概率',
    );

    Future<int> addAttempt({
      required String submittedAt,
      required String answer,
      required bool? isCorrect,
      required bool? independent,
      bool delayed = false,
      bool withHint = false,
    }) async {
      final attempt = await attempts.ensureOpenAttempt(
        conversation,
        delayed: delayed,
      );
      await attempts.submit(
        attempt.id,
        answer: answer,
        isCorrect: isCorrect,
        independent: independent,
        delayed: delayed,
      );
      await db.update(
        'attempt',
        {
          'submitted_at': submittedAt,
          'created_at': submittedAt,
          'updated_at': submittedAt,
          'help_json': withHint
              ? jsonEncode([
                  {
                    'kind': 'hint',
                    'content': '先想 P(AB) 与 P(B) 的关系。',
                    'at': submittedAt,
                  },
                ])
              : null,
        },
        where: 'id = ?',
        whereArgs: [attempt.id],
      );
      return attempt.id;
    }

    final first = await addAttempt(
      submittedAt: '2026-10-01 09:00:00',
      answer: '第一次写错',
      isCorrect: false,
      independent: null,
    );
    await addAttempt(
      submittedAt: '2026-10-02 09:00:00',
      answer: '第二次写错',
      isCorrect: false,
      independent: null,
    );
    final helped = await addAttempt(
      submittedAt: '2026-10-03 09:00:00',
      answer: '看过提示才写对',
      isCorrect: true,
      independent: false,
      withHint: true,
    );
    await addAttempt(
      submittedAt: '2026-10-04 09:00:00',
      answer: '第四次写错',
      isCorrect: false,
      independent: null,
    );
    await addAttempt(
      submittedAt: '2026-10-05 09:00:00',
      answer: '第五次写错',
      isCorrect: false,
      independent: null,
    );
    final independent = await addAttempt(
      submittedAt: '2026-10-06 09:00:00',
      answer: 'P(A|B)=P(AB)/P(B)，答案 0.4。',
      isCorrect: true,
      independent: true,
      delayed: true,
    );

    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );
    final scope = EvidenceScope.answer(
      conversationId: conversation,
      goalId: goal,
    );

    final last = await service.resolve(
      query: '上次那道题我做到哪里了',
      scope: scope,
      now: DateTime(2026, 10, 12, 20),
    );
    final lastIds = [for (final entry in last.attempts) entry.attempt.id];
    expect(
      lastIds,
      contains(independent),
      reason: '超过五次作答时，“上次”必须是本次之前最近的一次数，不能退回最早几次',
    );
    expect(last.attempts.last.attempt.id, independent);
    expect(lastIds, isNot(contains(first)), reason: '取最近的若干次，最早的作答让位给后来的记录');

    final later = await service.resolve(
      query: '例 3-2 后来有没有独立做对',
      scope: scope,
      now: DateTime(2026, 10, 12, 20),
    );
    final laterIds = [for (final entry in later.attempts) entry.attempt.id];
    expect(laterIds, containsAll([helped, independent]));
    expect(later.narrative, contains('辅助完成（应用内帮助）'), reason: '当时一次要保留用了什么帮助');
    expect(later.narrative, contains('延迟后独立完成'), reason: '之后一次要保留独立表现');
    final times = later.attempts
        .map((entry) => entry.attempt.submittedAt)
        .whereType<DateTime>()
        .toList();
    for (var index = 1; index < times.length; index++) {
      expect(times[index].isBefore(times[index - 1]), isFalse);
    }
  });

  test('无归属求助不沿同题扩到另一条无归属讨论', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);

    Future<int> record() async {
      final id = await conversations.create(sourceRef: '例 3-2');
      await conversations.append(id, role: 'user', content: '例 3-2 求条件概率');
      return id;
    }

    Future<void> submit(int conversationId, String at) async {
      final attempt = await attempts.ensureOpenAttempt(conversationId);
      await attempts.submit(
        attempt.id,
        answer: '提交于 $at',
        isCorrect: true,
        independent: true,
      );
      await db.update(
        'attempt',
        {'submitted_at': at, 'created_at': at, 'updated_at': at},
        where: 'id = ?',
        whereArgs: [attempt.id],
      );
    }

    final current = await record();
    await submit(current, '2026-10-01 09:00:00');
    await submit(current, '2026-10-02 09:00:00');
    final other = await record();
    await submit(other, '2026-10-03 09:00:00');

    final service = CrossSessionService(
      repository: EvidenceRepository(db.rawDb),
    );
    final summary = await service.resolve(
      query: '上次用了什么帮助',
      scope: EvidenceScope.answer(conversationId: current),
      now: DateTime(2026, 10, 12, 20),
      stem: '例 3-2 求条件概率',
    );
    expect(summary.attempts, isNotEmpty);
    expect(
      summary.attempts.every((entry) => entry.conversationId == current),
      isTrue,
      reason: '无归属求助只沿当前讨论回看，同一道题的另一条无归属讨论不进入上下文',
    );
  });

  test('同题线索按目标范围限定，不串到另一门课', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final goalA = await tasks.createGoal(title: '概率论期末');
    final goalB = await tasks.createGoal(title: '线性代数作业');

    Future<int> record(int? goalId, String at) async {
      final id = await conversations.create(sourceRef: '例 3-2');
      if (goalId != null) await conversations.setGoal(id, goalId);
      await conversations.append(id, role: 'user', content: '例 3-2 求条件概率');
      final attempt = await attempts.ensureOpenAttempt(id);
      await attempts.submit(
        attempt.id,
        answer: '提交于 $at',
        isCorrect: true,
        independent: true,
      );
      await db.update(
        'attempt',
        {'submitted_at': at, 'created_at': at, 'updated_at': at},
        where: 'id = ?',
        whereArgs: [attempt.id],
      );
      return id;
    }

    final inGoal = await record(goalA, '2026-10-01 09:00:00');
    final otherGoal = await record(goalB, '2026-10-02 09:00:00');
    final unassigned = await record(null, '2026-10-03 09:00:00');

    final summary =
        await CrossSessionService(repository: EvidenceRepository(db.rawDb))
            .resolve(
              query: '例 3-2 后来独立做对了吗',
              scope: EvidenceScope.answer(goalId: goalA),
              now: DateTime(2026, 10, 12, 20),
              stem: '例 3-2 求条件概率',
            );
    final seen = {for (final entry in summary.attempts) entry.conversationId};
    expect(seen, contains(inGoal));
    expect(seen, contains(unassigned));
    expect(seen, isNot(contains(otherGoal)), reason: '同一道题的另一门课作答不进入本次目标范围');
  });
}
