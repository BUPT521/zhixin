import '../ai/ai_chat_service.dart';
import '../ai/buddy_prompt.dart';
import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../data/db/write_transactions.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/study_plan_repository.dart';
import '../data/repository/study_repository.dart';
import '../domain/models/material.dart';
import '../domain/models/study.dart';
import '../domain/models/study_plan.dart';
import '../domain/rules/study_plan_steps.dart';
import 'context_service.dart';

/// 一份学习计划与它的步骤。
class StudyPlanView {
  const StudyPlanView({required this.plan, required this.steps});

  final StudyPlan plan;
  final List<PlanItem> steps;

  PlanItem? get currentStep => currentStudyStep(steps);
}

/// 一次学习步骤继续时打开的内容类型。
enum StudyStepResumeKind { material, discussion, question }

/// 学习步骤这次的继续位置；由步骤绑定的讨论与是否开始作答推出，不由入口决定。
class StudyStepResume {
  const StudyStepResume({
    required this.kind,
    required this.title,
    this.conversationId,
    this.materialId,
    this.pageFrom,
    this.pageTo,
  });

  final StudyStepResumeKind kind;
  final String title;
  final int? conversationId;
  final int? materialId;
  final int? pageFrom;
  final int? pageTo;
}

/// 一次学习顺序的来源，确认界面据此说明结果是模型给出还是按页补齐。
enum StudyPlanSource {
  model,
  local,
  mixed;

  String label({required bool isDocx}) {
    final unit = isDocx ? '片段' : '页';
    return switch (this) {
      model => '模型生成',
      local => '按$unit顺序',
      mixed => '部分模型、部分按$unit顺序',
    };
  }
}

/// 一次学习顺序提议：步骤、来源与本次覆盖的材料页数。
class StudyPlanProposal {
  const StudyPlanProposal({
    required this.steps,
    required this.source,
    required this.pageCount,
    this.notice,
  });

  final List<StudyStepDraft> steps;
  final StudyPlanSource source;
  final int pageCount;
  final String? notice;
}

/// 系统学习：按材料范围提出顺序、保存进度，并提供临时讨论入口。
///
/// 模型可用时按批提出学习步骤，并核对每个所选页码恰好被覆盖一次；某批
/// 没有通过核对或调用失败时只为这一批按页补齐，不丢弃已经生成的批次。
/// 模型不可用时整份按页顺序给出，并把来源带回确认界面。临时求助只创建
/// 一条讨论，不改变计划位置。
class StudyPlanService {
  StudyPlanService({
    required this.plans,
    required this.materials,
    required this.ai,
    required this.context,
    required this.conversations,
    required this.study,
    required this.transactions,
  });

  final StudyPlanRepository plans;
  final MaterialRepository materials;
  final BuddyAi ai;
  final ContextService context;
  final ConversationRepository conversations;
  final StudyRepository study;
  final WriteTransactions transactions;

  Future<List<StudyPlan>> list({bool openOnly = false}) =>
      plans.list(openOnly: openOnly);

  Future<StudyPlanView> view(int planId) async {
    final plan = await plans.byId(planId);
    if (plan == null) throw StateError('未找到这份学习计划');
    final steps = await plans.steps(planId);
    return StudyPlanView(plan: plan, steps: steps);
  }

  /// 每个步骤最近一次结束的场次，给步骤卡显示完成时间、结果与困难。
  Future<Map<int, StudySession>> latestSessionsForSteps(
    Iterable<int> stepIds,
  ) => study.latestEndedByPlanItem(stepIds);

  /// 这一步上次停在哪里：有作答时回到原题，有讨论时回到讨论，否则打开材料。
  ///
  /// 计划页、预约与事项详情共用这一条判断，入口只负责打开对应内容，不再
  /// 各自决定是新建讨论还是直接进入材料。步骤绑定的讨论被删除时退回材料。
  Future<StudyStepResume> resumePoint(int planId, int stepId) async {
    final view = await this.view(planId);
    final step = view.steps.where((item) => item.id == stepId).firstOrNull;
    if (step == null) throw StateError('未找到这一步');
    final conversationId = step.conversationId;
    if (conversationId != null) {
      final record = await conversations.byId(conversationId);
      if (record != null) {
        return StudyStepResume(
          kind: record.hasAttempts
              ? StudyStepResumeKind.question
              : StudyStepResumeKind.discussion,
          title: step.title,
          conversationId: conversationId,
          materialId: view.plan.materialId,
          pageFrom: step.pageFrom,
          pageTo: step.pageTo,
        );
      }
    }
    return StudyStepResume(
      kind: StudyStepResumeKind.material,
      title: step.title,
      materialId: view.plan.materialId,
      pageFrom: step.pageFrom,
      pageTo: step.pageTo,
    );
  }

