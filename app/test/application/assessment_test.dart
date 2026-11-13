import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/learning_service.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/data/repository/assessment_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/test_db.dart';

class _FakeAi implements BuddyAi {
  _FakeAi({this.reply, this.error});

  BuddyReply? reply;
  LlmException? error;
  BuddyContext? lastContext;
  Completer<void>? entered;
  Completer<void>? resume;

  @override
  Future<LlmConfig?> config() async => null;

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async {
    lastContext = context;
    entered?.complete();
    final waiting = resume;
    if (waiting != null) await waiting.future;
    final failure = error;
    if (failure != null) throw failure;
    return reply ?? const BuddyReply(text: '这是提示');
  }
}

class _Harness {
  _Harness({BuddyReply? reply, LlmException? error})
    : ai = _FakeAi(reply: reply, error: error);

  final _FakeAi ai;
  int epoch = 0;
  late Database db;
  late TestRig rig;
  late AttemptRepository attempts;
  late AssessmentRepository assessments;
  late ConversationRepository conversations;
  late StudyRepository study;
  late TaskRepository tasks;
  late MemoryRepository memories;
  late RevisionService revisions;
  late LearningService service;

  Future<void> open() async {
    rig = await openTestRig();
    db = rig.db;
    attempts = AttemptRepository(db);
    assessments = AssessmentRepository(db);
    conversations = ConversationRepository(db);
    study = StudyRepository(db);
    tasks = TaskRepository(db);
    memories = MemoryRepository(db);
    revisions = rig.revisions;
    final materials = MaterialRepository(db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 6, 20));
    service = LearningService(
      attempts: attempts,
      conversations: conversations,
      study: study,
      memories: memories,
      revisions: rig.revisions,
      schedule: ScheduleRepository(db),
      tasks: TaskRepository(db),
      assessments: assessments,
      ai: ai,
      context: ContextService(
        tasks: TaskRepository(db),
        attempts: attempts,
        schedule: ScheduleRepository(db),
        memories: memories,
        conversations: conversations,
        materials: materials,
        policy: () => policy,
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: attempts,
      ),
      policy: () => policy,
      transactions: WriteTransactions(db),
      filesDir: () => '.',
      dataEpoch: () => epoch,
    );
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('V6：用了帮助时自评记为辅助完成，核对依据单独保存', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义，再检查这一步'));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.help(questionId: questionId, mode: BuddyMode.hint);

    await h.service.submit(
      attemptId: attempt.id,
      answer: 'P(A|B)=P(AB)/P(B)',
      isCorrect: true,
      independent: false,
      delayed: false,
      checkable: '标准答案一致',
    );

    final list = await h.assessments.forAttempt(attempt.id);
    expect(list, hasLength(1));
    final stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.selfResult, '辅助完成（应用内帮助）');
    expect(stored.judgmentLabel, '自评做对');
    expect(stored.selfBasis, contains('应用内帮助：1 次'));
    expect(stored.selfBasis, contains('自评：正确'));
    final checkable = list.single;
    expect(checkable.kind, AssessmentKind.user);
    expect(checkable.result, '标准答案一致');

