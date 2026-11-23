import '../data/db/write_transactions.dart';
import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/revisions/revision_actions.dart';
import '../domain/models/time_values.dart';
import '../domain/models/memory.dart';
import '../domain/models/question.dart';
import '../domain/models/write_result.dart';

import '../domain/rules/time_format.dart';
import '../domain/rules/text.dart';
import '../../domain/rules/uuid_v7.dart';
import 'service_runtime.dart';

/// 一条待确认的记忆提案。
///
/// 提案带来源（哪次作答）、适用范围（目标或材料）与判断依据；依据按 R2 写明
/// 是否用过帮助、是否声明独立、是否隔一段时间重做，用户确认之后才写入记忆。
///
/// 困难与进展都是情景标签（ADR-0051 决定第 1 条），哪条是困难由来源作答的
/// 结果判断：[isDifficulty] 为真时是困难，否则是进展。
class MemoryProposal {
  const MemoryProposal({
    required this.id,
    required this.kind,
    required this.content,
    required this.scope,
    required this.sourceId,
    required this.sourceLabel,
    required this.basis,
    required this.conditionLabel,
    this.conversationId,
    this.isDifficulty = false,
    this.removesDifficultyId,
    this.removesDifficultyContent,
  });

  final String id;
  final MemoryKind kind;
  final String content;
  final String? scope;

  /// 来源作答的标识；写入记忆时记在 `source_kind = 'attempt'` 的 `source_id`。
  final String sourceId;
  final String sourceLabel;

  /// 判断依据，例如帮助次数、独立性声明与作答时间。
  final String basis;

  /// 提示下完成、独立完成或延迟后的独立完成。
  final String conditionLabel;
  final String? conversationId;

  /// 这条提案是不是“在某处卡住”；困难与进展同为情景，靠这一项区分。
  final bool isDifficulty;

  /// 同一道题以前写下的困难记忆编号：进展提案带一项默认勾选的“同时删除
  /// 旧的困难”（ADR-0051 决定第 9 条）。
  final String? removesDifficultyId;

  /// 要删掉的旧困难正文，卡片上写明依据。
  final String? removesDifficultyContent;
}

/// 一次提取的结果：待确认提案、已经处理过的来源与需要说明的情况。
class MemoryProposalOutcome {
  const MemoryProposalOutcome({
    this.proposals = const [],
    this.skipped = const [],
    this.notes = const [],
  });

  final List<MemoryProposal> proposals;

  /// 同一来源已经有记忆记录（包括删除过的），不再生成提案。
  final List<String> skipped;

  /// 独立性未说明、只在帮助下完成等情况，按 R2 保留说明，不写成独立表现。
  final List<String> notes;

  bool get isEmpty => proposals.isEmpty && notes.isEmpty;
}

/// 从合成历史提取记忆提案，复用现有的确认与撤销入口。
///
/// 提取只看已提交的作答：做错且有帮助时提出困难，隔一段时间后独立完成时提出
/// 进展；在帮助下完成、独立性未说明的情况只留说明，不提出独立完成的判断。
/// 每条来源在首次处理后留下记忆记录，用户纠正或删除后同一来源不再生成旧判断。
class MemoryProposalService {
  MemoryProposalService({
    required this.attempts,
    required this.conversations,
    required this.memories,
    required this.transactions,
    required this.runtime,
  });

  final AttemptRepository attempts;
  final ConversationRepository conversations;
  final MemoryRepository memories;
  final WriteTransactions transactions;
  final ServiceRuntime runtime;

  /// 记忆建议页一屏读到的表：有作答的记录连同题干、最近一次作答与记忆。
  ///
  /// 记忆也列在这里，因为哪些来源已经处理过由记忆表判断：接受建议或撤销
  /// 之后重读一次，页面与“已经处理过”的判断保持同一时刻（ADR-0014）。
  static const Set<String> _questionTables = {
    'conversation',
    'message',
    'attempt',
    'material',
    'memory',
  };

  /// 跟随写入更新的“最近有作答的记录”；页面订阅之后不再自己重读。
  Stream<List<QuestionRow>> watchQuestions({int limit = 20}) => runtime.watch(
    tables: _questionTables,
    read: () => questions(limit: limit),
  );

  /// 有作答的记录，附带每条最近一次作答；与记录页共用同一份读取。
  Future<List<QuestionRow>> questions({int limit = 20}) =>
      conversations.questionRows(limit: limit);

