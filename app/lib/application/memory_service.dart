import '../data/db/write_transactions.dart';
import '../domain/rules/revision_actions.dart';
import '../data/repository/material_repository.dart';
import '../data/repository/memory_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/memory.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/time_format.dart';
import 'service_runtime.dart';
import '../../domain/rules/uuid_v7.dart';

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

/// 记忆查找的适用范围条件：全部、只查不限定范围的条目，或某个目标/材料。
///
/// 记忆的 `scope` 用空值表示适用于全部学习，因此“全部范围”与“只查不限定
/// 范围的条目”要分开表示；具体范围沿用记忆里 `goal:<id>` 与 `material:<id>`
/// 的写法。
class MemoryScopeFilter {
  const MemoryScopeFilter.all() : scope = null, onlyUnscoped = false;

  const MemoryScopeFilter.unscoped() : scope = null, onlyUnscoped = true;

  const MemoryScopeFilter.scoped(String this.scope) : onlyUnscoped = false;

  /// 目标或材料标识；为空时看 [onlyUnscoped]。
  final String? scope;

  /// 只查没有写范围的条目。
  final bool onlyUnscoped;

  /// 不按范围筛选。
  bool get isAll => scope == null && !onlyUnscoped;

  @override
  bool operator ==(Object other) =>
      other is MemoryScopeFilter &&
      other.scope == scope &&
      other.onlyUnscoped == onlyUnscoped;

  @override
  int get hashCode => Object.hash(scope, onlyUnscoped);
}

/// 记忆查找的条件：正文关键词、类别、适用范围与状态。
///
/// 默认与记忆页当前列出的范围一致：有效与已过期都属于 `active` 状态，过期
/// 只由有效期判断，因此这里不把“过期”单列成状态；已删除的条目只提示追溯
/// 入口，不在记忆页重新列出。
class MemorySearchQuery {
  const MemorySearchQuery({
    this.text = '',
    this.kind,
    this.scope = const MemoryScopeFilter.all(),
    this.status = MemoryStatus.active,
  });

  final String text;

  /// 为空时不限类别。
  final MemoryKind? kind;
  final MemoryScopeFilter scope;
  final MemoryStatus status;

  /// 没有关键词、也没有改过任何筛选。
  bool get isDefault =>
      text.trim().isEmpty &&
      kind == null &&
      scope.isAll &&
      status == MemoryStatus.active;

  @override
  bool operator ==(Object other) =>
      other is MemorySearchQuery &&
      other.text == text &&
      other.kind == kind &&
      other.scope == scope &&
      other.status == status;

  @override
  int get hashCode => Object.hash(text, kind, scope, status);
}

/// 记忆查找的一页结果：命中的条目、范围名字与继续翻页的位置。
class MemorySearchResults {
  const MemorySearchResults({
    required this.query,
    required this.memories,
    required this.scopeLabels,
    required this.matched,
    required this.hasMore,
    required this.nextOffset,
  });

  final MemorySearchQuery query;
  final List<Memory> memories;

  /// 范围标识到显示名的对应，与记忆页共用同一份读法。
  final Map<String, String> scopeLabels;

  /// 本次条件命中的总条数，用于在页脚说明还剩多少没有显示。
  final int matched;
  final bool hasMore;
  final int nextOffset;

  bool get isEmpty => memories.isEmpty;

