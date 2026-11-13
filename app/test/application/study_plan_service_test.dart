import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/docx_import.dart';
import 'package:zhixin/application/material_service.dart';
import 'package:zhixin/application/study_plan_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/domain/models/study.dart';

import '../support/docx_fixture.dart';
import '../support/service_runtime.dart';
import '../support/test_db.dart';

class _FakeAi implements BuddyAi {
  _FakeAi({
    this.reply,
    this.configValue,
    List<BuddyReply>? replies,
    this.failAtCall,
  }) : replies = replies ?? const [];

  BuddyReply? reply;
  LlmConfig? configValue;
  final List<BuddyReply> replies;
  final int? failAtCall;
  int calls = 0;
  BuddyContext? lastContext;
  String lastText = '';

  @override
  Future<LlmConfig?> config() async => configValue;

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
    lastText = text;
    calls++;
    if (failAtCall != null && calls == failAtCall) {
      throw const LlmException(LlmFailure.timeout, '测试超时');
    }
    if (calls <= replies.length) return replies[calls - 1];
    return reply ?? const BuddyReply(text: '好');
  }
}

class _Harness {
  _Harness({
    BuddyReply? reply,
    LlmConfig? config,
    List<BuddyReply>? replies,
    int? failAtCall,
  }) : ai = _FakeAi(
         reply: reply,
         configValue: config,
         replies: replies,
         failAtCall: failAtCall,
       );

  final _FakeAi ai;
  late Database db;
  late ConversationRepository conversations;
  late MaterialRepository materials;
  late StudyPlanRepository plans;
  late AttemptRepository attempts;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late StudyRepository study;
  late StudyPlanService service;

  Future<void> open() async {
    db = await openTestDb();
    conversations = ConversationRepository(db);
    materials = MaterialRepository(db);
    plans = StudyPlanRepository(db);
    tasks = TaskRepository(db);
    attempts = AttemptRepository(db);
    schedule = ScheduleRepository(db);
    study = StudyRepository(db);
    final memories = MemoryRepository(db);
    final policy = TimePolicy(clock: () => DateTime(2026, 11, 6, 20));
    service = StudyPlanService(
      plans: plans,
      materials: materials,
      ai: ai,
      context: ContextService(
        tasks: tasks,
        attempts: attempts,
        schedule: schedule,
        memories: memories,
        conversations: conversations,
        materials: materials,
        runtime: testRuntime(policy: () => policy),
      ),
      conversations: conversations,
      study: study,
      transactions: WriteTransactions(db),
    );
  }

