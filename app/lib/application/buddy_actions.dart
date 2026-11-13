import '../ai/buddy_prompt.dart';
import '../data/db/write_transactions.dart';
import '../data/repository/memory_repository.dart';
import '../domain/rules/time_policy.dart';
import 'memory_view.dart';

/// 一次写入的结果：给界面显示回执，并拿到可以撤销的提交编号。
class AppliedChange {
  const AppliedChange({required this.commitId, required this.text, this.draft});

  final int commitId;
  final String text;

  /// 这条写入对应的记忆草案；从历史消息还原回执时没有原草案。
  ///
  /// 调用方据此把批量写入的结果对回各自的草案。
  final MemoryDraft? draft;
}

class ApplyResult {
  const ApplyResult({this.changes = const [], this.skipped = const []});

  final List<AppliedChange> changes;

  /// 被跳过的改动与原因，例如内容过长。
  final List<String> skipped;

  bool get isEmpty => changes.isEmpty;
}

/// 把模型给的记忆写进库：内容相同的有效记忆不重复写。
///
/// 讨论里只应用记忆这一类写入；下一步建议留在消息里，等用户接受后才创建事项，
/// 日程只由用户在安排页自己写入（00 第 4 章）。困难与进展写入本次目标的
/// 适用范围，偏好与限制保持全局。
///
/// 同一次调用里的记忆在同一条提交中写入，回执指向那一次提交；撤销其中一条
/// 会按提交整组撤销。
Future<ApplyResult> applyMemoryDrafts({
  required WriteTransactions transactions,
  required MemoryRepository memories,
  required List<MemoryDraft> drafts,
  required String sourceKind,
  int? sourceId,
  String? scope,
  WriteTransaction? transaction,
  Clock clock = systemClock,
}) async {
  final changes = <AppliedChange>[];
  final skipped = <String>[];
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
      if (content.length > 200) {
        skipped.add('记忆内容超过 200 字，未保存。');
        continue;
      }
      final draftScope = draft.kind.followsContext ? scope?.trim() : null;
      final key = _memoryKey(
        kind: draft.kind.value,
        scope: draftScope,
        content: content,
      );
      if (!keys.add(key)) continue;

      await memories.create(
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
Future<AcceptedMemory> confirmMemoryDraft({
  required WriteTransaction transaction,
  required WriteTransactions transactions,
  required MemoryRepository memories,
  required MemoryDraft draft,
  required String sourceKind,
  required int sourceId,
  required String? scope,
  required Clock clock,
  required Future<void> Function(String status, int? commitId) recordStatus,
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
    await recordStatus('dismissed', null);
    return const AcceptedMemory(applied: false, notice: '这条记忆已经存在，没有重复保存。');
  }
  final change = applied.changes.first;
  await recordStatus('accepted', change.commitId);
  return AcceptedMemory(applied: true, change: change);
}