    await expectLater(
      h.service.submit(
        attemptId: attempt.id,
        answer: '第二个答案不能覆盖已提交内容',
        isCorrect: false,
        independent: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      (await h.attempts.attemptById(attempt.id))!.userAnswer,
      'P(A|B)=P(AB)/P(B)',
    );
    expect(await h.assessments.forAttempt(attempt.id), hasLength(1));
  });

  test('草稿里的依据与核对结果一起保存，提交时沿用同一条判断', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '草稿检查');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.saveDraft(
      attemptId: attempt.id,
      answer: '写到第二步',
      isCorrect: true,
      independent: true,
      feedback: '卡在定义',
      checkable: '与标准答案一致',
    );

    var stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.submitted, isFalse);
    expect(stored.userAnswer, '写到第二步');
    expect(stored.isCorrect, isTrue);
    expect(stored.feedback, '卡在定义');
    var list = await h.assessments.forAttempt(attempt.id);
    expect(list, hasLength(1));
    expect(list.single.kind, AssessmentKind.user);
    expect(list.single.result, '与标准答案一致');

    await h.service.submit(
      attemptId: attempt.id,
      answer: '写到第二步',
      isCorrect: true,
      independent: true,
      feedback: '卡在定义',
      checkable: '与标准答案一致',
    );
    list = await h.assessments.forAttempt(attempt.id);
    expect(list, hasLength(1));
    expect(list.single.result, '与标准答案一致');
    stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.submitted, isTrue);
  });

  test('清空草稿里的核对结果会删掉对应判断', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '清空草稿');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.saveDraft(
      attemptId: attempt.id,
      answer: '写到一半',
      checkable: '与标准答案一致',
    );
    expect(await h.assessments.forAttempt(attempt.id), hasLength(1));

    await h.service.saveDraft(
      attemptId: attempt.id,
      answer: '写到一半',
      checkable: '',
    );
    expect(await h.assessments.forAttempt(attempt.id), isEmpty);
  });

  // 这一条要逐条写入两百多条消息，整个测试套件并行跑时会顶到默认的 30 秒
  // 上限；用例内容与断言不变，只放宽这一条的时限。
  test(
    '讨论超过两百条时仍把较早的助手回答导入帮助',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final h = _Harness(reply: const BuddyReply(text: '新的提示'));
      await h.open();
      addTearDown(h.db.close);

      final questionId = await h.service.capture(stem: '长讨论里的题目');
      await h.conversations.append(
        questionId,
        role: 'assistant',
        content: '较早的回答',
      );
      for (var index = 0; index < 200; index++) {
        await h.conversations.append(
          questionId,
          role: 'user',
          content: '追问 $index',
        );
      }

      final result = await h.service.help(
        questionId: questionId,
        mode: BuddyMode.hint,
      );

      // 讨论里的回答不复制进作答记录，只在本次上下文里作为帮助带入。
      expect(
        h.ai.lastContext!.attempt!.helps.any((help) => help.content == '较早的回答'),
        isTrue,
      );
      expect(
        result.attempt.helps.any((help) => help.content == '较早的回答'),
        isFalse,
      );
    },
  );

  test('作答的记忆建议先待确认，点记下才写入并可撤销', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看定义',
        memories: [
          MemoryDraft(kind: MemoryKind.difficulty, content: '放缩方向不确定'),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
    );

    // 帮助照常保存，记忆建议留在帮助里等用户确认，没有直接落库。
    expect(result.changes, isEmpty);
    expect(await h.memories.list(), isEmpty);
    final stored = (await h.attempts.attemptsFor(questionId)).single;
    expect(stored.helps.single.content, '先看定义');
    expect(stored.helps.single.memories.single.status, 'pending');

    final items = await h.service.memoryItemsFor(stored);
    expect(items, hasLength(1));
    expect(items.single.pending, isTrue);

    final accepted = await h.service.acceptMemory(
      attemptId: stored.id,
      helpIndex: 0,
      itemId: items.single.itemId,
    );
    expect(accepted.applied, isTrue);
    final memories = await h.memories.list();
    expect(memories.single.content, '放缩方向不确定');
    final applied = (await h.attempts.attemptsFor(questionId)).single;
    expect(applied.helps.single.memories.single.status, 'accepted');

    // 撤销这次写入：记忆删除，帮助里的建议回到待确认。
    final undone = await h.revisions.undoCommit(accepted.change!.commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await h.memories.list(), isEmpty);
    final reverted = (await h.attempts.attemptsFor(questionId)).single;
    expect(reverted.helps.single.memories.single.status, 'pending');
  });

  test('记忆写入失败时帮助照常保存，建议留作待确认', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看定义',
        memories: [
          MemoryDraft(kind: MemoryKind.difficulty, content: '放缩方向不确定'),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    await h.db.execute('''
      CREATE TRIGGER fail_memory_insert BEFORE INSERT ON memory
      BEGIN
        SELECT RAISE(ABORT, '记忆写入失败');
      END;
    ''');

    final questionId = await h.service.capture(stem: '求条件概率');
    await h.service.help(questionId: questionId, mode: BuddyMode.hint);
    final stored = (await h.attempts.attemptsFor(questionId)).single;
    final items = await h.service.memoryItemsFor(stored);

    await expectLater(
      h.service.acceptMemory(
        attemptId: stored.id,
        helpIndex: 0,
        itemId: items.single.itemId,
      ),
      throwsA(isA<Object>()),
    );
    expect(await h.memories.list(), isEmpty);
    final kept = (await h.attempts.attemptsFor(questionId)).single;
    expect(kept.helps.single.content, '先看定义');
    expect(kept.helps.single.memories.single.status, 'pending');
  });

  test('停止生成时保留已经显示的部分提示', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义', stopped: true));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
      onText: (_) {},
    );

    expect(result.stopped, isTrue);
    expect(result.text, '先看定义');
    expect(result.fromModel, isTrue);
    expect(result.notice, contains('保留已经生成的部分'));
    expect(result.attempt.helps, hasLength(1));
    expect(result.attempt.helps.single.content, '先看定义');
  });

  test('生成中断时保留已经显示的部分提示', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看定义',
        interrupted: true,
        interruptedReason: '网络不可用',
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
      onText: (_) {},
    );

    expect(result.interrupted, isTrue);
    expect(result.text, '先看定义');
    expect(result.fromModel, isTrue);
    expect(result.notice, contains('生成中断'));
    expect(result.notice, contains('已保留已经生成的部分'));
    expect(result.attempt.helps, hasLength(1));
    expect(result.attempt.helps.single.content, '先看定义');
  });

  test('达到长度上限时保留正文并提示被截断', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义', truncated: true));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
      onText: (_) {},
    );

    expect(result.text, '先看定义');
    expect(result.fromModel, isTrue);
    expect(result.notice, contains('回答被截断'));
    expect(result.attempt.helps.single.content, '先看定义');
  });

  test('还没有正文就停止时不记一条空的帮助', () async {
    final h = _Harness(reply: const BuddyReply(text: '', stopped: true));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
    );

    expect(result.stopped, isTrue);
    expect(result.text, isEmpty);
    expect(result.fromModel, isFalse);
    expect(result.notice, '已停止生成。');
    expect(result.attempt.helps, isEmpty);
  });

  test('作答求助与讨论共用一条调用失败的说明', () async {
    final h = _Harness(error: const LlmException(LlmFailure.offline, '断网'));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final result = await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
    );

    expect(result.fromModel, isFalse);
    expect(result.notice, contains('模型调用失败（网络不可用）'));
    expect(result.notice, contains('已切换为本地规则回答'));
    expect(result.attempt.helps.single.content, isNotEmpty);
  });

  test('应用内帮助自动记为用了提示，不需要在表单里再勾一次', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看定义'));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '自动带出帮助');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.help(questionId: questionId, mode: BuddyMode.hint);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: true,
    );

    final stored = await h.attempts.attemptById(attempt.id);
    expect(stored!.hintUsed, isTrue);
    expect(stored.selfResult, '辅助完成（应用内帮助）');
  });

  test('V6：独立且延迟重做时记为延迟后独立完成', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '重做一次');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '完整过程',
      isCorrect: true,
      independent: true,
      delayed: true,
    );
    final stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.selfResult, '延迟后独立完成');
    expect(stored.selfBasis, contains('间隔后重做'));
  });

  test('没有选择独立性时记为未说明，不从应用内帮助反推', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '没有说明独立性');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: null,
    );

    final stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.independent, isNull);
    expect(stored.selfResult, '独立性未说明');
    expect(stored.selfBasis, contains('独立性未说明'));
  });

  test('用户记录使用应用外帮助时记为应用外辅助完成', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '用了教材');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '照教材步骤写出',
      isCorrect: true,
      independent: false,
    );

    final stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.selfResult, '辅助完成（应用外帮助）');
    expect(stored.selfBasis, contains('应用外帮助'));
  });

  test('V6：模型判断带出应用内帮助', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '看过提示后完成，判断为辅助完成',
        assessment: AssessmentDraft(
          result: '辅助完成',
          basis: '应用内给过一次提示，用户自评独立完成但使用了帮助',
        ),
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '独立判断');
    await h.service.openAttempt(questionId);
    final attempt = (await h.attempts.attemptsFor(questionId)).first;
    await h.service.help(questionId: questionId, mode: BuddyMode.explain);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '写完',
      isCorrect: true,
      independent: true,
    );

    final assessment = await h.service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
    );
    expect(assessment.kind, AssessmentKind.model);
    expect(assessment.basis, contains('提示'));
    expect(h.ai.lastContext!.attempt!.helps, isNotEmpty);
    expect(h.ai.lastContext!.attempt!.helps.first.content, contains('看过提示'));
  });

  test('从讨论开始作答只挂一条记录，不再复制题干与回答', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final conversationId = await h.conversations.create(
      title: '第 8 题',
      entryKind: 'text_photo',
    );
    await h.conversations.append(
      conversationId,
      role: 'user',
      content: '第 8 题怎么做',
      imagePaths: ['m-1.jpg'],
    );
    await h.conversations.append(
      conversationId,
      role: 'assistant',
      content: '先写出条件概率的定义。',
    );

    final questionId = await h.service.startAnswering(
      conversationId: conversationId,
    );
    expect(questionId, conversationId);
    final view = await h.service.view(questionId);
    expect(view.question.stem, '第 8 题怎么做');
    expect(view.question.imagePaths, ['m-1.jpg']);
    expect(view.question.conversationId, conversationId);
    expect(view.attempts, hasLength(1));
    expect(view.attempts.single.helps, isEmpty);

    // 再次进入复用同一条记录与同一条未提交尝试。
    expect(
      await h.service.startAnswering(conversationId: conversationId),
      questionId,
    );
    expect((await h.service.view(questionId)).attempts, hasLength(1));

    // 求助时讨论里的回答作为帮助进入上下文，但不写进作答记录。
    await h.service.help(questionId: questionId, mode: BuddyMode.hint);
    expect(
      h.ai.lastContext!.attempt!.helps.any((help) => help.kind == 'discuss'),
      isTrue,
    );
    final stored = await h.attempts.attemptsFor(questionId);
    expect(stored.single.helps, hasLength(1));
    expect(stored.single.helps.single.kind, 'hint');
  });

  test('只有图片的讨论也能开始作答，材料页码写成出处', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final materials = MaterialRepository(h.db);
    final materialId = await materials.create(title: '概率论讲义', kind: 'book');
    await materials.addPage(
      materialId: materialId,
      pageNo: 3,
      content: '条件概率的定义。',
    );
    final conversationId = await h.conversations.create(
      title: '图片求助',
      entryKind: 'photo',
      materialId: materialId,
      pageNo: 3,
    );
    await h.conversations.append(
      conversationId,
      role: 'user',
      imagePaths: ['m-2.jpg'],
    );
    await h.conversations.append(
      conversationId,
      role: 'assistant',
      content: '先把已知条件列出来。',
    );

    final questionId = await h.service.startAnswering(
      conversationId: conversationId,
    );
    final view = await h.service.view(questionId);
    expect(view.question.stem, isEmpty);
    expect(view.question.displayStem, '图片题目');
    expect(view.question.imagePaths, ['m-2.jpg']);
    expect(view.question.sourceRef, '《概率论讲义》第 3 页');
  });

  test('离开学习页时场次自动结束，结果与困难从本次尝试推出', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求极限');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '用洛必达法则',
      isCorrect: false,
      independent: true,
      feedback: '放缩方向还不确定',
    );

    await h.service.closeForQuestion(questionId);
    final session = (await h.study.recent()).single;
    expect(session.outcome, 'not_done');
    expect(session.summary, '放缩方向还不确定');
    expect(session.endedAt, isNotNull);

    final memories = await h.memories.list();
    expect(memories, isEmpty);

    // 场次已经结束，再次离开不会重复写场次或记忆。
    await h.service.closeForQuestion(questionId);
    expect(await h.study.recent(), hasLength(1));
    expect(await h.memories.list(), isEmpty);
  });

  test('再次作答同一道题时只带入这道题以前留下的困难', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求极限');
    final first = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: first.id,
      answer: '用洛必达法则',
      isCorrect: false,
      independent: true,
      feedback: '放缩方向还不确定',
    );
    await h.service.closeForQuestion(questionId);

    await h.service.help(questionId: questionId, mode: BuddyMode.hint);
    final context = h.ai.lastContext!;
    expect(context.priorFeedback.single.feedback, '放缩方向还不确定');
    expect(context.memories, isEmpty);
  });

  test('先问方法后补完整题目时，把后来那条当原题', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final conversationId = await h.conversations.create(title: '先问方法');
    await h.conversations.append(
      conversationId,
      role: 'user',
      content: '这种题一般怎么做',
    );
    await h.conversations.append(
      conversationId,
      role: 'user',
      content: '题目：求 P(A|B)，已知 P(AB)=0.2，P(B)=0.5',
      imagePaths: ['m-9.jpg'],
    );

    final id = await h.service.startAnswering(conversationId: conversationId);
    final view = await h.service.view(id);
    expect(view.question.stem, contains('P(AB)=0.2'));
    expect(view.question.imagePaths, ['m-9.jpg']);
  });

  test('从步骤讨论开始作答时把场次记回这一步', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final plans = StudyPlanRepository(h.db);
    final planId = await plans.createWithDrafts(
      title: '条件概率计划',
      drafts: const [StudyStepDraft(title: '第一步', pageFrom: 1, pageTo: 1)],
    );
    final step = (await plans.steps(planId)).single;
    final conversationId = await h.conversations.create(title: '第一步讨论');
    await h.conversations.append(
      conversationId,
      role: 'user',
      content: '第一步的题目',
    );
    await WriteTransactions(h.db).run((txn) async {
      await plans.bindDiscussionToStep(
        planId: planId,
        stepId: step.id,
        conversationId: conversationId,
        transaction: txn,
      );
    }, label: '绑定步骤讨论');

    final attempt = await h.service.openAttempt(conversationId);
    expect((await h.study.byId(attempt.sessionId!))!.planItemId, step.id);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '第一步的答案',
      isCorrect: true,
      independent: true,
    );
    await h.service.closeForQuestion(conversationId);

    final latest = await h.study.latestEndedByPlanItem([step.id]);
    expect(latest[step.id], isNotNull);
    expect(latest[step.id]!.outcome, 'done');
  });

  test('两条无归属记录各自建立场次，结束一题不影响另一题', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final first = await h.service.capture(stem: '第一道无归属题');
    final second = await h.service.capture(stem: '第二道无归属题');
    final firstAttempt = await h.service.openAttempt(first);
    final secondAttempt = await h.service.openAttempt(second);
    expect(firstAttempt.sessionId, isNotNull);
    expect(secondAttempt.sessionId, isNotNull);
    expect(firstAttempt.sessionId, isNot(secondAttempt.sessionId));
    expect(
      (await h.study.byId(firstAttempt.sessionId!))!.conversationId,
      first,
    );
    expect(
      (await h.study.byId(secondAttempt.sessionId!))!.conversationId,
      second,
    );

    await h.service.closeForQuestion(first);

    expect((await h.study.byId(firstAttempt.sessionId!))!.endedAt, isNotNull);
    expect((await h.study.byId(secondAttempt.sessionId!))!.endedAt, isNull);

    // 第二题提交后仍然能在自己的场次里结算，不因为第一题退出而漏记。
    await h.service.submit(
      attemptId: secondAttempt.id,
      answer: '第二题的答案',
      isCorrect: true,
      independent: true,
    );
    await h.service.closeForQuestion(second);
    expect((await h.study.byId(secondAttempt.sessionId!))!.outcome, 'done');
  });

  test('清空记录目标后新生次不再继承旧场次目标', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final questionId = await h.service.capture(stem: '清空归属的题');
    await h.conversations.setGoal(questionId, goalId);
    final first = await h.service.openAttempt(questionId);
    expect((await h.study.byId(first.sessionId!))!.goalId, goalId);

    await h.conversations.setGoal(questionId, null);
    final second = await h.service.openAttempt(questionId);
    expect(second.sessionId, isNot(first.sessionId));
    expect((await h.study.byId(second.sessionId!))!.goalId, isNull);
    expect((await h.study.byId(first.sessionId!))!.endedAt, isNotNull);
  });

  test('旧页面保存草稿不能改写已提交作答的核对依据', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '已提交的题');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '提交时的答案',
      isCorrect: true,
      independent: true,
      checkable: '提交时的依据',
    );

    await expectLater(
      h.service.saveDraft(
        attemptId: attempt.id,
        answer: '旧页面里的答案',
        isCorrect: false,
        independent: false,
        checkable: '旧页面覆盖的依据',
      ),
      throwsA(isA<StateError>()),
    );

    expect((await h.attempts.attemptById(attempt.id))!.userAnswer, '提交时的答案');
    final assessments = await h.assessments.forAttempt(attempt.id);
    expect(assessments.single.result, '提交时的依据');
  });

  test('独立重做状态写入尝试，并关联被复查的作答', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '重做状态');
    final first = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: first.id,
      answer: '上一次答案',
      isCorrect: false,
      independent: true,
    );

    final redo = await h.service.openAttempt(questionId, independentRedo: true);
    expect(redo.redoOfAttemptId, first.id);

    // 重新读回也仍是重做，不依赖页面上的临时变量。
    final view = await h.service.view(questionId);
    expect(view.openAttempt!.redoOfAttemptId, first.id);
    await h.service.closeForQuestion(questionId);
    final reopened = await h.service.openAttempt(
      questionId,
      independentRedo: true,
    );
    expect(reopened.redoOfAttemptId, first.id);
  });

  test('解法单独保存，不覆盖答案与困难', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '单独保存解法');
    final attempt = await h.service.openAttempt(questionId);
    await h.service.saveDraft(
      attemptId: attempt.id,
      answer: '答案写到第二步',
      solution: '设事件 A、B，按乘法公式展开',
      feedback: '卡在条件概率定义',
      checkable: '与标准答案一致',
    );
    var stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.userAnswer, '答案写到第二步');
    expect(stored.solution, '设事件 A、B，按乘法公式展开');
    expect(stored.feedback, '卡在条件概率定义');

    await h.service.submit(
      attemptId: attempt.id,
      answer: '答案写到第二步',
      solution: '设事件 A、B，按乘法公式展开',
      isCorrect: true,
      independent: true,
      feedback: '卡在条件概率定义',
      checkable: '与标准答案一致',
    );
    stored = (await h.attempts.attemptById(attempt.id))!;
    expect(stored.solution, '设事件 A、B，按乘法公式展开');
  });

  test('同一困难隔了二十次学习后再出现，仍然写成带范围的记忆', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    for (var index = 0; index < 21; index++) {
      final session = await h.study.start(goalId: goalId);
      await h.study.end(
        session.id,
        summary: index == 0 ? '放缩方向还不确定' : '第 $index 次的其他困难',
      );
    }
    final itemId = await h.tasks.createItem(title: '重做第 8 题', goalId: goalId);
    final questionId = await h.service.capture(stem: '求极限', planItemId: itemId);
    final attempt = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: attempt.id,
      answer: '用洛必达法则',
      isCorrect: false,
      independent: true,
      feedback: ' 放缩方向还不确定 ',
    );
    await h.service.closeForQuestion(questionId);

    final memories = await h.memories.list();
    expect(memories, hasLength(1));
    expect(memories.single.content, '放缩方向还不确定');
    expect(memories.single.scope, memoryGoalScope(goalId));
  });

  test('超过两百字的困难不截成记忆，完整内容留在作答记录', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final itemId = await h.tasks.createItem(title: '重做第 8 题', goalId: goalId);
    final questionId = await h.service.capture(stem: '求极限', planItemId: itemId);
    final long = List.filled(201, '卡').join();

    Future<void> answer() async {
      final attempt = await h.service.openAttempt(questionId);
      await h.service.submit(
        attemptId: attempt.id,
        answer: '用洛必达法则',
        isCorrect: false,
        independent: true,
        feedback: long,
      );
      await h.service.closeForQuestion(questionId);
    }

    await answer();
    await answer();

    expect(await h.memories.list(), isEmpty);
    final attempts = await h.attempts.attemptsFor(questionId);
    expect(attempts.first.feedback, long);
  });

  test('从学习事项开始时，场次写入所属目标', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final itemId = await h.tasks.createItem(title: '重做第 8 题', goalId: goalId);
    final questionId = await h.service.capture(stem: '求极限', planItemId: itemId);
    await h.service.closeForQuestion(questionId);

    final session = (await h.study.recent()).single;
    expect(session.goalId, goalId);
  });

  test('同一目标下同一困难反复出现时，才写成带范围的记忆', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);

    final goalId = await h.tasks.createGoal(title: '概率论期末');
    final itemId = await h.tasks.createItem(title: '重做第 8 题', goalId: goalId);
    final questionId = await h.service.capture(stem: '求极限', planItemId: itemId);

    Future<void> answer(String feedback) async {
      final attempt = await h.service.openAttempt(questionId);
      await h.service.submit(
        attemptId: attempt.id,
        answer: '用洛必达法则',
        isCorrect: false,
        independent: true,
        feedback: feedback,
      );
      await h.service.closeForQuestion(questionId);
    }

    await answer('放缩方向还不确定');
    expect(await h.memories.list(), isEmpty);

    await answer('  放缩方向还不确定 ');
    final memories = await h.memories.list();
    expect(memories, hasLength(1));
    expect(memories.single.kind, MemoryKind.difficulty);
    expect(memories.single.scope, memoryGoalScope(goalId));
    expect(memories.single.content, '放缩方向还不确定');
    expect(memories.single.sourceKind, 'session');

    await answer('放缩方向还不确定');
    expect(await h.memories.list(), hasLength(1));
  });

  test('恢复之后迟到的模型判断不再写入', () async {
    final h = _Harness(
      reply: const BuddyReply(
        text: '先看依据',
        assessment: AssessmentDraft(result: '还需要补充依据', basis: '只看到步骤'),
      ),
    );
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '求条件概率');
    final attempt = await h.service.openAttempt(questionId);
    h.ai.entered = Completer<void>();
    h.ai.resume = Completer<void>();

    final pending = h.service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
    );
    await h.ai.entered!.future;
    // 等待模型期间整库恢复或版本恢复推进代次。
    h.epoch++;
    h.ai.resume!.complete();

    await expectLater(pending, throwsA(isA<StateError>()));
    expect(await h.assessments.forAttempt(attempt.id), isEmpty);
  });

  test('独立重做不带入上次困难与讨论回答', () async {
    final h = _Harness(reply: const BuddyReply(text: '先看条件'));
    await h.open();
    addTearDown(h.db.close);

    final questionId = await h.service.capture(stem: '独立重做这道题');
    final first = await h.service.openAttempt(questionId);
    await h.service.submit(
      attemptId: first.id,
      answer: '上次的答案',
      isCorrect: false,
      independent: true,
      feedback: '上次卡在放缩',
    );
    await h.conversations.append(
      questionId,
      role: 'assistant',
      content: '上次讨论里给过的回答',
    );

    await h.service.help(
      questionId: questionId,
      mode: BuddyMode.hint,
      independentRedo: true,
    );
    // 重做时的上下文不带上次困难，也不把讨论里的旧回答复制成帮助。
    expect(h.ai.lastContext!.priorFeedback, isEmpty);
    expect(
      h.ai.lastContext!.attempt!.helps.any(
        (help) => help.content == '上次讨论里给过的回答',
      ),
      isFalse,
    );

    await h.service.help(questionId: questionId, mode: BuddyMode.hint);
    expect(h.ai.lastContext!.priorFeedback, isNotEmpty);
    expect(
      h.ai.lastContext!.attempt!.helps.any(
        (help) => help.content == '上次讨论里给过的回答',
      ),
      isTrue,
    );
  });
}
