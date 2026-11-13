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
import 'package:zhixin/data/repository/assessment_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _SilentAi implements BuddyAi {
  _SilentAi({this.reply = const BuddyReply(text: '不需要模型')});

  final BuddyReply reply;

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
    return reply;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('同一请求编号的模型判断只写一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final attempts = AttemptRepository(rig.db);
    final conversations = ConversationRepository(rig.db);
    final study = StudyRepository(rig.db);
    final memories = MemoryRepository(rig.db);
    final assessments = AssessmentRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final tasks = TaskRepository(rig.db);
    final materials = MaterialRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 11, 20));
    final service = LearningService(
      attempts: attempts,
      conversations: conversations,
      study: study,
      memories: memories,
      revisions: rig.revisions,
      schedule: schedule,
      tasks: tasks,
      assessments: assessments,
      ai: _SilentAi(
        reply: const BuddyReply(
          text: '检查结果',
          assessment: AssessmentDraft(result: '步骤完整', basis: '对照材料'),
        ),
      ),
      context: ContextService(
        tasks: tasks,
        attempts: attempts,
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: materials,
        runtime: testRuntime(policy: () => policy),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: attempts,
      ),
      runtime: testRuntime(policy: () => policy, filesDir: () => rig.filesDir),
      transactions: WriteTransactions(rig.db),
    );

    final questionId = await service.capture(stem: '检查这道题');
    final attempt = await service.openAttempt(questionId);
    final first = await service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
      requestId: 'assess-1',
    );
    final head = await rig.engine.headId(rig.raw);

    final again = await service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
      requestId: 'assess-1',
    );
    expect(again.id, first.id);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await assessments.forAttempt(attempt.id), hasLength(1));
  });

  test('同一请求编号的草稿与提交只写一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final attempts = AttemptRepository(rig.db);
    final conversations = ConversationRepository(rig.db);
    final study = StudyRepository(rig.db);
    final memories = MemoryRepository(rig.db);
    final assessments = AssessmentRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final tasks = TaskRepository(rig.db);
    final materials = MaterialRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 11, 20));
    final service = LearningService(
      attempts: attempts,
      conversations: conversations,
      study: study,
      memories: memories,
      revisions: rig.revisions,
      schedule: schedule,
      tasks: tasks,
      assessments: assessments,
      ai: _SilentAi(),
      context: ContextService(
        tasks: tasks,
        attempts: attempts,
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: materials,
        runtime: testRuntime(policy: () => policy),
      ),
      memoryScope: MemoryScopeService(
        conversations: conversations,
        attempts: attempts,
      ),
      runtime: testRuntime(policy: () => policy, filesDir: () => rig.filesDir),
      transactions: WriteTransactions(rig.db),
    );

    final questionId = await service.capture(stem: '请求编号去重');
    final attempt = await service.openAttempt(questionId);

    final draftHead = await rig.engine.headId(rig.raw);
    await service.saveDraft(
      attemptId: attempt.id,
      answer: '先写一步',
      requestId: 'draft-1',
    );
    final savedHead = await rig.engine.headId(rig.raw);
    expect(savedHead, greaterThan(draftHead));
    // 写入失败后用户再点一次：同一个请求编号不再形成第二条提交。
    await service.saveDraft(
      attemptId: attempt.id,
      answer: '先写一步',
      requestId: 'draft-1',
    );
    expect(await rig.engine.headId(rig.raw), savedHead);
    expect((await attempts.attemptById(attempt.id))!.userAnswer, '先写一步');

    await service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: true,
      requestId: 'submit-1',
    );
    final submittedHead = await rig.engine.headId(rig.raw);
    await service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: true,
      requestId: 'submit-1',
    );
    expect(await rig.engine.headId(rig.raw), submittedHead);
    final stored = (await attempts.attemptById(attempt.id))!;
    expect(stored.submitted, isTrue);
    expect(stored.userAnswer, '写完了');
  });
}