  /// 从这一步的材料页开始讨论，并把新讨论记为这一步的继续位置。
  ///
  /// 讨论与步骤绑定放在同一个事务里，之后从计划页或预约进入都会回到这条
  /// 讨论，而不是重新打开材料页。
  Future<int> startDiscussionAtStep({
    required int planId,
    required int stepId,
    required int pageNo,
  }) async {
    final view = await this.view(planId);
    final step = view.steps.where((item) => item.id == stepId).firstOrNull;
    if (step == null) throw StateError('未找到这一步');
    final materialId = view.plan.materialId;
    if (materialId == null) throw StateError('这一步还没有关联材料');
    return transactions.run((txn) async {
      final conversationId = await conversations.create(
        title:
            '${step.title} · ${materialPosition(pageNo, isDocx: view.plan.materialIsDocx)}',
        goalId: view.plan.goalId,
        materialId: materialId,
        pageNo: pageNo,
        transaction: txn,
      );
      await plans.bindDiscussionToStep(
        planId: planId,
        stepId: step.id,
        conversationId: conversationId,
        transaction: txn,
      );
      return conversationId;
    }, label: '开始步骤讨论');
  }

  /// 按材料范围提出学习顺序；模型失败时只为失败批次退回按页顺序。
  ///
  /// 每批模型结果都要经过 [studyStepsProblem] 的页码覆盖核对；某批失败时保留
  /// 前面已经通过核对的步骤，只给这一批按页补齐，并在 [StudyPlanProposal]
  /// 里标明整份结果的来源。
  Future<StudyPlanProposal> propose({
    required int materialId,
    required int pageFrom,
    required int pageTo,
    int? goalId,
    String? conversationFocus,
  }) async {
    final isDocx = (await materials.byId(materialId))?.isDocx ?? false;
    final inRange = await materials.pagesBetween(
      materialId,
      pageFrom: pageFrom,
      pageTo: pageTo,
    );
    if (inRange.isEmpty) {
      throw StateError('所选范围暂无材料页面。请先添加页码和原文。');
    }

    LlmConfig? config;
    try {
      config = await ai.config();
    } on LlmConfigReadFailure {
      config = null;
    }
    if (config == null || !config.isConfigured) {
      return StudyPlanProposal(
        steps: _localSteps(inRange, focus: conversationFocus, isDocx: isDocx),
        source: StudyPlanSource.local,
        pageCount: inRange.length,
        notice: '模型未配置，暂按${isDocx ? '片段' : '页码'}顺序生成。',
      );
    }

    const pagesPerRequest = 6;
    final proposed = <StudyStepDraft>[];
    var modelBatches = 0;
    var localBatches = 0;
    for (var offset = 0; offset < inRange.length; offset += pagesPerRequest) {
      final batch = inRange.skip(offset).take(pagesPerRequest).toList();
      final batchFrom = batch.first.pageNo;
      final batchTo = batch.last.pageNo;
      try {
        final batchSteps = await _proposeBatch(
          materialId: materialId,
          goalId: goalId,
          conversationFocus: conversationFocus,
          config: config,
          batch: batch,
          previous: proposed,
        );
        final problem = studyStepsProblem(
          steps: batchSteps,
          pageNos: batch.map((page) => page.pageNo),
          pageFrom: batchFrom,
          pageTo: batchTo,
        );
        if (problem != null) throw FormatException(problem);
        proposed.addAll(batchSteps);
        modelBatches++;
      } on LlmException {
        proposed.addAll(
          _localSteps(
            batch,
            isDocx: isDocx,
            focus: proposed.isEmpty ? conversationFocus : null,
          ),
        );
        localBatches++;
      } on FormatException {
        proposed.addAll(
          _localSteps(
            batch,
            isDocx: isDocx,
            focus: proposed.isEmpty ? conversationFocus : null,
          ),
        );
        localBatches++;
      } on LlmConfigReadFailure {
        proposed.addAll(
          _localSteps(
            batch,
            isDocx: isDocx,
            focus: proposed.isEmpty ? conversationFocus : null,
          ),
        );
        localBatches++;
      }
    }

    final source = localBatches == 0
        ? StudyPlanSource.model
        : modelBatches == 0
        ? StudyPlanSource.local
        : StudyPlanSource.mixed;
    final order = isDocx ? '片段' : '页';
    final position = isDocx ? '片段编号' : '页码';
    return StudyPlanProposal(
      steps: proposed,
      source: source,
      pageCount: inRange.length,
      notice: switch (source) {
        StudyPlanSource.model => null,
        StudyPlanSource.local => '模型顺序未能完整生成，已按$order顺序生成。',
        StudyPlanSource.mixed => '部分批次没有通过$position核对或调用失败，已按$order顺序补上。',
      },
    );
  }

