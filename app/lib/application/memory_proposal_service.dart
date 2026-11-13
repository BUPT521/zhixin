import '../data/db/write_transactions.dart';
import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/revisions/revision_actions.dart';
import '../domain/models/memory.dart';
import '../domain/models/question.dart';

/// 一条待确认的记忆提案。
///
/// 提案带来源（哪次作答）、适用范围（目标或材料）与判断依据；依据按 R2 写明
/// 是否用过帮助、是否声明独立、是否隔一段时间重做，用户确认之后才写入记忆。
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
  });

  final String id;
  final MemoryKind kind;
  final String content;
  final String? scope;

  /// 来源作答的标识；写入记忆时记在 `source_kind = 'attempt'` 的 `source_id`。
  final int sourceId;
  final String sourceLabel;

  /// 判断依据，例如帮助次数、独立性声明与作答时间。
  final String basis;

  /// 提示下完成、独立完成或延迟后的独立完成。
  final String conditionLabel;
  final int? conversationId;
}

/// 一次提取的结果：待确认提案、已经处理过的来源与需要说明的情况。
class MemoryProposalOutcome {
  const MemoryProposalOutcome({
    this.proposals = const [],
    this.skipped = const [],
    this.notes = const [],
  });

  final List<MemoryProposal> proposals;

  /// 同一来源已经有记忆记录（包括纠正或删除过的），不再生成提案。
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
  });

  final AttemptRepository attempts;
  final ConversationRepository conversations;
  final MemoryRepository memories;
  final WriteTransactions transactions;

  Future<MemoryProposalOutcome> propose(int conversationId) async {
    final conversation = await conversations.byId(conversationId);
    if (conversation == null) {
      return const MemoryProposalOutcome(notes: ['这条记录已经不存在']);
    }
    final question = await conversations.question(conversationId);
    final stem = question?.displayStem ?? conversation.title ?? '这道题';
    final scope = _scopeFor(conversation.goalId, conversation.materialId);
    final existing = await memories.list(includeInactive: true);
    final processed = <int>{
      for (final memory in existing)
        if (memory.sourceKind == 'attempt' && memory.sourceId != null)
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
    for (final attempt in records) {
      if (!attempt.submitted) continue;
      final label = _conditionLabel(attempt);
      final basis = _basis(attempt);
      final memoryKind = _kindFor(attempt);
      if (memoryKind == null) {
        if (attempt.isCorrect == true && attempt.independent == null) {
          notes.add('$stem：第 ${attempt.id} 次作答没有说明是否独立，暂不生成独立完成的判断。');
        } else if (attempt.isCorrect == true && !attempt.delayed) {
          notes.add('$stem：第 ${attempt.id} 次作答在帮助下完成，不记为独立表现。');
        }
        continue;
      }
      if (processed.contains(attempt.id)) {
        skipped.add('$stem：第 ${attempt.id} 次作答已经处理过，不再重复生成。');
        continue;
      }
      final content = _contentFor(stem, attempt, memoryKind);
      final key = _contentKey(memoryKind, content);
      if (remembered.contains(key)) {
        skipped.add('$stem：相同判断已经在记忆里，不再重复提出。');
        continue;
      }
      final earlier = pending[key];
      if (earlier != null) {
        skipped.add(
          '$stem：第 ${attempt.id} 次作答与第 ${earlier.sourceId} 次作答'
          '指向同一判断，已合并为一条提案。',
        );
        continue;
      }
      final proposal = MemoryProposal(
        id: 'attempt:${attempt.id}:${memoryKind.value}',
        kind: memoryKind,
        content: content,
        scope: scope,
        sourceId: attempt.id,
        sourceLabel: '第 ${attempt.id} 次作答（${question?.sourceRef ?? '本机记录'}）',
        basis: basis,
        conditionLabel: label,
        conversationId: conversationId,
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

  /// 用户确认之后写入记忆，返回提交编号供撤销；重复确认同一条提案不再写入。
  Future<int?> accept(MemoryProposal proposal) async {
    final known = await memories.hasSource('attempt', proposal.sourceId);
    if (known) return null;
    final existing = await memories.list(includeInactive: true);
    final key = _contentKey(proposal.kind, proposal.content);
    if (existing.any(
      (memory) => _contentKey(memory.kind, memory.content) == key,
    )) {
      return null;
    }
    return transactions.run((txn) async {
      // 事务内再核对一次，两个确认同时到达时也只写入一条。
      if (await memories.hasSource(
        'attempt',
        proposal.sourceId,
        transaction: txn,
      )) {
        return null;
      }
      await memories.create(
        kind: proposal.kind,
        content: proposal.content,
        scope: proposal.scope,
        sourceKind: 'attempt',
        sourceId: proposal.sourceId,
        transaction: txn,
      );
      return txn.requireCommitId();
    }, label: addMemoryAction);
  }

  MemoryKind? _kindFor(Attempt attempt) {
    if (attempt.isCorrect == false &&
        (attempt.helps.isNotEmpty || attempt.independent == false)) {
      return MemoryKind.difficulty;
    }
    if (attempt.isCorrect == true &&
        attempt.delayed &&
        attempt.independent == true) {
      return MemoryKind.progress;
    }
    return null;
  }

  String _contentFor(String stem, Attempt attempt, MemoryKind kind) {
    if (kind == MemoryKind.difficulty) {
      final stuck = (attempt.feedback ?? attempt.userAnswer ?? '这一步')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final short = stuck.length <= 40 ? stuck : '${stuck.substring(0, 40)}…';
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
        '提交于 ${attempt.submittedAt!.year}-'
            '${attempt.submittedAt!.month.toString().padLeft(2, '0')}-'
            '${attempt.submittedAt!.day.toString().padLeft(2, '0')} '
            '${attempt.submittedAt!.hour.toString().padLeft(2, '0')}:'
            '${attempt.submittedAt!.minute.toString().padLeft(2, '0')}',
    ];
    return parts.join('；');
  }

  static String _contentKey(MemoryKind kind, String content) =>
      '${kind.value}|${content.replaceAll(RegExp(r'[\s，。；、,.;:：]+'), '')}';

  static String? _scopeFor(int? goalId, int? materialId) {
    if (goalId != null) return memoryGoalScope(goalId);
    if (materialId != null) return memoryMaterialScope(materialId);
    return null;
  }
}
