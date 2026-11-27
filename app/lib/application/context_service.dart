import '../ai/buddy_prompt.dart';
import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/evidence.dart';
import '../domain/models/evidence_id.dart';
import '../domain/models/material.dart';
import '../domain/models/memory.dart';
import '../domain/models/question.dart';
import '../domain/models/study.dart';
import 'context_request.dart';
import 'evidence_service.dart';
import 'memory_recall.dart';
import 'memory_usage_service.dart';
import 'service_runtime.dart';

/// 一次回答最多带上的其他材料页与较早讨论条数；用户主动检索不受这个限制。
const int maxContextMaterialHits = 5;
const int maxContextRelatedRecords = 5;

/// 一次回答最多带入的原文命中条数。
const int maxContextEvidenceHits = 5;

/// 组装一次回答需要的上下文；只读当前用得到的记录。
///
/// 讨论的归属由调用方按用户明确选择的目标传入，没有选择时只带上同时有效的
/// 目标列表。材料按本次页码与当前问题检索，较早记录只取同一目标或同样无归属
/// 的讨论，避免其他课程的内容参加判断。记忆与材料页只在当前有效时进入上下文；
/// 纠正记录只用于界面追溯，不在这里读取，以免删除或过期之后的旧说法重新参与回答。
class ContextService {
  ContextService({
    required this.tasks,
    required this.attempts,
    required this.memories,
    required this.conversations,
    required this.materials,
    required this.runtime,
    this.evidence,
    this.personaSource,
    this.usage,
  });

  final TaskRepository tasks;
  final AttemptRepository attempts;
  final MemoryRepository memories;
  final ConversationRepository conversations;
  final MaterialRepository materials;
  final ServiceRuntime runtime;

  /// 回答前的原文与记录检索；为空时不取检索结果，只用当前材料与记忆。
  final EvidenceService? evidence;

  /// 记忆使用统计：进入相关层的记忆各记一次；为空时不记（ADR-0051 第 8 条）。
  final MemoryUsageService? usage;

  /// 当前启用的人格；由应用根从插件运行时取，为空表示这轮不带人格段落。
  ///
  /// 每次回答前重新读一次设置，恢复或清空之后人名与文本立即生效。
  final Future<BuddyPersona?> Function()? personaSource;

