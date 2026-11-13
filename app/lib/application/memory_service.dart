import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/repository/memory_repository.dart';
import '../domain/models/memory.dart';
import '../domain/rules/time_format.dart';

/// 记忆页：列出、修改、删除；修改后只碰记忆表，回答读的是新内容。
///
/// 每次保存与删除都在一条提交里完成，并返回提交编号供提示条撤销；内容没有
/// 变化时不形成提交，也不返回编号。
class MemoryService {
  MemoryService(this.repository, {required this.transactions});

  final MemoryRepository repository;
  final WriteTransactions transactions;

  Future<List<Memory>> list() => repository.list(includeInactive: true);

  /// 用户改记忆时直接更新内容；回答读的是更新后的记忆本身。
  Future<int?> save(
    Memory memory, {
    required String content,
    DateTime? validUntil,
  }) {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    return transactions.run((txn) async {
      final current = await repository.byId(memory.id);
      if (current == null) throw StateError('这条记忆已不存在');
      if (current.content == text &&
          _sameValidUntil(current.validUntil, validUntil)) {
        return null;
      }
      await repository.updateContent(
        memory.id,
        content: text,
        validUntil: validUntil,
        transaction: txn,
      );
      return txn.requireCommitId();
    }, label: editMemoryAction);
  }

  Future<int?> add({
    required MemoryKind kind,
    required String content,
    DateTime? validUntil,
  }) {
    return transactions.run((txn) async {
      await repository.create(
        kind: kind,
        content: content,
        sourceKind: 'user',
        validUntil: validUntil,
        transaction: txn,
      );
      return txn.requireCommitId();
    }, label: addMemoryAction);
  }

  /// 删除是软删除；撤销时按反向规则把状态改回 active。
  Future<int?> delete(int id) {
    return transactions.run((txn) async {
      await repository.delete(id, transaction: txn);
      return txn.requireCommitId();
    }, label: deleteMemoryAction);
  }

  bool _sameValidUntil(DateTime? left, DateTime? right) {
    if (left == null || right == null) return left == right;
    return formatDateTime(left) == formatDateTime(right);
  }
}
