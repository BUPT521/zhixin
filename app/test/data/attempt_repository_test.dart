import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/question.dart';

import '../support/test_db.dart';

Future<int> _record(
  ConversationRepository conversations,
  AttemptRepository attempts, {
  String stem = '',
  List<String> images = const [],
  String? sourceRef,
}) async {
  final id = await conversations.create(
    entryKind: stem.isEmpty
        ? 'photo'
        : (images.isEmpty ? 'text' : 'text_photo'),
    sourceRef: sourceRef,
  );
  await conversations.append(
    id,
    role: 'user',
    content: stem,
    imagePaths: images,
  );
  await attempts.ensureOpenAttempt(id);
  return id;
}

void main() {
  test('记录的状态由最近一次已提交尝试派生', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final id = await _record(
      conversations,
      attempts,
      stem: '证明数列极限',
      sourceRef: '教材第 82 页第 8 题',
    );

    var rows = await conversations.questionRows();
    expect(rows.single.question.id, id);
    expect(rows.single.question.stem, '证明数列极限');
    expect(rows.single.question.sourceRef, '教材第 82 页第 8 题');
    expect(rows.single.status, 'open');

    final first = await attempts.ensureOpenAttempt(id);
    await attempts.appendHelp(
      first.id,
      HelpEntry(kind: 'hint', content: '先看上下界', at: DateTime.now()),
    );
    var stored = await attempts.attemptsFor(id);
    expect(stored.single.helps, hasLength(1));
    expect(stored.single.submitted, isFalse);

    await attempts.submit(
      first.id,
      answer: '用夹逼准则',
      isCorrect: true,
      independent: false,
    );
    rows = await conversations.questionRows();
    expect(rows.single.status, 'correct');
    expect(rows.single.lastAttempt!.hintUsed, isTrue);
    expect(rows.single.lastAttempt!.independent, isFalse);

    final second = await attempts.ensureOpenAttempt(id);
    expect(second.id, isNot(first.id));
    await attempts.submit(
      second.id,
      answer: '写不出步骤',
      isCorrect: false,
      independent: true,
    );

    stored = await attempts.attemptsFor(id);
    expect(stored, hasLength(2));
    rows = await conversations.questionRows();
    expect(rows.single.status, 'wrong');
    expect(rows.single.lastAttempt!.isCorrect, isFalse);
  });

  test('最近一次学习场次的目标由一次联表取出', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final study = StudyRepository(db.rawDb);
    final tasks = TaskRepository(db.rawDb);

    final id = await conversations.create(entryKind: 'text');
    await conversations.append(id, role: 'user', content: '再做一次');
    final goalA = await tasks.createGoal(title: '目标 A');
    final goalB = await tasks.createGoal(title: '目标 B');
    final firstSession = await study.start(goalId: goalA);
    final first = await attempts.ensureOpenAttempt(
      id,
      sessionId: firstSession.id,
    );
    await attempts.submit(
      first.id,
      answer: '先写一步',
      isCorrect: false,
      independent: true,
    );
    final secondSession = await study.start(goalId: goalB);
    await attempts.ensureOpenAttempt(id, sessionId: secondSession.id);

    expect(await attempts.recentSessionGoal(id), goalB);

    final plain = await conversations.create(entryKind: 'text');
    expect(await attempts.recentSessionGoal(plain), isNull);
  });

  test('保存草稿一起留下自评与依据，清空时写回空值', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final id = await _record(conversations, attempts, stem: '写出推导');
    final attempt = await attempts.ensureOpenAttempt(id);

    await attempts.saveDraft(
      attempt.id,
      answer: '先写两步',
      isCorrect: false,
      independent: false,
      delayed: true,
      feedback: '卡在放缩',
    );

    var stored = (await attempts.attemptById(attempt.id))!;
    expect(stored.submitted, isFalse);
    expect(stored.userAnswer, '先写两步');
    expect(stored.isCorrect, isFalse);
    expect(stored.hintUsed, isTrue);
    expect(stored.independent, isFalse);
    expect(stored.delayed, isTrue);
    expect(stored.feedback, '卡在放缩');

    await attempts.saveDraft(attempt.id, answer: '');
    stored = (await attempts.attemptById(attempt.id))!;
    expect(stored.userAnswer, isNull);
    expect(stored.isCorrect, isNull);
    expect(stored.hintUsed, isFalse);
    expect(stored.independent, isNull);
    expect(stored.delayed, isFalse);
    expect(stored.feedback, isNull);
    expect(stored.submitted, isFalse);
  });

  test('题目视图就是首条用户消息与图片', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final questions = AttemptRepository(db.rawDb);
    final conversations = ConversationRepository(db.rawDb);

    final textId = await _record(conversations, questions, stem: '第 8 题怎么做');
    final photoId = await _record(
      conversations,
      questions,
      images: ['m-1.jpg'],
    );

    final text = (await conversations.question(textId))!;
    expect(text.stem, '第 8 题怎么做');
    expect(text.id, textId);

    final photo = (await conversations.question(photoId))!;
    expect(photo.stem, isEmpty);
    expect(photo.displayStem, '图片题目');
    expect(photo.imagePaths, ['m-1.jpg']);

    expect(await conversations.question(textId + 999), isNull);
  });

  test('同时开始作答只留下一条未提交草稿', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final id = await conversations.create(entryKind: 'text');
    await conversations.append(id, role: 'user', content: '同时开始作答');

    final started = await Future.wait([
      attempts.ensureOpenAttempt(id),
      attempts.ensureOpenAttempt(id),
      attempts.ensureOpenAttempt(id),
    ]);

    expect(started.map((attempt) => attempt.id).toSet(), hasLength(1));
    expect(await attempts.attemptsFor(id), hasLength(1));
  });

  test('没有作答过的讨论不出现在题目列表', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);

    final plain = await conversations.create(entryKind: 'text');
    await conversations.append(plain, role: 'user', content: '只是讨论');
    expect(await conversations.questionRows(), isEmpty);

    await attempts.ensureOpenAttempt(plain);
    final rows = await conversations.questionRows();
    expect(rows.single.question.id, plain);
  });
}