  Future<BuddyContext> load(ContextRequest request) async {
    final question = request.question;
    final attempt = request.attempt;
    final assessmentRecords = request.assessmentRecords;
    final mode = request.mode;
    final goalId = request.goalId;
    final materialId = request.materialId;
    final pageNo = request.pageNo;
    final pageFrom = request.pageFrom;
    final pageTo = request.pageTo;
    final conversationId = request.conversationId;
    final query = request.query;
    final broughtIdentities = request.broughtIdentities;
    final conversationFocus = request.conversationFocus;
    final includeEarlier = request.includeEarlier;
    final current = runtime.policy;
    final now = current.now;
    final goals = await tasks.activeGoals();
    final goal = goalId == null ? null : await tasks.goalById(goalId);
    // 待办与最近尝试只服务普通问答的本地兜底和安排学习；
    // 提示、讲解与检查用不到它们，因此不读。
    final withPlanContext = mode == BuddyMode.chat || mode == BuddyMode.plan;
    final openItems = withPlanContext
        ? await tasks.items(openOnly: true, onlyActiveGoals: true)
        : const <PlanItem>[];
    final recent = withPlanContext
        ? await conversations.recentSubmitted(
            limit: null,
            goalId: goalId,
            materialId: materialId,
            conversationId: conversationId,
            broughtAttemptIds: _broughtAttemptIds(broughtIdentities),
          )
        : const <AttemptWithQuestion>[];
    final scope = memoryScopeFor(goalId: goalId, materialId: materialId);
    // 记忆先按有效性与范围筛选，再分成常驻与相关两层：常驻（语义或程序、
    // 全局、长期有效）排在前面，其余按检索相关性。相关性由检索索引给出，
    // 索引不可用时按本机的二元组切分（ADR-0051 决定第 5 条）。
    final purpose = switch (mode) {
      BuddyMode.plan => MemoryRecallPurpose.plan,
      BuddyMode.check => MemoryRecallPurpose.check,
      BuddyMode.explain || BuddyMode.hint => MemoryRecallPurpose.explain,
      BuddyMode.chat => MemoryRecallPurpose.chat,
    };
    final recalled = await MemoryRecallService(
      memories,
      ranker: evidence?.index,
    ).recall(now: now, scope: scope, purpose: purpose, query: query);
    // 进入提示词的记忆同时记一次使用：只记在本机，不形成提交；常驻的不降权，
    // 所以只记相关层（ADR-0051 决定第 8 条）。
    usage?.noteRecalled(recalled.related, at: now);
    // 同一道题以前的困难只从这道题的作答记录里取；不经过长期记忆，
    // 其他课程的卡点因此不会进入本次上下文。
    final earlier = question == null || !includeEarlier
        ? const <Attempt>[]
        : await attempts.priorFeedback(
            question.id,
            excludeAttemptId: attempt?.id,
          );

    Material? material;
    MaterialPage? page;
    var outlinePages = const <MaterialPage>[];
    if (materialId != null) {
      material = await materials.byId(materialId);
      if (pageNo != null) page = await materials.page(materialId, pageNo);
      if (mode == BuddyMode.plan) {
        outlinePages = await materials.pagesBetween(
          materialId,
          pageFrom: pageFrom,
          pageTo: pageTo,
        );
      }
    }

    // 回答前只做一次检索：材料页、较早讨论、题目与已提交作答都在同一次
    // 结果里，不再分别读材料表和消息表。命中同时受当前目标、材料、这条讨论
    // 与本轮带入来源的限制。
    final trimmedQuery = query.trim();
    var materialHits = const <MaterialHit>[];
    var related = const <RelatedRecord>[];
    var evidenceHits = const <EvidenceHit>[];
    var crossSessionNotes = const <String>[];
    final evidenceService = evidence;
    final answerScope = EvidenceScope.answer(
      goalId: goalId,
      materialId: materialId,
      pageNo: pageNo,
      conversationId: conversationId,
      broughtIdentities: broughtIdentities,
    );
    final excludePage = materialId != null && pageNo != null
        ? (materialId, pageNo)
        : null;
    if (evidenceService != null && trimmedQuery.isNotEmpty) {
      final bundle = await evidenceService.forAnswer(
        query: trimmedQuery,
        scope: answerScope,
        perKindLimit: 3,
        limit: maxContextEvidenceHits * 2,
        excludePage: excludePage,
        now: now,
        stem: question?.stem,
        excludeAttemptId: attempt?.id,
      );
      crossSessionNotes = bundle.crossSessionNotes;
      // 一次检索带回各类候选，按“材料页、较早讨论、题目与作答”的顺序各取
      // 若干条，再合成五条左右的摘录；不按类别截断 SQL 候选，也不重复读表。
      final materialHitsFound = <MaterialHit>[];
      final relatedFound = <(String, RelatedRecord)>[];
      final relatedSeen = <String>{};
      final otherHits = <EvidenceHit>[];
      var chosen = 0;
      for (final hit in bundle.hits) {
        if (chosen >= maxContextEvidenceHits) break;
        switch (hit.kind) {
          case EvidenceKind.materialPage:
            final hitMaterialId = hit.location.materialId;
            final hitPageNo = hit.location.pageNo;
            if (hitMaterialId == null || hitPageNo == null) break;
            if (hitMaterialId == materialId && hitPageNo == pageNo) break;
            materialHitsFound.add(
              MaterialHit(
                materialId: hitMaterialId,
                materialTitle: hit.title,
                pageNo: hitPageNo,
                content: hit.text,
                snippetText: hit.snippet,
              ),
            );
            chosen++;
          case EvidenceKind.message:
            final hitConversationId = hit.location.conversationId;
            if (hitConversationId == null ||
                !relatedSeen.add(hitConversationId)) {
              break;
            }
            relatedFound.add((
              hitConversationId,
              RelatedRecord(
                conversationId: hitConversationId,
                title: hit.title,
                content: hit.text,
                createdAt: hit.createdAt,
                snippetText: hit.snippet,
              ),
            ));
            chosen++;
          case EvidenceKind.question || EvidenceKind.answer:
            otherHits.add(hit);
            chosen++;
          case EvidenceKind.unknown:
            // 认不出来源的命中不进入上下文。
            break;
        }
      }
      materialHits = materialHitsFound
          .take(maxContextMaterialHits)
          .toList(growable: false);
      related = relatedFound
          .take(maxContextRelatedRecords)
          .map((entry) => entry.$2)
          .toList(growable: false);
      // 材料页与较早讨论已经在各自的段落里列出，这里只留题目与作答，避免
      // 同一条摘录在一份提示词里出现两次。
      evidenceHits = otherHits.toList(growable: false);
    }

    // 重试接续上一轮读到的材料页：按位置重新读取当前保存的原文，材料或页码
    // 已经不在时跳过，更正过的内容按当前版本进入（docs/02 第 3.8 节）。
    // 这些页与本次检索命中的页放在一起，排在检索结果之前，读原文的工具因此
    // 可以直接接着读，不必先重新补搜。
    if (request.reusedPageKeys.isNotEmpty) {
      final reusedHits = <MaterialHit>[];
      final seenPageKeys = {for (final hit in materialHits) hit.pageKey};
      final materialCache = <String, Material?>{};
      for (final key in request.reusedPageKeys) {
        if (reusedHits.length >= maxContextMaterialHits) break;
        if (key == excludePage || !seenPageKeys.add(key)) continue;
        final reusedPage = await materials.page(key.$1, key.$2);
        if (reusedPage == null) continue;
        final reusedMaterial = materialCache.containsKey(key.$1)
            ? materialCache[key.$1]
            : (materialCache[key.$1] = await materials.byId(key.$1));
        // 记录换了目标之后，原来目标下的材料页不再进入这次回答。
        if (reusedMaterial == null ||
            (reusedMaterial.goalId != null &&
                reusedMaterial.goalId != goalId)) {
          continue;
        }
        reusedHits.add(
          MaterialHit(
            materialId: reusedMaterial.id,
            materialTitle: reusedMaterial.title,
            pageNo: reusedPage.pageNo,
            content: reusedPage.content,
            label: reusedPage.label,
            isDocx: reusedMaterial.isDocx,
          ),
        );
      }
      materialHits = [
        ...reusedHits,
        ...materialHits,
      ].take(maxContextMaterialHits).toList(growable: false);
    }

    return BuddyContext(
      now: now,
      persona: await personaSource?.call(),
      goal: goal,
      goals: goals,
      openItems: openItems,
      recentAttempts: recent,
      memories: recalled.all,
      priorFeedback: earlier,
      question: question,
      attempt: attempt,
      assessmentRecords: assessmentRecords,
      mode: mode,
      material: material,
      materialPage: page,
      outlinePages: outlinePages,
      materialHits: materialHits,
      relatedRecords: related,
      evidence: evidenceHits,
      crossSessionNotes: crossSessionNotes,
      conversationFocus: conversationFocus,
      sessionId: conversationId ?? request.routingSessionId,
      sourceSearch: evidenceService == null
          ? null
          : (query, limit) async {
              final bundle = await evidenceService.forAnswer(
                query: query,
                scope: answerScope,
                perKindLimit: limit,
                limit: limit,
                excludePage: excludePage,
                now: now,
                stem: question?.stem,
                excludeAttemptId: attempt?.id,
              );
              return bundle.hits;
            },
    );
  }

  /// 本轮带入的作答标识，交给“最近作答”按主键放行。
  static Set<String> _broughtAttemptIds(Set<String> identities) {
    final ids = <String>{};
    for (final identity in identities) {
      final parsed = EvidenceId.tryParse(identity);
      if (parsed?.kind != 'attempt') continue;
      final id = parsed!.primaryId;
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// 给首页提供最近到期的待办。
  Future<NowActivity> loadActivity() async =>
      NowActivity(pending: await tasks.nextDue());
}

/// 首页“接下来”的待办。
class NowActivity {
  const NowActivity({this.pending});

  final PlanItem? pending;

  bool get isEmpty => pending == null;
}