  Future<List<StudyStepDraft>> _proposeBatch({
    required int materialId,
    required int? goalId,
    required String? conversationFocus,
    required LlmConfig config,
    required List<MaterialPage> batch,
    required List<StudyStepDraft> previous,
  }) async {
    final batchFrom = batch.first.pageNo;
    final batchTo = batch.last.pageNo;
    final facts = await context.load(
      mode: BuddyMode.plan,
      goalId: goalId,
      materialId: materialId,
      pageNo: batchFrom,
      pageFrom: batchFrom,
      pageTo: batchTo,
      conversationFocus: conversationFocus,
    );
    final isDocx = facts.material?.isDocx ?? false;
    final range = isDocx
        ? materialPosition(batchFrom, to: batchTo, isDocx: true)
        : '第 $batchFrom–$batchTo 页';
    final unit = isDocx ? '片段编号' : '页码';
    final prompt = StringBuffer()
      ..write('按本次提供的材料提出学习步骤，覆盖$range，')
      ..write('每一步写清$unit范围与结束条件；材料里没有展开但完成目标必需的内容，')
      ..write('标为前置内容。不得引用本次范围之外的$unit。');
    final earlier = _previousStepsSummary(previous, isDocx: isDocx);
    if (earlier.isNotEmpty) {
      prompt
        ..write('\n前面批次已经给出的步骤：\n$earlier\n')
        ..write('不要重复这些步骤；本批次的内容如果依赖前面的步骤，在说明里写明依赖第几步。');
    }
    final reply = await ai.ask(
      context: facts,
      history: const [],
      text: prompt.toString(),
      configSnapshot: LlmConfigSnapshot(config),
    );
    if (reply.studySteps.isEmpty) {
      throw const FormatException('模型没有返回学习步骤');
    }
    return reply.studySteps;
  }

  /// 前面批次已经给出的步骤摘要；只列最近若干步，控制提示长度。
  String _previousStepsSummary(
    List<StudyStepDraft> steps, {
    required bool isDocx,
  }) {
    if (steps.isEmpty) return '';
    final start = steps.length > 12 ? steps.length - 12 : 0;
    final lines = <String>[if (start > 0) '前面共 ${steps.length} 步，以下只列最近 12 步。'];
    for (var index = start; index < steps.length; index++) {
      final step = steps[index];
      final range = materialPosition(
        step.pageFrom,
        to: step.pageTo,
        isDocx: isDocx,
      );
      lines.add(
        '${index + 1}. ${step.title}${range.isEmpty ? '' : '（$range）'}',
      );
    }
    return lines.join('\n');
  }

