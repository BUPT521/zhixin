import '../data/repository/evidence_repository.dart';
import '../domain/models/evidence.dart';
import '../domain/rules/time_condition.dart';

/// 一次跨次综合的结果：按时间顺序的作答、缺少证据时待确认的内容与可直接进入
/// 回答上下文的命中。
class CrossSessionSummary {
  const CrossSessionSummary({
    this.attempts = const [],
    this.pendingNotes = const [],
    this.evidence = const [],
    this.timeLabel,
    this.threadLabel,
  });

  final List<ThreadAttempt> attempts;
  final List<String> pendingNotes;
  final List<EvidenceHit> evidence;
  final String? timeLabel;

  /// 这一次沿哪条线索找齐作答：当前讨论、同一道题、这份材料或当前目标。
  final String? threadLabel;

  bool get isEmpty => attempts.isEmpty && pendingNotes.isEmpty;

  /// 把各次作答写成一句可供回答引用的说明，区分当时的帮助与后来的独立表现。
  String get narrative {
    if (attempts.isEmpty) return pendingNotes.join('\n');
    final lines = <String>[];
    for (final entry in attempts) {
      final attempt = entry.attempt;
      final at = attempt.submittedAt;
      final when = at == null
          ? '时间未记录'
          : '${at.month} 月 ${at.day} 日 '
                '${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}';
      lines.add(
        '$when：${attempt.selfResult}'
        '${attempt.helps.isEmpty ? '' : '，${attempt.helps.length} 次应用内帮助'}'
        '${attempt.feedback == null ? '' : '，当时卡在${attempt.feedback}'}',
      );
    }
    return lines.join('\n');
  }
}

/// 一条查找线索：先看当前讨论，找不到足够作答时再扩大到同一道题、这份材料，
/// 最后才用用户明确选择的目标。
class _ThreadTier {
  const _ThreadTier({
    required this.label,
    this.conversationId,
    this.stem,
    this.materialId,
    this.pageNo,
    this.goalId,
    this.includeUnassigned = false,
  });

  final String label;
  final int? conversationId;
  final String? stem;
  final int? materialId;
  final int? pageNo;
  final int? goalId;

  /// 沿同一个目标找作答时，是否同时带上没有归属的记录。
  final bool includeUnassigned;
}

/// 跨次综合：沿当前讨论、同一道题、这份材料页与用户选定的目标找齐作答。
///
/// 只在查询带有显式日期或“上次、后来、历次”这类回看意图时触发，避免每次
/// 回答都拉取历史。线索按具体程度逐层扩大：当前讨论够用就不再读同一目标下
/// 的其他记录，回看意图需要区分前后表现时再扩到同题与材料；不会把同一目标
/// 里无关的作答混进来。当前这次作答本身排除在外，它在回答上下文里已经单独
/// 列出。结果按提交时间先后排列，回答可以引用每次作答，并区分当时需要帮助、
/// 后来独立完成与仍待确认的部分。
class CrossSessionService {
  CrossSessionService({required this.repository});

  final EvidenceRepository repository;

  Future<CrossSessionSummary> resolve({
    required String query,
    required EvidenceScope scope,
    required DateTime now,
    String? stem,
    int? excludeAttemptId,
    int limit = 5,
  }) async {
    if (!scope.isAnswerContext) return const CrossSessionSummary();
    final condition = TimeCondition.parse(query, now);
    final cue = TimeCondition.hasTemporalCue(query);
    if (condition == null && !cue) return const CrossSessionSummary();

    // 能确定“同一道题”时只沿讨论与同题展开，不由同一目标的其他记录补数；
    // 没有题目线索时才退回材料页，最后才是用户明确选择的目标。没有目标归属
    // 的求助不沿同题跨记录扩读，只保留当前讨论；本轮带入的来源由检索侧放行。
    final questionTiers = <_ThreadTier>[
      if (scope.conversationId != null)
        _ThreadTier(label: '当前讨论', conversationId: scope.conversationId),
      if (!scope.restrictsToCurrentRecord &&
          stem != null &&
          stem.trim().isNotEmpty)
        _ThreadTier(
          label: '同一道题',
          stem: stem.trim(),
          goalId: scope.goalId,
          includeUnassigned: scope.goalId != null,
        ),
    ];
    final tiers = scope.restrictsToCurrentRecord
        ? questionTiers
        : questionTiers.isNotEmpty
        ? questionTiers
        : <_ThreadTier>[
            if (scope.materialId != null)
              _ThreadTier(
                label: '这份材料',
                materialId: scope.materialId,
                pageNo: scope.pageNo,
              ),
            if (scope.materialId == null && scope.goalId != null)
              _ThreadTier(label: '当前目标', goalId: scope.goalId),
          ];

    final collected = <int, ThreadAttempt>{};
    String? threadLabel;
    for (final tier in tiers) {
      final found = await repository.threadAttempts(
        conversationId: tier.conversationId,
        stem: tier.stem,
        materialId: tier.materialId,
        pageNo: tier.pageNo,
        goalId: tier.goalId,
        includeUnassigned: tier.includeUnassigned,
        from: condition?.from,
        to: condition?.to,
        limit: limit,
      );
      for (final entry in found) {
        if (entry.attempt.id == excludeAttemptId) continue;
        collected.putIfAbsent(entry.attempt.id, () => entry);
      }
      if (found.any((entry) => entry.attempt.id != excludeAttemptId)) {
        threadLabel ??= tier.label;
      }
      // 明确的日期在第一层命中后即可停止；回看意图要至少两次作答才够区分
      // 当时的帮助与后来的独立表现，否则继续沿更宽的线索找。
    }

    final attempts = collected.values.toList(growable: false)
      ..sort((left, right) {
        final leftAt = left.attempt.submittedAt;
        final rightAt = right.attempt.submittedAt;
        if (leftAt == null && rightAt == null) {
          return left.attempt.id.compareTo(right.attempt.id);
        }
        if (leftAt == null) return -1;
        if (rightAt == null) return 1;
        return leftAt.compareTo(rightAt);
      });
    // 取最近的若干次，同时保留“当时的一次”与“之后的一次独立表现”：回看意图
    // 需要这两条证据同时进入上下文，不能因为最近几次都是后来重做而丢掉对照。
    final capped = _recent(
      attempts,
      limit: limit,
      keepLaterPair: TimeCondition.wantsLaterPerformance(query),
    );

    final pending = <String>[];
    if (capped.isEmpty) {
      pending.add(
        '${condition == null ? '这次范围里' : '${condition.label}这一天'}'
        '没有找到更多作答，尚待确认：是否记错了日期，或那次学习没有提交作答。',
      );
    }
    var unstated = 0;
    for (final entry in capped) {
      if (entry.attempt.independent == null) unstated++;
    }
    if (unstated > 0) {
      pending.add('有 $unstated 次作答没有说明是否独立，不能据此判断已经掌握。');
    }
    if (capped.length == 1 && TimeCondition.wantsLaterPerformance(query)) {
      pending.add('目前只有一次作答，缺少后来的独立表现，尚待确认。');
    }

    final evidence = <EvidenceHit>[
      for (var index = 0; index < capped.length; index++)
        _hitFor(capped[index], index),
    ];
    return CrossSessionSummary(
      attempts: capped,
      pendingNotes: pending,
      evidence: evidence,
      timeLabel: condition?.label,
      threadLabel: threadLabel,
    );
  }

