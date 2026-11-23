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
import 'package:zhixin/domain/models/result.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/domain/rules/uuid_v7.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

/// 提交身份只用 `uid`（ADR-0053 决定第 3 条）。
///
/// 界面在动作开始时生成一次 UUIDv7 并一路传下来，同一次动作重试沿用同一个值；
/// 写入层按 `revision_commit.uid` 的唯一索引先查，已存在就返回原提交，不再有
/// 按参数派生的重试编号与两分钟窗口。两次真正独立、参数相同的动作是两个不同的
/// 身份，各自形成提交。

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
  test('同一个 uid 的模型判断只写一次', () async {
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
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
    );

    final questionId = await service.capture(stem: '检查这道题');
    final attempt = await service.openAttempt(questionId);
    final uid = newUuidV7();
    final first = await service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
      uid: uid,
    );
    final head = await rig.engine.headId(rig.raw);

    final again = await service.assessWithModel(
      questionId: questionId,
      attemptId: attempt.id,
      uid: uid,
    );
    expect(again.id, first.id);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await assessments.forAttempt(attempt.id), hasLength(1));
  });

  test('同一个 uid 的草稿与提交只写一次', () async {
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
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
    );

    final questionId = await service.capture(stem: '提交身份去重');
    final attempt = await service.openAttempt(questionId);

    final draftHead = await rig.engine.headId(rig.raw);
    final draftUid = newUuidV7();
    await service.saveDraft(
      attemptId: attempt.id,
      answer: '先写一步',
      uid: draftUid,
    );
    final savedHead = await rig.engine.headId(rig.raw);
    expect(savedHead, greaterThan(draftHead));
    // 写入失败后用户再点一次：同一个 uid 不再形成第二条提交。
    await service.saveDraft(
      attemptId: attempt.id,
      answer: '先写一步',
      uid: draftUid,
    );
    expect(await rig.engine.headId(rig.raw), savedHead);
    expect((await attempts.attemptById(attempt.id))!.userAnswer, '先写一步');

    final submitUid = newUuidV7();
    await service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: true,
      uid: submitUid,
    );
    final submittedHead = await rig.engine.headId(rig.raw);
    await service.submit(
      attemptId: attempt.id,
      answer: '写完了',
      isCorrect: true,
      independent: true,
      uid: submitUid,
    );
    expect(await rig.engine.headId(rig.raw), submittedHead);
    final stored = (await attempts.attemptById(attempt.id))!;
    expect(stored.submitted, isTrue);
    expect(stored.userAnswer, '写完了');
  });

  test('新建目标与事项各形成一条提交，同内容两次是两个身份', () async {
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
    // 界面每次动作各自生成身份：内容相同也照常写入第二条。
    final goalAgain = await service.addGoal(title: '概率论期末');
    expect(goalAgain.changed, isTrue);
    expect(goalAgain.commitId, isNot(goal.commitId));
    expect(await tasks.goals(), hasLength(2));

    final item = await service.addItem(title: '做一组练习', minutes: 20);
    expect(item.changed, isTrue);
    final other = await service.addItem(title: '再做一组', minutes: 20);
    expect(other.changed, isTrue);
    expect(other.commitId, isNot(item.commitId));
    expect(await tasks.items(), hasLength(2));
  });

  test('完成步骤与改回是各自的动作，状态迁移都写入', () async {
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
    // 状态没有变化时不形成提交。
    final again = await service.setStatus(itemId, PlanItemStatus.done);
    expect(again.changed, isFalse);
    expect(await rig.engine.headId(rig.raw), head);

    expect(
      (await service.setStatus(itemId, PlanItemStatus.todo)).changed,
      isTrue,
    );
    final redo = await service.setStatus(itemId, PlanItemStatus.done);
    expect(redo.changed, isTrue);
    expect((await tasks.byId(itemId))!.status, PlanItemStatus.done);
  });

  test('同一时段重复预约按冲突拒绝，换时间另起一条提交', () async {
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
    // 参数完全相同的第二次调用由界面另起一个 uid，不再按“同参数两分钟内算重试”
    // 合并；这一次撞上同一时段的已有预约，被冲突校验拒绝，不形成提交。
    await expectLater(
      service.scheduleItem(planItemId: itemId, start: start, end: end),
      throwsA(anything),
    );
    expect(await rig.engine.headId(rig.raw), head);
    expect(await schedule.nextBlocksForItems([itemId], start), hasLength(1));

    // 换一个时间就是另一个动作，各自形成一条提交。
    final later = await service.scheduleItem(
      planItemId: itemId,
      start: start.add(const Duration(hours: 2)),
      end: end.add(const Duration(hours: 2)),
    );
    expect(later.commitId, isNot(scheduled.commitId));
    expect(later.changed, isTrue);
  });

  test('同参数的暂停、恢复、再暂停各自生效', () async {
    var now = DateTime(2026, 11, 12, 9);
    final rig = await openTestRigWithUndoRules(clock: () => now);
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final service = _planService(rig, TimePolicy(clock: () => now));

    await service.addGoal(title: '来回切换');
    final goalId = (await tasks.goals()).single.id;

    expect((await service.pauseGoal(goalId)).changed, isTrue);
    expect((await tasks.goals()).single.status, LearningGoalStatus.paused);
    expect((await service.resumeGoal(goalId)).changed, isTrue);
    expect((await tasks.goals()).single.status, LearningGoalStatus.active);
    final headBefore = await rig.engine.headId(rig.raw);
    expect((await service.pauseGoal(goalId)).changed, isTrue);
    expect((await tasks.goals()).single.status, LearningGoalStatus.paused);
    expect(await rig.engine.headId(rig.raw), greaterThan(headBefore));
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
  transactions: WriteTransactions(rig.db, revisions: rig.engine),
);