  Future<int> materialWithPages(List<int> pageNos) async {
    final id = await materials.create(title: '概率论讲义', kind: 'book');
    for (final pageNo in pageNos) {
      await materials.addPage(
        materialId: id,
        pageNo: pageNo,
        label: '第 $pageNo 节',
        content: '第 $pageNo 页的内容：条件概率与独立性。',
      );
    }
    return id;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('Word 片段生成学习步骤，开始讨论时保留材料位置', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final document = await DocxImport.read(
      '概率讲义.docx',
      Stream.value(docxFixture()),
    );
    final materialId = await MaterialService(
      materials: h.materials,
      transactions: WriteTransactions(h.db),
      runtime: testRuntime(),
    ).importDocx(document: document, title: '概率讲义', expectedEpoch: 0);
    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
    );
    expect(proposal.steps.map((step) => step.title), ['条件概率', '独立事件']);
    final view = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: proposal.steps,
    );
    expect(view.plan.progressLabel, contains('当前第 1 个片段'));
    final step = view.steps.first;
    expect((await h.tasks.byId(step.id))!.pageLabel, '第 1 个片段');
    final conversation = await h.service.startDiscussionAtStep(
      planId: view.plan.id,
      stepId: step.id,
      pageNo: 1,
    );
    expect(
      (await h.conversations.byId(conversation))!.materialLabel,
      '《概率讲义》第 1 个片段',
    );
  });

  test('V4：模型不可用时按页生成顺序，保存后可查看进度', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
    );
    expect(proposal.steps, hasLength(3));
    expect(proposal.steps.first.pageFrom, 1);
    expect(proposal.source, StudyPlanSource.local);
    expect(proposal.pageCount, 3);

    final view = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
      steps: proposal.steps,
    );
    expect(view.plan.title, contains('概率论讲义'));
    expect(view.plan.currentPage, 1);
    expect(view.plan.status, StudyPlanStatus.active);
    expect(view.steps, hasLength(3));
    expect(view.steps.first.seq, 1);
    expect(view.plan.stepsDone, 0);
    expect(view.plan.stepsTotal, 3);
  });

  test('计划及步骤原子创建，读取计划不修改更新时间', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);

    await expectLater(
      h.service.createPlan(
        materialId: materialId,
        pageFrom: 1,
        pageTo: 2,
        steps: const [
          StudyStepDraft(title: '有效步骤', pageFrom: 1, pageTo: 1),
          StudyStepDraft(title: '页码无效', pageFrom: 0, pageTo: 0),
        ],
      ),
      throwsA(anything),
    );
    expect(await h.db.query('study_plan'), isEmpty);
    expect(
      await h.db.query('plan_item', where: 'study_plan_id IS NOT NULL'),
      isEmpty,
    );

    final view = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: const [StudyStepDraft(title: '阅读材料', pageFrom: 1, pageTo: 2)],
    );
    final before = (await h.db.query(
      'study_plan',
      where: 'id = ?',
      whereArgs: [view.plan.id],
    )).single['updated_at'];
    await h.service.list();
    await h.service.view(view.plan.id);
    final after = (await h.db.query(
      'study_plan',
      where: 'id = ?',
      whereArgs: [view.plan.id],
    )).single['updated_at'];
    expect(after, before);
  });

  test('V4：模型给出顺序时会写入前置内容并带上材料范围', () async {
    final h = _Harness(
      config: const LlmConfig(apiKey: 'test'),
      reply: const BuddyReply(
        text: '按这个顺序',
        studySteps: [
          StudyStepDraft(
            title: '先补独立性的定义',
            pageFrom: 1,
            pageTo: 1,
            isPrerequisite: true,
            note: '材料中没有展开',
          ),
          StudyStepDraft(title: '条件概率与乘法公式', pageFrom: 2, pageTo: 3),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
    );
    expect(proposal.steps, hasLength(2));
    expect(proposal.source, StudyPlanSource.model);
    expect(h.ai.lastContext!.outlinePages, hasLength(3));
    final prompt = buildBuddySystemPrompt(h.ai.lastContext!);
    expect(prompt, contains('本次系统学习的材料范围'));
    expect(prompt, contains('前置内容'));
    expect(prompt, contains('学习步骤按页码范围排'));

    final view = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
      steps: proposal.steps,
    );
    expect(view.steps.first.note, contains('此前未接触的必要内容'));
    expect(view.steps.first.pageLabel, '第 1 页');
    expect(view.steps.last.pageLabel, '第 2–3 页');
  });

  test('V4：模型漏页或重复覆盖时只为这一批按页补齐', () async {
    final h = _Harness(
      config: const LlmConfig(apiKey: 'test'),
      reply: const BuddyReply(
        text: '只给出第一页',
        studySteps: [StudyStepDraft(title: '只覆盖第 1 页', pageFrom: 1, pageTo: 1)],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
    );
    expect(proposal.source, StudyPlanSource.local);
    expect(proposal.steps, hasLength(3));
    expect(proposal.steps.map((step) => step.pageFrom), [1, 2, 3]);
    expect(proposal.notice, isNotNull);
  });

  test('V4：模型重复覆盖页码时这一批按页顺序补齐', () async {
    final h = _Harness(
      config: const LlmConfig(apiKey: 'test'),
      reply: const BuddyReply(
        text: '两段重叠',
        studySteps: [
          StudyStepDraft(title: '第 1–2 页', pageFrom: 1, pageTo: 2),
          StudyStepDraft(title: '第 2–3 页', pageFrom: 2, pageTo: 3),
        ],
      ),
    );
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 3,
    );
    expect(proposal.source, StudyPlanSource.local);
    expect(proposal.steps.map((step) => step.pageFrom), [1, 2, 3]);
  });

  test('V4：后一批调用失败时保留前一批模型步骤', () async {
    final h = _Harness(
      config: const LlmConfig(apiKey: 'test'),
      replies: const [
        BuddyReply(
          text: '第一批',
          studySteps: [
            StudyStepDraft(title: '模型覆盖第 1–6 页', pageFrom: 1, pageTo: 6),
          ],
        ),
      ],
      failAtCall: 2,
    );
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3, 4, 5, 6, 7]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 7,
    );
    expect(proposal.source, StudyPlanSource.mixed);
    expect(proposal.steps.first.title, '模型覆盖第 1–6 页');
    expect(proposal.steps.where((step) => step.pageFrom == 7), hasLength(1));
    expect(proposal.notice, contains('补上'));
  });

  test('V4：后一批生成时带上前面批次已经给出的步骤', () async {
    final h = _Harness(
      config: const LlmConfig(apiKey: 'test'),
      replies: const [
        BuddyReply(
          text: '第一批',
          studySteps: [
            StudyStepDraft(title: '模型覆盖第 1–6 页', pageFrom: 1, pageTo: 6),
          ],
        ),
        BuddyReply(
          text: '第二批',
          studySteps: [
            StudyStepDraft(title: '模型覆盖第 7 页', pageFrom: 7, pageTo: 7),
          ],
        ),
      ],
    );
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2, 3, 4, 5, 6, 7]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 7,
    );
    expect(proposal.source, StudyPlanSource.model);
    expect(h.ai.lastText, contains('前面批次已经给出的步骤'));
    expect(h.ai.lastText, contains('模型覆盖第 1–6 页'));
  });

  test('V4：保存计划时拒绝没有覆盖所选页码的顺序', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);

    await expectLater(
      h.service.createPlan(
        materialId: materialId,
        pageFrom: 1,
        pageTo: 2,
        steps: const [StudyStepDraft(title: '只读第 1 页', pageFrom: 1, pageTo: 1)],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await h.db.query('study_plan'), isEmpty);
  });

  test('V4：继续位置由讨论与是否开始作答决定', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);
    final created = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: const [StudyStepDraft(title: '阅读第 1–2 页', pageFrom: 1, pageTo: 2)],
    );
    final planId = created.plan.id;
    final step = created.steps.single;

    var resume = await h.service.resumePoint(planId, step.id);
    expect(resume.kind, StudyStepResumeKind.material);
    expect(resume.materialId, materialId);
    expect(resume.pageFrom, 1);

    final conversationId = await h.service.startAtCurrent(planId);
    resume = await h.service.resumePoint(planId, step.id);
    expect(resume.kind, StudyStepResumeKind.discussion);
    expect(resume.conversationId, conversationId);

    await h.attempts.ensureOpenAttempt(conversationId);
    resume = await h.service.resumePoint(planId, step.id);
    expect(resume.kind, StudyStepResumeKind.question);
    expect(resume.conversationId, conversationId);
  });

  test('V4：从材料页开始的讨论会绑回学习步骤', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);
    final created = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: const [StudyStepDraft(title: '阅读第 1–2 页', pageFrom: 1, pageTo: 2)],
    );
    final planId = created.plan.id;
    final step = created.steps.single;

    final conversationId = await h.service.startDiscussionAtStep(
      planId: planId,
      stepId: step.id,
      pageNo: 1,
    );
    final view = await h.service.view(planId);
    expect(view.steps.single.conversationId, conversationId);
    final resume = await h.service.resumePoint(planId, step.id);
    expect(resume.kind, StudyStepResumeKind.discussion);
    final record = await h.conversations.byId(conversationId);
    expect(record!.pageNo, 1);
    expect(record.title, contains('阅读第 1–2 页'));
  });

  test('V4：完成一步后继续位置前移，临时求助不改变计划位置', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
    );
    final created = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: proposal.steps,
    );
    final planId = created.plan.id;
    final firstStep = created.steps.first;

    // 正式学习把这一步标为进行中，并按页码打开讨论。
    final studyId = await h.service.startAtCurrent(planId);
    final study = await h.conversations.byId(studyId);
    expect(study!.materialId, materialId);
    expect(study.pageNo, 1);
    var view = await h.service.view(planId);
    expect(view.currentStep!.status, PlanItemStatus.doing);
    expect(view.currentStep!.conversationId, studyId);
    expect(await h.service.startAtCurrent(planId), studyId);
    expect(view.plan.currentPage, 1);

    final newStudyId = await h.service.startAtCurrent(
      planId,
      newDiscussion: true,
    );
    expect(newStudyId, isNot(studyId));
    expect(await h.service.startAtCurrent(planId), newStudyId);

    // 临时问题使用当前页，但不改变计划位置。
    final temporaryId = await h.service.startTemporary(planId);
    final temporary = await h.conversations.byId(temporaryId);
    expect(temporary!.pageNo, 1);
    expect(temporaryId, isNot(newStudyId));
    view = await h.service.view(planId);
    expect(view.currentStep!.conversationId, newStudyId);
    expect(view.plan.currentPage, 1);
    expect(view.currentStep!.id, firstStep.id);

    await h.service.setStepStatus(planId, firstStep.id, PlanItemStatus.done);
    view = await h.service.view(planId);
    expect(view.plan.currentPage, 2);
    expect(view.plan.stepsDone, 1);

    await h.service.setStepStatus(
      planId,
      view.steps.last.id,
      PlanItemStatus.done,
    );
    view = await h.service.view(planId);
    expect(view.plan.status, StudyPlanStatus.done);
    expect(view.plan.stepsDone, 2);
  });

  test('V4：从已有讨论开始系统学习时保留来源', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);
    final conversationId = await h.conversations.create(
      title: '先讨论条件概率',
      materialId: materialId,
      pageNo: 1,
    );
    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
    );

    final view = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: proposal.steps,
      conversationId: conversationId,
    );
    expect(view.plan.conversationId, conversationId);
    expect(view.plan.materialId, materialId);
  });

  test('V4：学习步骤就是学习事项，可直接预约并共用完成状态', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.db.close);
    final materialId = await h.materialWithPages([1, 2]);

    final proposal = await h.service.propose(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
    );
    final created = await h.service.createPlan(
      materialId: materialId,
      pageFrom: 1,
      pageTo: 2,
      steps: proposal.steps,
    );
    final planId = created.plan.id;
    final step = created.steps.first;
    expect(step.studyPlanId, planId);
    expect(step.isStudyStep, isTrue);

    // 同一条记录既出现在事项列表里，也能直接挂时间块。
    final items = await h.tasks.items();
    expect(items.map((item) => item.id), contains(step.id));
    final now = DateTime(2026, 11, 6, 20);
    await h.schedule.addBlock(
      planItemId: step.id,
      start: now,
      end: now.add(const Duration(minutes: 20)),
    );
    final blocks = await h.schedule.blocksBetween(
      now,
      now.add(const Duration(days: 1)),
    );
    expect(blocks.map((entry) => entry.block.planItemId), contains(step.id));

    // 在事项侧标记完成，计划页读到同一条状态并前移继续位置。
    await h.plans.setItemStatus(step.id, PlanItemStatus.done);
    final view = await h.service.view(planId);
    expect(view.steps.first.status, PlanItemStatus.done);
    expect(view.plan.currentPage, 2);
  });
}
