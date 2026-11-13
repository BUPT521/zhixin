import '../ai/buddy_prompt.dart';
import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/schedule_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import '../domain/models/assessment.dart';
import '../domain/models/memory.dart';
import '../domain/models/question.dart';
import '../domain/models/study.dart';
import 'evidence_service.dart';
import 'memory_recall.dart';
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
///
/// 当天时间块按自然日期读取；夜间学习记录另按截止小时归到前一天，只影响记录
/// 展示与分组。
class ContextService {
  ContextService({
    required this.tasks,
    required this.attempts,
    required this.schedule,
    required this.memories,
    required this.conversations,
    required this.materials,
    required this.runtime,
    this.evidence,
  });

  final TaskRepository tasks;
  final AttemptRepository attempts;
  final ScheduleRepository schedule;
  final MemoryRepository memories;
  final ConversationRepository conversations;
  final MaterialRepository materials;
  final ServiceRuntime runtime;

  /// 回答前的原文检索；为空时只使用关键词检索，行为与之前一致。
  final EvidenceService? evidence;

  Future<BuddyContext> load({
    Question? question,
    Attempt? attempt,
    List<Assessment> assessmentRecords = const [],
    BuddyMode mode = BuddyMode.chat,
    int? goalId,
    int? materialId,
    int? pageNo,
    int? pageFrom,
    int? pageTo,
    int? conversationId,
    String query = '',
    Set<String> broughtIdentities = const {},
    String? conversationFocus,
    bool includeEarlier = true,
  }) async {
    final current = runtime.policy;
    final now = current.now;
    final range = current.naturalDayRange(now);
    final goals = await tasks.activeGoals();
    final goal = goalId == null ? null : await tasks.goalById(goalId);
    // 待办、当天时间块与最近尝试只服务普通问答的本地兜底和安排学习；
    // 提示、讲解与检查用不到它们，因此不读。
    final withPlanContext = mode == BuddyMode.chat || mode == BuddyMode.plan;
    final openItems = withPlanContext
        ? await tasks.items(openOnly: true, onlyActiveGoals: true)
        : const <PlanItem>[];
    final blocks = withPlanContext
        ? await schedule.blocksBetween(range.start, range.endExclusive)
        : const <ScheduledItem>[];
    final recent = withPlanContext
        ? await conversations.recentSubmitted(
            limit: null,
            goalId: goalId,
            materialId: materialId,
            conversationId: conversationId,
            broughtAttemptIds: _broughtAttemptIds(broughtIdentities),
          )
        : const <AttemptWithQuestion>[];
    final scope = _scopeFor(goalId: goalId, materialId: materialId);
    // 记忆先按有效性与范围筛选，再按这次请求的用途与问题相关性取用。
    final purpose = switch (mode) {
      BuddyMode.plan => MemoryRecallPurpose.plan,
      BuddyMode.check => MemoryRecallPurpose.check,
      BuddyMode.explain || BuddyMode.hint => MemoryRecallPurpose.explain,
      BuddyMode.chat => MemoryRecallPurpose.chat,
    };
    final remembered = await MemoryRecallService(memories)
        .recall(now: now, scope: scope, purpose: purpose, query: query);
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
      final relatedFound = <(int, RelatedRecord)>[];
      final relatedSeen = <int>{};
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

    return BuddyContext(
      now: now,
      goal: goal,
      goals: goals,
      openItems: openItems,
      todayBlocks: blocks,
      recentAttempts: recent,
      memories: remembered,
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
  static Set<int> _broughtAttemptIds(Set<String> identities) {
    final ids = <int>{};
    for (final identity in identities) {
      final parts = identity.trim().split(':');
      if (parts.length < 2 || parts.first != 'attempt') continue;
      final id = int.tryParse(parts[1]);
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// 本次回答的适用范围：调用方给出的目标优先，其次材料；都没有时只取全局
  /// 记忆。讨论与作答的归属由 `MemoryScopeService` 先解析，这里不再读一次
  /// 记录上的归属。
  String? _scopeFor({required int? goalId, required int? materialId}) {
    if (goalId != null) return memoryGoalScope(goalId);
    if (materialId != null) return memoryMaterialScope(materialId);
    return null;
  }

  /// 给首页活动卡用：正在进行的预约、今天的下一次预约，或没有排期的待办。
  ///
  /// 当天时间块按自然日期读取，只有状态为 `planned` 且事项仍未完成的预约参与
  /// 推荐。开始时间已到、结束时间未到的算“正在进行”；开始时间还在后面的算
  /// “接下来”，不再把晚些时候的预约当成当前活动。没有下一次预约时才取最近
  /// 到期的待办，并且不重复展示已经在进行的那一项。
  Future<NowActivity> loadActivity() async {
    final current = runtime.policy;
    final now = current.now;
    final range = current.naturalDayRange(now);
    // 当天时间块与最近到期的待办互不依赖，同时发出，首屏少一次平台通道往返。
    final (blocks, pendingItem) = await (
      schedule.blocksBetween(range.start, range.endExclusive),
      tasks.nextDue(),
    ).wait;
    final open = blocks
        .where((block) => block.block.planned && block.itemStatus.open)
        .toList(growable: false);
    final ongoingScheduled = open
        .where(
          (block) =>
              !block.block.startAt.isAfter(now) &&
              block.block.endAt.isAfter(now),
        )
        .firstOrNull;
    final nextScheduled = open
        .where(
          (block) =>
              block.block.startAt.isAfter(now) &&
              block.block.planItemId != ongoingScheduled?.block.planItemId,
        )
        .firstOrNull;
    // 两项预约对应的事项一次取回，不为每条预约再查一次。
    final items = await tasks.byIds([
      if (ongoingScheduled != null) ongoingScheduled.block.planItemId,
      if (nextScheduled != null) nextScheduled.block.planItemId,
    ]);
    ActivityEntry? entryFor(ScheduledItem? scheduled) {
      if (scheduled == null) return null;
      final item = items[scheduled.block.planItemId];
      if (item == null || !item.open) return null;
      return ActivityEntry(scheduled: scheduled, item: item);
    }

    final ongoing = entryFor(ongoingScheduled);
    final next = entryFor(nextScheduled);
    return NowActivity(
      ongoing: ongoing,
      next: next,
      // 没有下一次预约时才用最近的待办；与正在进行的是同一项时不重复显示。
      pending: next != null || pendingItem == null
          ? null
          : pendingItem.id == ongoing?.item.id
          ? null
          : pendingItem,
    );
  }
}

/// 首页活动卡的一项：一条预约与它对应的事项。
class ActivityEntry {
  const ActivityEntry({required this.scheduled, required this.item});

  final ScheduledItem scheduled;
  final PlanItem item;
}

/// 首页“正在进行”与“接下来”的内容。
///
/// [ongoing] 是当前时间落在其中的预约，[next] 是今天接下来的一次预约，
/// [pending] 是没有下一次预约时最近到期的事项。三者互不重复，界面按状态
/// 分节显示，不再把晚些时候的预约称为“当前安排”。
class NowActivity {
  const NowActivity({this.ongoing, this.next, this.pending});

  final ActivityEntry? ongoing;
  final ActivityEntry? next;
  final PlanItem? pending;

  bool get isEmpty => ongoing == null && next == null && pending == null;
}