  /// 按提交时间取最近的若干次；[keepLaterPair] 为真时再补上“当时用过帮助的
  /// 一次”和“之后一次独立完成”，用这两条替换较早的重复记录。
  ///
  /// 输入已按提交时间正序。取最近若干次只做下标选择，不重新查询数据库；证据
  /// 顺序仍按提交时间先后返回，回答可以分清哪一次在前。
  static List<ThreadAttempt> _recent(
    List<ThreadAttempt> attempts, {
    required int limit,
    required bool keepLaterPair,
  }) {
    if (attempts.length <= limit) return attempts;
    final kept = <int>{
      for (
        var index = attempts.length - limit;
        index < attempts.length;
        index++
      )
        index,
    };
    if (keepLaterPair) {
      final pair = _laterPair(attempts);
      if (pair != null) {
        kept.addAll([pair.at, pair.later]);
        // 超出上限时从最旧、且不属于这一对的记录开始让位。
        for (
          var index = 0;
          kept.length > limit && index < attempts.length;
          index++
        ) {
          if (index == pair.at || index == pair.later) continue;
          kept.remove(index);
        }
      }
    }
    final ordered = kept.toList()..sort();
    final chosen = ordered.length <= limit
        ? ordered
        : ordered.sublist(ordered.length - limit);
    return [for (final index in chosen) attempts[index]];
  }

  /// 最近一次独立完成，以及它之前最近一次用过帮助的作答。
  static ({int at, int later})? _laterPair(List<ThreadAttempt> attempts) {
    int? later;
    for (var index = attempts.length - 1; index >= 0; index--) {
      if (attempts[index].attempt.independent == true) {
        later = index;
        break;
      }
    }
    if (later == null) return null;
    for (var index = later - 1; index >= 0; index--) {
      final attempt = attempts[index].attempt;
      if (attempt.helps.isNotEmpty || attempt.independent == false) {
        return (at: index, later: later);
      }
    }
    return null;
  }

  EvidenceHit _hitFor(ThreadAttempt entry, int index) {
    final attempt = entry.attempt;
    final at = attempt.submittedAt;
    final when = at == null
        ? '时间未记录'
        : '${at.month} 月 ${at.day} 日 '
              '${at.hour.toString().padLeft(2, '0')}:'
              '${at.minute.toString().padLeft(2, '0')}';
    final answer = (attempt.userAnswer ?? '').replaceAll(RegExp(r'\s+'), ' ');
    final shortAnswer = answer.length <= 60
        ? answer
        : '${answer.substring(0, 60)}…';
    final parts = <String>[
      '$when 提交',
      attempt.selfResult,
      if (answer.isNotEmpty) '答案：$shortAnswer',
      if (attempt.feedback != null) '当时卡在：${attempt.feedback}',
      if (attempt.helps.isNotEmpty) '应用内帮助 ${attempt.helps.length} 次',
      if (attempt.redoOfAttemptId != null) '复查第 ${attempt.redoOfAttemptId} 次作答',
    ];
    return EvidenceHit(
      kind: EvidenceKind.answer,
      identity: 'attempt:${attempt.id}',
      title: '一次已提交作答 · $when',
      snippet: parts.join('；'),
      matchedText: answer,
      literal: false,
      score: 60 - index * 0.1,
      location: EvidenceLocation(
        conversationId: entry.conversationId,
        attemptId: attempt.id,
        materialId: entry.materialId,
        pageNo: entry.pageNo,
      ),
      createdAt: at,
      sourceRef: entry.sourceRef,
      text: parts.join('；'),
    );
  }
}
