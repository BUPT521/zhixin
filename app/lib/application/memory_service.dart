import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/memory.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/time_format.dart';
import 'service_runtime.dart';

/// 记忆页的一屏：记忆条目与适用范围的名字。
///
/// 范围在记忆里只存标识，界面要显示目标或材料的标题；两份读法与记忆一起
/// 读回，目标改名或材料删除之后整屏重读，标签不会停在旧名字上。
class MemoryPageView {
  const MemoryPageView({required this.memories, required this.scopeLabels});

  final List<Memory> memories;

  /// 范围标识到显示名的对应；目标与材料共用一张表，键是 `goal:<id>` 这类标识。
  final Map<String, String> scopeLabels;
}

/// 记忆页：列出、修改、删除；修改后只碰记忆表，回答读的是新内容。
///
/// 每次保存与删除都在一条提交里完成，并返回提交编号供提示条撤销；内容没有
/// 变化时不形成提交，也不返回编号。
class MemoryService {
  MemoryService(
    this.repository, {
    required this.tasks,
    required this.materials,
    required this.transactions,
    required this.runtime,
  });

  final MemoryRepository repository;

  /// 记忆页显示范围名字要读目标与材料；两处都只读，不改任何数据。
  final TaskRepository tasks;
  final MaterialRepository materials;
  final WriteTransactions transactions;
  final ServiceRuntime runtime;

  /// 记忆页一屏读到的表：记忆条目、目标与材料标题，材料列表还读页码数量。
  static const Set<String> _pageTables = {
    'memory',
    'learning_goal',
    'material',
    'material_page',
  };

  /// 跟随写入更新的记忆页一屏；页面订阅之后不再在保存、删除与撤销之后重读。
  Stream<MemoryPageView> watchMemories() =>
      runtime.watch(tables: _pageTables, read: loadPage);

  /// 读一屏记忆：条目、目标与材料同时发出，范围名字在结果回来之后拼好。
  Future<MemoryPageView> loadPage() async {
    final (memories, goals, materialRows) = await (
      list(),
      tasks.goals(),
      materials.list(),
    ).wait;
    return MemoryPageView(
      memories: memories,
      scopeLabels: {
        for (final goal in goals) memoryGoalScope(goal.id): '目标：${goal.title}',
        for (final material in materialRows)
          memoryMaterialScope(material.id): '材料：${material.title}',
      },
    );
  }

  Future<List<Memory>> list() => repository.list(includeInactive: true);

  /// 用户改记忆时直接更新内容；回答读的是更新后的记忆本身。
  Future<WriteResult> save(
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
        return const WriteResult.skipped('这条记忆没有变化');
      }
      await repository.updateContent(
        memory.id,
        content: text,
        validUntil: validUntil,
        transaction: txn,
      );
      return txn.result();
    }, label: editMemoryAction);
  }

  Future<WriteResult> add({
    required MemoryKind kind,
    required String content,
    DateTime? validUntil,
  }) {
    return transactions.run((txn) async {
      await repository.create(
        kind: kind,
        content: content,
        sourceKind: MemorySourceKind.user,
        validUntil: validUntil,
        transaction: txn,
      );
      return txn.result();
    }, label: addMemoryAction);
  }

  /// 删除是软删除；撤销时按反向规则把状态改回 active。
  Future<WriteResult> delete(String id) {
    return transactions.run((txn) async {
      await repository.delete(id, transaction: txn);
      return txn.result();
    }, label: deleteMemoryAction);
  }

  bool _sameValidUntil(DateTime? left, DateTime? right) {
    if (left == null || right == null) return left == right;
    return formatDateTime(left) == formatDateTime(right);
  }
}