  Future<MemoryProposalOutcome> propose(String conversationId) async {
    final conversation = await conversations.byId(conversationId);
    if (conversation == null) {
      return const MemoryProposalOutcome(notes: ['这条记录已经不存在']);
    }
    final question = await conversations.question(conversationId);
    final stem = question?.displayStem ?? conversation.title ?? '这道题';
    final scope = memoryScopeFor(
      goalId: conversation.goalId,
      materialId: conversation.materialId,
    );
    final existing = await memories.list(includeInactive: true);
    final processed = <String>{
      for (final memory in existing)
        if (memory.sourceKind == MemorySourceKind.attempt &&
            memory.sourceId != null)
          memory.sourceId!,
    };

    final records = await attempts.attemptsFor(conversationId);
    final proposals = <MemoryProposal>[];
    final skipped = <String>[];
    final notes = <String>[];
    // 已经记下的判断按类型与内容去重：同一条判断来自不同作答时只保留一条
    // 提案，用户纠正或删除之后也不会从另一条来源重新长出来。
    final remembered = <String>{
      for (final memory in existing) _contentKey(memory.kind, memory.content),
    };
    final pending = <String, MemoryProposal>{};
    // 界面上按“第几次作答”指称来源；作答编号已经是文本标识，这里按本次读取的
    // 提交顺序给出一句可读的说明，内部仍以标识定位。
    final labels = <String, String>{};
    var submitted = 0;
    for (final attempt in records) {
      if (!attempt.submitted) continue;
      submitted += 1;
      final label = '第 $submitted 次作答';
      labels[attempt.id] = label;
      final basis = _basis(attempt);
      final stuck = _isStuck(attempt);
      if (!stuck && !_isProgress(attempt)) {
        if (attempt.isCorrect == true && attempt.independent == null) {
          notes.add('$stem：$label没有说明是否独立，暂不生成独立完成的判断。');
        } else if (attempt.isCorrect == true && !attempt.delayed) {
          notes.add('$stem：$label在帮助下完成，不记为独立表现。');
        }
        continue;
      }
      // 困难与进展都是情景标签，类别成了同一个值，来源去重按来源编号。
      if (processed.contains(attempt.id)) {
        skipped.add('$stem：$label已经处理过，不再重复生成。');
        continue;
      }
      final content = _contentFor(stem, attempt, stuck: stuck);
      final key = _contentKey(MemoryKind.episodic, content);
      if (remembered.contains(key)) {
        skipped.add('$stem：相同判断已经在记忆里，不再重复提出。');
        continue;
      }
      final earlier = pending[key];
      if (earlier != null) {
        skipped.add(
          '$stem：$label与${labels[earlier.sourceId] ?? earlier.sourceLabel}'
          '指向同一判断，已合并为一条提案。',
        );
        continue;
      }
      final removesDifficulty = stuck
          ? null
          : await _oldDifficultyFor(attempt, scope);
      final proposal = MemoryProposal(
        id: 'attempt:${attempt.id}:${stuck ? 'difficulty' : 'progress'}',
        kind: MemoryKind.episodic,
        content: content,
        scope: scope,
        sourceId: attempt.id,
        sourceLabel: '$label（${question?.sourceRef ?? '本机记录'}）',
        basis: basis,
        conditionLabel: _conditionLabel(attempt),
        conversationId: conversationId,
        isDifficulty: stuck,
        removesDifficultyId: removesDifficulty?.id,
        removesDifficultyContent: removesDifficulty?.content,
      );
      pending[key] = proposal;
      proposals.add(proposal);
      // 同一条来源一次只生成一条提案，避免同一次作答同时写成困难与进展。
      processed.add(attempt.id);
    }
    return MemoryProposalOutcome(
      proposals: proposals,
      skipped: skipped,
      notes: notes,
    );
  }

  /// 同一道题以前写下的、仍然有效的情景记忆里，来源作答有误的那一条。
  ///
  /// 困难与进展现在都是情景标签，只能按来源作答的结果判断哪条是困难
  /// （ADR-0051 决定第 9 条）。
  Future<({String id, String content})?> _oldDifficultyFor(
    Attempt attempt,
    String? scope,
  ) async {
    final episodes = await memories.activeByKind(MemoryKind.episodic, scope);
    if (episodes.isEmpty) return null;
    final stuckAttempts = <String>{};
    for (final episode in episodes) {
      final sourceId = episode.sourceId;
      if (sourceId == null || sourceId == attempt.id) continue;
      final source = await attempts.attemptById(sourceId);
      if (source?.isCorrect == false) stuckAttempts.add(episode.id);
    }
    for (final episode in episodes) {
      if (stuckAttempts.contains(episode.id)) {
        return (id: episode.id, content: episode.content);
      }
    }
    return null;
  }

