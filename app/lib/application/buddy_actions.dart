import '../ai/buddy_prompt.dart';
import '../data/db/write_transactions.dart';
import '../data/repository/memory_repository.dart';
import '../domain/models/memory.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/time_policy.dart';
import '../domain/rules/uuid_v7.dart';
import 'memory_view.dart';

/// 一次写入的结果：给界面显示回执，并拿到可以撤销的提交编号。
class AppliedChange {
  const AppliedChange({
    required this.commitId,
    required this.text,
    this.draft,
    this.memoryId,
  });

  final int commitId;
  final String text;

  /// 这条写入对应的记忆草案；从历史消息还原回执时没有原草案。
  ///
  /// 调用方据此把批量写入的结果对回各自的草案。
  final MemoryDraft? draft;

  /// 这一次写入的记忆编号；草案与编号在同一个事务里写下（ADR-0053）。
  final String? memoryId;
}

/// 一条记忆没有写入的原因。
///
/// 现在只有“超过写入长度”一种；确认入口按它区分“已经存在”与“太长没有保存”，
/// 不再把两者说成同一句话。
enum MemorySkipReason { tooLong }

/// 一条被跳过的记忆：哪条草案、为什么没有写入。
class MemorySkip {
  const MemorySkip({
    required this.reason,
    required this.draft,
    required this.message,
  });

  final MemorySkipReason reason;
  final MemoryDraft draft;

  /// 给人看的一句说明，例如“记忆内容超过 200 字，未保存。”。
  final String message;
}

class ApplyResult {
  const ApplyResult({this.changes = const [], this.skipped = const []});

  final List<AppliedChange> changes;

  /// 被跳过的改动与原因，例如内容过长。
  final List<MemorySkip> skipped;

  bool get isEmpty => changes.isEmpty;
}

/// 把本轮模型给出的记忆草案整理成卡片：内容为空的不出现，超长的照常保留
/// 卡片并记下跳过原因。
///
/// 讨论与作答原先各写一份：讨论只给用户明说的超长草案记跳过，作答完全不看
/// 长度，用户点“记下”时才发现写不进去，还被说成“已经存在”。超长不截半句，
/// 也不静默丢卡片：用户看得到这一条，确认入口给出“超过长度，未保存”。
({List<MemoryDraft> cards, List<MemorySkip> skipped}) memoryCards(
  Iterable<MemoryDraft> drafts,
) {
  final cards = <MemoryDraft>[];
  final skipped = <MemorySkip>[];
  var index = 0;
  for (final draft in uniqueById(drafts, (draft) => draft.contentId)) {
    final content = draft.content.trim();
    if (content.isEmpty) continue;
    final card = MemoryDraft(
      id: 'm${index++}',
      kind: draft.kind,
      content: content,
      validUntil: draft.validUntil,
      source: draft.source,
    );
    if (card.tooLong) {
      skipped.add(
        MemorySkip(
          reason: MemorySkipReason.tooLong,
          draft: card,
          message: '记忆内容超过 $memoryContentLimit 字，未保存。',
        ),
      );
    }
    cards.add(card);
  }
  return (cards: cards, skipped: skipped);
}

/// 把模型给的记忆写进库：内容相同的有效记忆不重复写。
///
/// 讨论里只应用记忆这一类写入；下一步建议留在消息里，等用户接受后才创建事项，
/// 范围由草案的类别决定：情景是
/// 发生过的一件事，写入本次讨论的目标或材料；语义与程序是对全部学习成立的
/// 事实与做法，保持全局（ADR-0051 决定第 1 条）。
///
/// 同一次调用里的记忆在同一条提交中写入，回执指向那一次提交；撤销其中一条
/// 会按提交整组撤销。
Future<ApplyResult> applyMemoryDrafts({
  required WriteTransactions transactions,
  required MemoryRepository memories,
  required List<MemoryDraft> drafts,
  required MemorySourceKind sourceKind,
  String? sourceId,
  String? scope,
  WriteTransaction? transaction,
  Clock clock = systemClock,
}) async {
  final changes = <AppliedChange>[];
  final skipped = <MemorySkip>[];
  if (drafts.isEmpty) return const ApplyResult();
  final now = clock();
  Future<ApplyResult> apply(WriteTransaction txn) async {
    final identities = await memories.activeIdentities(now, transaction: txn);
    final keys = <String>{
      for (final memory in identities)
        _memoryKey(
          kind: memory.kind,
          scope: memory.scope,
          content: memory.content,
        ),
    };

    for (final draft in drafts) {
      final content = draft.content.trim();
      if (content.isEmpty) continue;
      if (draft.tooLong) {
        skipped.add(
          MemorySkip(
            reason: MemorySkipReason.tooLong,
            draft: draft,
            message: '记忆内容超过 $memoryContentLimit 字，未保存。',
          ),
        );
        continue;
      }
      final draftScope = draft.kind.followsContext ? scope?.trim() : null;
      final key = _memoryKey(
        kind: draft.kind.value,
        scope: draftScope,
        content: content,
      );
      if (!keys.add(key)) continue;

      final memoryId = newUuidV7();
      await memories.create(
        id: memoryId,
        kind: draft.kind,
        content: content,
        scope: draftScope,
        sourceKind: sourceKind,
        sourceId: sourceId,
        validUntil: draft.validUntil,
        transaction: txn,
      );
      changes.add(
        AppliedChange(
          commitId: await txn.requireCommitId(),
          text: '已添加记忆：${draft.kind.label} · $content',
          draft: draft,
          memoryId: memoryId,
        ),
      );
    }
    return ApplyResult(changes: changes, skipped: skipped);
  }

  return transaction == null ? transactions.run(apply) : apply(transaction);
}

String _memoryKey({
  required String kind,
  required String? scope,
  required String content,
}) => '$kind\u0000${scope ?? ''}\u0000$content';

/// 一次确认的共用流程：写入这条记忆，再把来源条目改成已接受或收起。
///
/// 讨论与作答原先各写一遍同样的判断，改一处时另一处仍按旧规则处理；两条路径
/// 现在只在这里决定“内容重复就不写、卡片改为收起”与“写入后带回执”。
///
/// 超过写入长度的草案不写、也不收起卡片：返回带 [MemorySkip] 的结果，界面
/// 按“超过长度，未保存”提示，用户还可以删掉内容再点“记下”。
Future<AcceptedMemory> confirmMemoryDraft({
  required WriteTransaction transaction,
  required WriteTransactions transactions,
  required MemoryRepository memories,
  required MemoryDraft draft,
  required MemorySourceKind sourceKind,
  required String sourceId,
  required String? scope,
  required Clock clock,
  required Future<void> Function(MemoryCardStatus status, int? commitId)
  recordStatus,
}) async {
  final applied = await applyMemoryDrafts(
    transactions: transactions,
    memories: memories,
    drafts: [draft],
    sourceKind: sourceKind,
    sourceId: sourceId,
    scope: scope,
    transaction: transaction,
    clock: clock,
  );
  if (applied.isEmpty) {
    final skip = applied.skipped.firstOrNull;
    if (skip != null) {
      // 卡片保留：用户看得到这一条，也看得到为什么没有保存。
      return AcceptedMemory(applied: false, notice: skip.message, skip: skip);
    }
    await recordStatus(MemoryCardStatus.dismissed, null);
    return const AcceptedMemory(applied: false, notice: '这条记忆已经存在，没有重复保存。');
  }
  final change = applied.changes.first;
  await recordStatus(MemoryCardStatus.accepted, change.commitId);
  return AcceptedMemory(applied: true, change: change);
}