  /// 追加一页；只有同一组条件才能合并，页面换了筛选就重新取第一页。
  MemorySearchResults append(MemorySearchResults next) {
    assert(next.query == query);
    return MemorySearchResults(
      query: query,
      memories: [...memories, ...next.memories],
      scopeLabels: next.scopeLabels,
      matched: next.matched,
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }
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

  /// 记忆查找一页的条数；与记录页查找一致，翻页只取用户真正看得到的一页。
  static const int searchPageSize = 20;

  /// 按正文、类别、适用范围与状态查找，全部在本机完成。
  ///
  /// 读取沿用记忆页的整屏读法，范围名字随结果一起返回；调用方换了查询或筛选
  /// 之后用新的 [MemorySearchQuery] 重取第一页，并用 `RequestGate` 丢弃晚到
  /// 的旧结果。分页在过滤之后执行，因此命中超过一页时也能翻到最早一条。
  Future<MemorySearchResults> search(
    MemorySearchQuery query, {
    int offset = 0,
    int pageSize = searchPageSize,
  }) async {
    final view = await loadPage();
    final now = runtime.policy.now;
    final matched = view.memories
        .where((memory) => _matches(memory, query, now))
        .toList(growable: false);
    final page = matched.skip(offset).take(pageSize).toList(growable: false);
    return MemorySearchResults(
      query: query,
      memories: page,
      scopeLabels: view.scopeLabels,
      matched: matched.length,
      hasMore: offset + page.length < matched.length,
      nextOffset: offset + page.length,
    );
  }

  bool _matches(Memory memory, MemorySearchQuery query, DateTime now) {
    if (memory.status != query.status) return false;
    if (query.kind != null && memory.kind != query.kind) return false;
    if (query.scope.onlyUnscoped && memory.scope != null) return false;
    final scope = query.scope.scope;
    if (scope != null && memory.scope != scope) return false;
    final text = query.text.trim().toLowerCase();
    if (text.isEmpty) return true;
    return memory.content.toLowerCase().contains(text);
  }

  /// 用户改记忆时直接更新类型、内容、线索、范围与有效期；回答读的是改后的内容。
  ///
  /// 类型与内容在同一条提交里写入，撤销仍按提交整组回放。不传 [kind] 时只改
  /// 内容与有效期，类型与范围保持原样；换成语义或程序时不再保留原来的目标或
  /// 材料范围，因为这两类适用于全部学习，只有情景跟本次范围走（ADR-0051 决定
  /// 第 5 条）。检索线索拿不到时写空串，旧线索不留在新正文后面。
  Future<WriteResult> save(
    Memory memory, {
    MemoryKind? kind,
    required String content,
    String searchTerms = '',
    DateTime? validUntil,
  }) {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    final nextKind = kind;
    final terms = searchTerms.trim();
    return transactions.run((txn) async {
      final current = await repository.byId(memory.id);
      if (current == null) throw StateError('这条记忆已不存在');
      final kindChanged = nextKind != null && current.kind != nextKind;
      if (!kindChanged &&
          current.content == text &&
          current.searchTerms == terms &&
          _sameValidUntil(current.validUntil, validUntil)) {
        return const WriteResult.skipped('这条记忆没有变化');
      }
      final savedKind = nextKind ?? current.kind;
      await repository.updateContent(
        memory.id,
        content: text,
        kind: savedKind,
        scope: savedKind.followsContext ? current.scope : null,
        searchTerms: terms,
        validUntil: validUntil,
        transaction: txn,
      );
      return txn.result();
    }, label: editMemoryAction);
  }

  /// 记一条新记忆；[searchTerms] 是写入时顺带给出的检索线索，拿不到时写空串。
  ///
  /// 用户手写不推断程序类，偏好与限制按内容归语义（ADR-0051 决定第 1 条）。
  Future<WriteResult> add({
    required MemoryKind kind,
    required String content,
    String searchTerms = '',
    DateTime? validUntil,
  }) {
    return transactions.run(
      (txn) async {
        await repository.create(
          kind: kind,
          content: content,
          searchTerms: searchTerms,
          sourceKind: MemorySourceKind.user,
          validUntil: validUntil,
          transaction: txn,
        );
        return txn.result();
      },
      label: addMemoryAction,
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  /// 用户确认保留这条记忆：只写 `reviewed_at`，不更新 `updated_at`，也不触发
  /// 索引重建（ADR-0051 决定第 9 条）。计时从最近使用、最近确认保留与创建
  /// 三者里最晚的一个算起，“保留”因此把“很久没用到”的计时推到现在。
  Future<WriteResult> keep(String id) {
    return transactions.run(
      (txn) async {
        final current = await repository.byId(id);
        if (current == null) throw StateError('这条记忆已不存在');
        await repository.markReviewed(id, transaction: txn);
        return txn.result();
      },
      label: keepMemoryAction,
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  /// 删除是软删除；撤销时按反向规则把状态改回 active。
  Future<WriteResult> delete(String id) {
    return transactions.run(
      (txn) async {
        await repository.delete(id, transaction: txn);
        return txn.result();
      },
      label: deleteMemoryAction,
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  bool _sameValidUntil(DateTime? left, DateTime? right) {
    if (left == null || right == null) return left == right;
    return formatDateTime(left) == formatDateTime(right);
  }
}
