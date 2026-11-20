import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/learning_service.dart';
import 'package:zhixin/application/memory_scope_service.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/assessment_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _SilentAi implements BuddyAi {
  _SilentAi({this.reply = const BuddyReply(text: '不需要模型')});

  final BuddyReply reply;

  @override
  Future<Result<LlmConfig?>> config() async => const Success(null);

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
  test('同一请求编号的模型判断只写一次', () async {
    final rig = await openTestRigWithUndoRules();
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
    final rig = await openTestRigWithUndoRules();
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

  test('新建目标与事项连点两次只形成一条提交，不同内容各自提交', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final service = _planService(
      rig,
      TimePolicy(clock: () => DateTime(2026, 11, 12, 9)),
    );
    final before = await rig.engine.headId(rig.raw);

    final goal = await service.addGoal(title: '概率论期末');
    expect(goal.changed, isTrue);
    final afterGoal = await rig.engine.headId(rig.raw);
    expect(afterGoal, greaterThan(before));
    final goalAgain = await service.addGoal(title: '概率论期末');
    expect(goalAgain.commitId, goal.commitId);
    expect(await rig.engine.headId(rig.raw), afterGoal);
    expect(await tasks.goals(), hasLength(1));

    final item = await service.addItem(title: '做一组练习', minutes: 20);
    expect(item.changed, isTrue);
    final afterItem = await rig.engine.headId(rig.raw);
    final itemAgain = await service.addItem(title: '做一组练习', minutes: 20);
    expect(itemAgain.commitId, item.commitId);
    expect(await rig.engine.headId(rig.raw), afterItem);
    expect(await tasks.items(), hasLength(1));

    // 内容不同是另一个动作，不会被当成重试。
    final other = await service.addItem(title: '再做一组', minutes: 20);
    expect(other.changed, isTrue);
    expect(other.commitId, isNot(item.commitId));
    expect(await tasks.items(), hasLength(2));
  });

  test('完成步骤连点两次只形成一条提交，改回后再完成仍能写入', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final service = _planService(
      rig,
      TimePolicy(clock: () => DateTime(2026, 11, 12, 9)),
    );
    final itemId = await tasks.createItem(title: '看完一节');

    final first = await service.setStatus(itemId, PlanItemStatus.done);
    expect(first.changed, isTrue);
    final head = await rig.engine.headId(rig.raw);
    final again = await service.setStatus(itemId, PlanItemStatus.done);
    expect(again.changed, isFalse);
    expect(await rig.engine.headId(rig.raw), head);

    // 改回待办再完成是新的状态迁移，不能被当成上一次动作的重试。
    expect(
      (await service.setStatus(itemId, PlanItemStatus.todo)).changed,
      isTrue,
    );
    final redo = await service.setStatus(itemId, PlanItemStatus.done);
    expect(redo.changed, isTrue);
    expect((await tasks.byId(itemId))!.status, PlanItemStatus.done);
  });

  test('保存预约时间连点两次只形成一条提交', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final schedule = ScheduleRepository(rig.db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 12, 9));
    final service = _planService(rig, policy);
    final itemId = await tasks.createItem(title: '看材料');
    final start = DateTime(2026, 11, 13, 19);
    final end = start.add(const Duration(minutes: 30));

    final scheduled = await service.scheduleItem(
      planItemId: itemId,
      start: start,
      end: end,
    );
    expect(scheduled.changed, isTrue);
    final head = await rig.engine.headId(rig.raw);
    final scheduledAgain = await service.scheduleItem(
      planItemId: itemId,
      start: start,
      end: end,
    );
    expect(scheduledAgain.commitId, scheduled.commitId);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await schedule.nextBlocksForItems([itemId], start), hasLength(1));

    // 换一个时间是新动作，不会因为同一事项而被当成重试。
    final later = await service.scheduleItem(
      planItemId: itemId,
      start: start.add(const Duration(hours: 2)),
      end: end.add(const Duration(hours: 2)),
    );
    expect(later.commitId, isNot(scheduled.commitId));
  });

  test('撤销之后同一个动作可以重新提交', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final service = _planService(
      rig,
      TimePolicy(clock: () => DateTime(2026, 11, 12, 9)),
    );
    final goal = await service.addGoal(title: '暂停后重开');
    expect(goal.changed, isTrue);
    final undone = await rig.revisions.undoCommit(goal.commitId!);
    expect(undone.applied, isTrue);
    expect(await tasks.goals(), isEmpty);

    final again = await service.addGoal(title: '暂停后重开');
    expect(again.changed, isTrue);
    expect(again.commitId, isNot(goal.commitId));
    expect(await tasks.goals(), hasLength(1));
  });
}

PlanService _planService(TestRig rig, TimePolicy policy) => PlanService(
  tasks: TaskRepository(rig.db),
  schedule: ScheduleRepository(rig.db),
  revisions: rig.revisions,
  runtime: testRuntime(policy: () => policy),
  studyPlans: StudyPlanRepository(rig.db),
  transactions: WriteTransactions(rig.db),
);