  /// 用户确认之后写入记忆，返回写结果供撤销；重复确认同一条提案不再写入。
  ///
  /// 进展提案带着“同时删除旧的困难”时，写入与删除在同一条提交里完成
  /// （ADR-0051 决定第 9 条）。
  Future<WriteResult> accept(
    MemoryProposal proposal, {
    bool removeDifficulty = true,
  }) async {
    final known = await memories.hasSource(
      MemorySourceKind.attempt,
      proposal.sourceId,
    );
    if (known) {
      return const WriteResult.skipped('这条作答已经写成记忆');
    }
    final existing = await memories.list(includeInactive: true);
    final key = _contentKey(proposal.kind, proposal.content);
    if (existing.any(
      (memory) => _contentKey(memory.kind, memory.content) == key,
    )) {
      return const WriteResult.skipped('这条记忆已经存在');
    }
    final removesId = removeDifficulty && !proposal.isDifficulty
        ? proposal.removesDifficultyId
        : null;
    return transactions.run(
      (txn) async {
        // 事务内再核对一次，两个确认同时到达时也只写入一条。
        if (await memories.hasSource(
          MemorySourceKind.attempt,
          proposal.sourceId,
          transaction: txn,
        )) {
          return const WriteResult.skipped('这条记忆已经存在');
        }
        await memories.create(
          kind: proposal.kind,
          content: proposal.content,
          scope: proposal.scope,
          sourceKind: MemorySourceKind.attempt,
          sourceId: proposal.sourceId,
          transaction: txn,
        );
        if (removesId != null) {
          final old = await memories.byId(removesId);
          // 旧困难在打开页面之后被用户改过或删掉时只写进展，不覆盖用户的选择。
          if (old != null && old.active) {
            await memories.delete(removesId, transaction: txn);
          }
        }
        return txn.result();
      },
      label: addMemoryAction,
      uid: newUuidV7(),
      onDuplicate: (_) => const WriteResult.skipped('这条记忆已经存在'),
    );
  }

  /// 做错且有帮助时是一次困难。
  static bool _isStuck(Attempt attempt) =>
      attempt.isCorrect == false &&
      (attempt.helps.isNotEmpty || attempt.independent == false);

  /// 隔一段时间后独立完成是一次进展。
  static bool _isProgress(Attempt attempt) =>
      attempt.isCorrect == true &&
      attempt.delayed &&
      attempt.independent == true;

  String _contentFor(String stem, Attempt attempt, {required bool stuck}) {
    if (stuck) {
      final feedback = (attempt.feedback ?? attempt.userAnswer ?? '这一步')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final short = truncateCodePoints(feedback, 40);
      return '$stem：在「$short」处卡住；${_conditionLabel(attempt)}。';
    }
    final time = attempt.submittedAt == null
        ? ''
        : '${attempt.submittedAt!.month} 月 ${attempt.submittedAt!.day} 日';
    return '$stem：${time.isEmpty ? '' : '$time，'}隔一段时间后独立完成，不再需要提示。';
  }

  String _conditionLabel(Attempt attempt) {
    if (attempt.delayed && attempt.independent == true) {
      return '隔一段时间后独立完成';
    }
    if (attempt.independent == false || attempt.helps.isNotEmpty) {
      return attempt.helps.isEmpty
          ? '在应用外帮助下完成'
          : '在 ${attempt.helps.length} 次提示下完成';
    }
    if (attempt.independent == null) return '独立性未说明';
    return '当场独立完成';
  }

  String _basis(Attempt attempt) {
    final parts = <String>[
      '应用内帮助 ${attempt.helps.length} 次',
      switch (attempt.independent) {
        true => '用户记为独立完成',
        false => '用户记为使用了应用外帮助',
        null => '独立性未说明',
      },
      attempt.delayed ? '间隔后重做' : '当场作答',
      switch (attempt.isCorrect) {
        true => '自评正确',
        false => '自评有误',
        null => '暂未判断对错',
      },
      if (attempt.submittedAt != null)
        '提交于 ${formatDate(attempt.submittedAt!)} '
            '${ClockTime(attempt.submittedAt!.hour, attempt.submittedAt!.minute).format()}',
    ];
    return parts.join('；');
  }

  static String _contentKey(MemoryKind kind, String content) =>
      '${kind.value}|${content.replaceAll(RegExp(r'[\s，。；、,.;:：]+'), '')}';
}