  /// 保存用户确认的顺序；`conversationId` 用于从已有讨论开始系统学习。
  Future<StudyPlanView> createPlan({
    required int materialId,
    required int pageFrom,
    required int pageTo,
    required List<StudyStepDraft> steps,
    int? goalId,
    int? conversationId,
    String? title,
  }) async {
    if (steps.isEmpty) throw ArgumentError('请先生成学习步骤');
    if (pageFrom <= 0 || pageTo < pageFrom) {
      throw ArgumentError('学习计划页码范围无效');
    }
    final material = await materials.byId(materialId);
    if (material == null) throw StateError('未找到这份材料');
    final inRange = await materials.pagesBetween(
      materialId,
      pageFrom: pageFrom,
      pageTo: pageTo,
    );
    if (inRange.isEmpty) {
      throw StateError('所选范围内没有材料页面');
    }
    final problem = studyStepsProblem(
      steps: steps,
      pageNos: inRange.map((page) => page.pageNo),
      pageFrom: pageFrom,
      pageTo: pageTo,
    );
    if (problem != null) throw ArgumentError(problem);
    final planTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : '${material.title} ${material.position(pageFrom, to: pageTo)}';
    final first = steps.first;
    final planId = await plans.createWithDrafts(
      title: planTitle,
      drafts: steps,
      materialId: materialId,
      goalId: goalId ?? material.goalId,
      conversationId: conversationId,
      pageFrom: pageFrom,
      pageTo: pageTo,
      currentPage: first.pageFrom ?? pageFrom,
    );
    return view(planId);
  }

  Future<void> setStepStatus(
    int planId,
    int stepId,
    PlanItemStatus status,
  ) async {
    await plans.setStepStatus(stepId, status, expectedPlanId: planId);
  }

  Future<void> pause(int planId) =>
      plans.setStatus(planId, StudyPlanStatus.paused);

  Future<void> resume(int planId) =>
      plans.setStatus(planId, StudyPlanStatus.active);

  /// 从当前步骤打开一次讨论；正式学习会把这一步标为进行中。
  Future<int> startAtCurrent(
    int planId, {
    bool temporary = false,
    bool newDiscussion = false,
  }) async {
    final view = await this.view(planId);
    final plan = view.plan;
    final step = view.currentStep;
    final page = step?.pageFrom ?? plan.currentPage ?? plan.pageFrom;
    final material = plan.materialId == null
        ? null
        : await materials.byId(plan.materialId!);
    final pageLabel = materialPosition(page, isDocx: plan.materialIsDocx);
    if (!temporary && step != null && step.status == PlanItemStatus.todo) {
      await plans.setStepStatus(
        step.id,
        PlanItemStatus.doing,
        expectedPlanId: plan.id,
      );
    }
    if (!temporary &&
        !newDiscussion &&
        step?.conversationId != null &&
        step!.conversationId != plan.conversationId) {
      final previous = await conversations.byId(step.conversationId!);
      if (previous != null) return previous.id;
    }
    final title = temporary
        ? '临时问题 · ${material?.title ?? '材料'}$pageLabel'
        : '${step?.title ?? '系统学习'} · $pageLabel';
    if (!temporary && step != null) {
      return transactions.run((txn) async {
        final conversationId = await conversations.create(
          title: title,
          goalId: plan.goalId,
          materialId: plan.materialId,
          pageNo: page,
          transaction: txn,
        );
        await plans.bindDiscussionToStep(
          planId: plan.id,
          stepId: step.id,
          conversationId: conversationId,
          transaction: txn,
        );
        return conversationId;
      }, label: '开始系统学习');
    }
    return conversations.create(
      title: title,
      goalId: plan.goalId,
      materialId: plan.materialId,
      pageNo: page,
    );
  }

  Future<int> startTemporary(int planId) =>
      startAtCurrent(planId, temporary: true);

  List<StudyStepDraft> _localSteps(
    List<MaterialPage> pages, {
    String? focus,
    required bool isDocx,
  }) {
    const maxSteps = 6;
    final chunk = (pages.length / maxSteps).ceil();
    final steps = <StudyStepDraft>[];
    var index = 0;
    var seq = 0;
    while (index < pages.length) {
      final group = pages.skip(index).take(chunk).toList(growable: false);
      index += group.length;
      seq++;
      final from = group.first.pageNo;
      final to = group.last.pageNo;
      final label = group
          .map((page) => page.label)
          .whereType<String>()
          .where((value) => value.trim().isNotEmpty)
          .firstOrNull;
      steps.add(
        StudyStepDraft(
          title:
              label ?? '阅读${materialPosition(from, to: to, isDocx: isDocx)}材料',
          pageFrom: from,
          pageTo: to,
          note: seq == 1 && focus != null
              ? '继续“$focus”讨论'
              : '按${isDocx ? '片段' : '页码'}顺序阅读，并用一句话记录要点。',
        ),
      );
    }
    return steps;
  }
}
