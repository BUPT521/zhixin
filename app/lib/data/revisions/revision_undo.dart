import 'dart:convert';

import '../db/raw_executor.dart';
import '../db/sql.dart';

import '../../domain/models/chat_message_payload.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import 'revision_engine.dart';
import 'revision_models.dart';

/// 一次撤销核对需要读到的上下文：目标提交、这条净变化、当前行、同一次提交的
/// 全部变化，以及判断“现在”的时间。
class UndoCheck {
  const UndoCheck({
    required this.executor,
    required this.commit,
    required this.change,
    required this.current,
    required this.commitChanges,
    required this.clock,
  });

  final RawExecutor executor;
  final RevisionCommit commit;
  final RevisionChange change;

  /// 这一行当前的值；行已经不存在时为空。
  final TypedRow? current;

  /// 目标提交里的全部净变化，供 guard 判断同一条提交是否会把状态恢复。
  final List<RevisionChange> commitChanges;
  final Clock clock;
}

/// 撤销的业务约束：按表声明覆盖范围，并在写回之前核对恢复后是否仍然成立。
///
/// 数据层只做通用核对（代次、后续修改、当前值、白名单与消息回执清理）；哪些
/// 表可以撤销、撤销前还要满足什么业务条件由实现方声明与实现，应用层在
/// `lib/application/undo_guards/` 注册（ADR-0039）。可撤销表的白名单就是所有
/// 已注册 guard 的 [tables] 汇总，随动作开放的表来自 [actionTables]。
abstract interface class UndoGuard {
  /// 这个 guard 负责的表。
  Set<String> get tables;

  /// 只对指定动作开放的表，例如更正材料页同一条提交里的材料行。
  Map<String, Set<String>> get actionTables;

  /// 恢复后不成立时返回不能撤销的原因，成立时返回空。
  Future<String?> check(UndoCheck check);
}

/// 撤销链：谁回指了谁，以及一条提交现在是否仍被撤销。
///
/// 撤销提交可以再被撤销，含义是重做。回指链 `C ← U ← R` 上，`U` 撤销 `C`、
/// `R` 重做 `C`；一条提交被撤销，当且仅当回指它的提交里有一条仍然生效。
/// 所以不能只看“有没有人回指”，要沿链递归：`U` 被 `R` 撤销（R 生效）之后，
/// `C` 重新生效。
///
/// 链上的提交总是比它回指的目标新，正常数据不会成环；坏数据用 [visiting]
/// 兜住，按“仍生效”处理，避免一条读不出来的记录让整页都读不出来。
class _UndoChain {
  _UndoChain(this._reverters);

  /// 被回指的提交编号 → 回指它的提交编号。
  final Map<int, List<int>> _reverters;
  final Map<int, bool> _memo = {};

  /// 这条提交是否已经被一条仍生效的撤销提交回指。
  bool isReverted(int id) => _isReverted(id, <int>{});

  bool _isReverted(int id, Set<int> visiting) {
    final cached = _memo[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) return false;
    var reverted = false;
    for (final reverter in _reverters[id] ?? const <int>[]) {
      if (!_isReverted(reverter, visiting)) {
        reverted = true;
        break;
      }
    }
    visiting.remove(id);
    _memo[id] = reverted;
    return reverted;
  }

  /// 回指 [id] 的提交，以及继续回指这些提交的提交：撤销与重做 [id] 形成的
  /// 整条链。核对后续修改时跳过它们，因为它们记录的正是这次动作本身。
  Set<int> chainOf(int id) {
    final result = <int>{};
    final queue = <int>[...?_reverters[id]];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!result.add(current)) continue;
      queue.addAll(_reverters[current] ?? const <int>[]);
    }
    return result;
  }
}

/// 单项撤销：在同一个事务里核对代次、后续修改、当前值与业务约束，全部通过才
/// 整组写回，并追加一条撤销提交。
///
/// 撤销一条撤销提交的含义是重做。回指链 `C ← U ← R` 上，`U` 撤销 `C` 的改动，
/// `R` 撤销 `U`，所以撤销 `U` 就是按 `U` 记下的反向变化正向写回 `C` 的内容，
/// 撤销 `R` 又回到撤销后的状态；链上第奇数条撤销提交重做、第偶数条撤销提交
/// 撤销，动作名与文案都按这个层数给出。重做的核对规则与撤销相同：之后有人
/// 改过同一格、当前值与撤销后的值不一致时拒绝。重做形成的提交类型仍是 `undo`，
/// `reverted_commit_id` 指向被重做的那条撤销提交。消息里的回执不恢复，界面按
/// [activeCommits] 重新判断回执状态。
///
/// 可撤销表的白名单与预约冲突、学习事项归属、课表这三类业务规则由应用层注册
/// 的 [guards] 提供，数据层不内置业务规则，也不反向依赖应用层。远端提交与
/// 普通写入适用同一份白名单：能撤销的远端改动照常按反向规则写回。
///
/// 可以撤销预约、记忆、学习事项本身、材料页更正、每日截止小时，以及消息里
/// 的回执字段。讨论卡片、学习页、安排页与材料详情的即时回执指向提交历史，
/// 撤销的就是它所属的那次提交。回执所在的 `message.structured_json` 不整行
/// 回滚，只清掉指向这次提交的条目：同一消息里后续留下的回执不能被更早的
/// 撤销抹掉。
///
/// 截止小时写在 `profile` 一行，撤销后应用根要重新读取设置；否则界面继续
/// 使用启动时缓存的值，时间口径与导出文件名都和库里的设置不一致。
class RevisionUndoService {
  RevisionUndoService({
    required this.engine,
    required this.clock,
    required this.guards,
  });

  final RevisionEngine engine;
  final Clock clock;

  /// 应用层注册的业务约束；可撤销表的白名单也从它们的声明汇总。
  final List<UndoGuard> guards;

  /// 所有 guard 声明的可撤销表；数据层不内置名单。
  late final Set<String> _allowedTables = {
    for (final guard in guards) ...guard.tables,
  };

  /// 随动作开放的表，例如更正材料页同一条提交里的材料行；多个 guard 声明
  /// 同一个动作时合并，不互相覆盖。
  late final Map<String, Set<String>> _actionTables = _collectActionTables();

  Map<String, Set<String>> _collectActionTables() {
    final result = <String, Set<String>>{};
    for (final guard in guards) {
      for (final entry in guard.actionTables.entries) {
        result.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
      }
    }
    return result;
  }

  Future<RevisionUndoResult> undo(RawDatabase db, int commitId) async {
    return db.transaction((txn) async {
      final target = await engine.commitById(txn, commitId);
      if (target == null) {
        return const RevisionUndoResult(applied: false, message: '找不到要撤销的提交');
      }
      final headId = await engine.headId(txn);
      final head = await engine.commitById(txn, headId);
      if (head == null) {
        return const RevisionUndoResult(applied: false, message: '当前版本状态不完整');
      }
      final chain = await _undoChain(txn);
      final changes = await engine.changesFor(txn, commitId);
      // 回指链的层数决定这次动作叫撤销还是重做：撤销一条撤销提交就是重做。
      final start = await _chainStart(txn, target);
      final redo = start.depth.isOdd;
      final blocked = _blockedReason(
        target: target,
        headGeneration: head.generation,
        reverted: chain.isReverted(commitId),
        changes: changes,
        start: start,
      );
      if (blocked != null) {
        return RevisionUndoResult(applied: false, message: blocked);
      }

      // `message` 的变化不参与写回：撤销时回执是定向清掉的，重做不把它们装
      // 回去，回执状态由界面按 activeCommits 重新判断。
      final changeRows = [
        for (final change in changes)
          if (change.table != 'message') change,
      ];
      final conflict = await _validate(
        txn,
        target,
        changeRows,
        chain: chain,
        redo: redo,
      );
      if (conflict != null) {
        return RevisionUndoResult(applied: false, message: conflict);
      }

      await engine.beginCommand(txn);
      for (final change in changeRows) {
        await _apply(txn, change);
      }
      // 撤销要清掉指向目标提交的回执；重做不恢复旧回执，也不重复清理。
      if (!redo) {
        await _cleanReceipts(txn, commitId: commitId, changes: changes);
      }
      final action = start.depth.isOdd
          ? '重做操作'
          : (start.depth == 0 ? '撤销操作' : '撤销重做');
      final commit = await engine.finishCommand(
        txn,
        action: action,
        actor: 'user',
        kind: RevisionKind.undo,
        revertedCommitId: commitId,
      );
      if (commit == null) {
        return const RevisionUndoResult(applied: false, message: '没有产生需要写入的变化');
      }
      return RevisionUndoResult(
        applied: true,
        message: start.depth.isOdd
            ? '已重做这次撤销'
            : (start.depth == 0 ? '已撤销这次操作' : '已撤销这次重做'),
        commit: commit,
      );
    });
  }

  /// 提交列表用的判断：同一套白名单、代次与撤销范围，给出每条提交不能撤销
  /// 的原因；值为 null 表示结构上可以撤销，当前值与后续修改仍在撤销时核对。
  ///
  /// 撤销提交本身也在这里判断：仍在生效的撤销提交可以再撤销，也就是重做；
  /// 已经被重做过的撤销提交给出原因，不能再撤销一次。
  Future<Map<int, String?>> undoBlockReasons(
    RawExecutor executor,
    Iterable<RevisionCommit> commits,
  ) async {
    final list = commits.toList(growable: false);
    if (list.isEmpty) return const {};
    final head = await engine.commitById(
      executor,
      await engine.headId(executor),
    );
    if (head == null) {
      return {for (final commit in list) commit.id: '当前版本状态不完整'};
    }
    final chain = await _undoChain(executor);
    final ids = [for (final commit in list) commit.id];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await executor.rawQuery(
      'SELECT * FROM revision_change WHERE commit_id IN ($placeholders) '
      'ORDER BY commit_id, seq',
      ids,
    );
    final changesByCommit = <int, List<RevisionChange>>{};
    for (final row in rows) {
      final change = RevisionChange.fromRow(row);
      changesByCommit.putIfAbsent(change.commitId, () => []).add(change);
    }
    final reasons = <int, String?>{};
    for (final commit in list) {
      final start = await _chainStart(executor, commit);
      reasons[commit.id] = _blockedReason(
        target: commit,
        headGeneration: head.generation,
        reverted: chain.isReverted(commit.id),
        changes: changesByCommit[commit.id] ?? const [],
        start: start,
      );
    }
    return reasons;
  }

  /// 界面的回执是否仍然可以撤销；整版恢复或导入之后的旧提交与被撤销的提交
  /// 不在结果里。
  ///
  /// 与 `RevisionEngine.activeCommits` 的区别是这里沿撤销链递归判断：重做之后
  /// 原提交重新生效，回执入口据此重新出现；已经被重做过的撤销提交不再生效。
  Future<Set<int>> activeCommits(
    RawExecutor executor,
    Iterable<int> ids,
  ) async {
    final values = ids.toSet().toList(growable: false);
    if (values.isEmpty) return const {};
    final head = await engine.commitById(
      executor,
      await engine.headId(executor),
    );
    if (head == null) return const {};
    final placeholders = List.filled(values.length, '?').join(', ');
    final rows = await executor.rawQuery(
      'SELECT id, generation FROM revision_commit '
      'WHERE id IN ($placeholders)',
      values,
    );
    final chain = await _undoChain(executor);
    return {
      for (final row in rows)
        if (row['generation'] == head.generation &&
            !chain.isReverted(row['id']! as int))
          row['id']! as int,
    };
  }

  /// 当前代次里还没被撤销的提交，按编号倒序；撤销提交本身不在其中。
  ///
  /// 与 `RevisionEngine.undoableCommits` 的区别同 [activeCommits]：重做之后原
  /// 提交重新进入结果；撤销提交本身不按普通撤销处理，界面用
  /// [undoBlockReasons] 给出“重做”入口。
  Future<List<RevisionCommit>> undoableCommits(RawExecutor executor) async {
    final head = await engine.commitById(
      executor,
      await engine.headId(executor),
    );
    if (head == null) return const [];
    final rows = await executor.rawQuery(
      'SELECT * FROM revision_commit '
      'WHERE id != 0 AND generation = ? ORDER BY id DESC',
      [head.generation],
    );
    final chain = await _undoChain(executor);
    return [
      for (final row in rows)
        if (row['kind'] != RevisionKind.undo.value &&
            !chain.isReverted(row['id']! as int))
          RevisionCommit.fromRow(row),
    ];
  }

  /// 指定动作、且改动落在指定表里的可撤销提交，按编号倒序。
  ///
  /// 查询与 `RevisionEngine.receiptCommits` 相同，撤销链的判断放在 Dart 里做，
  /// 因为 SQL 里的“有没有人回指”只能排除一层：重做之后原提交重新可撤销，
  /// 安排页据此重新给出回执。
  Future<List<RevisionCommit>> receiptCommits(
    RawExecutor executor, {
    required Set<String> actions,
    required Set<String> tables,
  }) async {
    if (actions.isEmpty || tables.isEmpty) return const [];
    final head = await engine.commitById(
      executor,
      await engine.headId(executor),
    );
    if (head == null) return const [];
    final actionSlots = List.filled(actions.length, '?').join(', ');
    final tableSlots = List.filled(tables.length, '?').join(', ');
    final rows = await executor.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      WHERE c.id != 0 AND c.generation = ? AND c.reverted_commit_id IS NULL
        AND c.action IN ($actionSlots)
        AND EXISTS (
          SELECT 1 FROM revision_change ch
          WHERE ch.commit_id = c.id AND ch.table_name IN ($tableSlots)
        )
      ORDER BY c.id DESC
      ''',
      [head.generation, ...actions, ...tables],
    );
    final chain = await _undoChain(executor);
    return [
      for (final row in rows)
        if (!chain.isReverted(row['id']! as int)) RevisionCommit.fromRow(row),
    ];
  }

  /// 读撤销链：被回指的提交编号 → 回指它的提交编号。
  ///
  /// 只有撤销提交会写 `reverted_commit_id`；撤销提交自己也可以再被撤销，
  /// 所以一条提交可能被多条撤销提交回指。
  Future<_UndoChain> _undoChain(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT id, reverted_commit_id FROM revision_commit '
      'WHERE reverted_commit_id IS NOT NULL',
    );
    final reverters = <int, List<int>>{};
    for (final row in rows) {
      final target = row['reverted_commit_id'] as int?;
      if (target == null) continue;
      reverters.putIfAbsent(target, () => <int>[]).add(row['id']! as int);
    }
    return _UndoChain(reverters);
  }

  /// 沿回指链走到起点：撤销链的层数与链起点的提交。
  ///
  /// 层数用于文案与动作名：0 是普通提交，1 是撤销，2 是重做，3 是再撤销，
  /// 依此类推。链起点的动作用于判断随动作开放的表：撤销提交自己只记
  /// “撤销操作”，更正材料页里的材料行这类表要回到最初的动作才开放。
  ///
  /// 链上的提交总是比回指的目标新；遇到断链（目标已被裁剪）或坏数据时按
  /// 已经走过的层数返回，不让一条读不出来的记录影响整页。
  Future<({int depth, RevisionCommit root})> _chainStart(
    RawExecutor executor,
    RevisionCommit commit,
  ) async {
    var depth = 0;
    var root = commit;
    final seen = <int>{};
    while (root.isUndo && root.revertedCommitId != null && seen.add(root.id)) {
      depth++;
      final parent = await engine.commitById(executor, root.revertedCommitId!);
      if (parent == null) break;
      root = parent;
    }
    return (depth: depth, root: root);
  }

  /// 撤销前的结构判断；单项撤销与提交列表共用这一份规则。
  ///
  /// [start] 是目标提交在回指链上的位置：层数决定文案（撤销还是重做），链
  /// 起点的动作决定随动作开放的表，因为撤销提交自己只记“撤销操作”。
  String? _blockedReason({
    required RevisionCommit target,
    required int headGeneration,
    required bool reverted,
    required List<RevisionChange> changes,
    required ({int depth, RevisionCommit root}) start,
  }) {
    if (target.isBaseline) return '找不到要撤销的提交';
    if (target.generation != headGeneration) {
      return '整版恢复或导入之后，不能撤销更早的提交';
    }
    if (reverted) {
      // 撤销提交还可以再撤销（重做），所以只有它已经被重做过时才拒绝；
      // 普通提交被撤销过就不能再撤销第二次。撤销链上偶数层是重做、奇数层
      // 是撤销，回指者的方向由此反过来。
      if (!target.isUndo) return '这次操作已经撤销';
      return start.depth.isEven ? '这次重做已经撤销' : '这次撤销已经重做';
    }
    if (target.kind == RevisionKind.maintenance) {
      // 这条提交只是把失效的提交编号从消息里去掉；反向回放会把它们装回去。
      return '清理回执的记录不能单独撤销，需要回到更早的状态请用整版恢复';
    }
    if (target.kind == RevisionKind.restore ||
        target.kind == RevisionKind.import) {
      return '整版恢复请用恢复入口，不能按单项撤销处理';
    }
    if (changes.isEmpty) return '这次提交没有可以撤销的数据变化';
    final allowedTables = <String>{
      ..._allowedTables,
      ...?_actionTables[start.root.action],
    };
    for (final change in changes) {
      if (!allowedTables.contains(change.table)) {
        return '“${change.table}”的改动暂不支持单项撤销';
      }
      if (change.table == 'message' && change.op != ChangeOp.update) {
        return '新增或删除的消息不能按单项撤销';
      }
    }
    return null;
  }

  /// 撤销或重做之前的核对：之后有没有人改过同一格、当前值是否仍等于目标提交
  /// 写完之后的值，以及业务约束。
  ///
  /// 重做核对的是“撤销之后”的状态：当前值必须等于撤销提交写回的值，之后有人
  /// 改过同一格同样拒绝；原因文案按 [redo] 给出，用户看到的说法才和这次动作
  /// 对得上。
  Future<String?> _validate(
    RawExecutor txn,
    RevisionCommit target,
    List<RevisionChange> changes, {
    required _UndoChain chain,
    required bool redo,
  }) async {
    for (final change in changes) {
      final later = await _laterChanges(txn, target, change, chain);
      if (later.isNotEmpty) {
        return redo ? '这次撤销之后，同一项内容又被修改过，不能重做' : '这次操作之后，同一项内容又被修改过，不能撤销';
      }

      final current = await _currentRow(txn, change);
      switch (change.op) {
        case ChangeOp.insert:
          if (current == null) {
            return redo ? '这次撤销写入的内容已经不存在，不能重做' : '要撤销的新增内容已经不存在';
          }
          if (!_sameContent(current, change.after!)) {
            return redo ? '这次撤销写入的内容又有变化，不能重做' : '新增之后内容又有变化，不能撤销';
          }
        case ChangeOp.delete:
          if (current != null) {
            return redo ? '这次撤销删除的位置已经有新内容，不能重做' : '要撤销的删除位置已经有新内容';
          }
        case ChangeOp.update:
          if (current == null) {
            return redo ? '这次撤销恢复的内容已经不存在，不能重做' : '要撤销的内容已经不存在';
          }
          for (final entry in change.after!.entries) {
            if (revisionBookkeepingColumns.contains(entry.key)) continue;
            final value = current[entry.key];
            if (value == null || !value.equals(entry.value)) {
              return redo ? '这次撤销恢复的内容已经不是原来的样子，不能重做' : '要撤销的内容已经不是原来的样子';
            }
          }
      }

      for (final guard in guards) {
        if (!guard.tables.contains(change.table)) continue;
        final blocked = await guard.check(
          UndoCheck(
            executor: txn,
            commit: target,
            change: change,
            current: current,
            commitChanges: changes,
            clock: clock,
          ),
        );
        if (blocked != null) return blocked;
      }
    }
    return null;
  }

  /// 目标提交之后同一行又被改到的变化；只改维护列的不算。
  ///
  /// 撤销写回时维护列写成撤销时刻、不写回旧值，所以之后任何一次写入顺手改到
  /// 的 `updated_at` 不再阻止撤销；同一行改过其他列仍然阻止。撤销新增与撤销
  /// 删除也按同一口径：之后只动过维护列的行仍可整行删除或重新插入。
  ///
  /// 撤销与重做形成的整条链要跳过：它们记录的正是这次动作反向或正向的写回，
  /// 不是别人后来的修改。重做之后再撤销原提交时，链上已经有相反的写回，
  /// 不能因此把原提交判成“之后又被改过”。
  Future<List<RevisionChange>> _laterChanges(
    RawExecutor txn,
    RevisionCommit target,
    RevisionChange change,
    _UndoChain chain,
  ) async {
    final skipped = chain.chainOf(target.id);
    final rows = await selectRows(
      txn,
      'revision_change',
      where: 'commit_id > ? AND table_name = ? AND row_key = ?',
      whereArgs: [target.id, change.table, change.rowKey],
      orderBy: 'commit_id, seq',
    );
    final targetColumns = _contentColumns(change);
    final result = <RevisionChange>[];
    for (final row in rows) {
      final later = RevisionChange.fromRow(row);
      if (skipped.contains(later.commitId)) continue;
      final columns = _contentColumns(later);
      if (change.op != ChangeOp.update) {
        if (columns.isNotEmpty) result.add(later);
        continue;
      }
      if (targetColumns.intersection(columns).isNotEmpty) {
        result.add(later);
      }
    }
    return result;
  }

  /// 一次变化里除维护列以外的列。
  Set<String> _contentColumns(RevisionChange change) => {
    for (final column in <String>{
      ...?change.after?.keys,
      ...?change.before?.keys,
    })
      if (!revisionBookkeepingColumns.contains(column)) column,
  };

  /// 两行的内容是否一致；维护列由撤销写回时刷新，不参与比较。
  bool _sameContent(TypedRow current, TypedRow expected) {
    for (final entry in expected.entries) {
      if (revisionBookkeepingColumns.contains(entry.key)) continue;
      final value = current[entry.key];
      if (value == null || !value.equals(entry.value)) return false;
    }
    return true;
  }

  Future<TypedRow?> _currentRow(RawExecutor txn, RevisionChange change) async {
    final schema = await engine.tables(txn);
    final table = schema[change.table];
    if (table == null) return null;
    final rows = await selectRows(
      txn,
      table.name,
      where: '${quoteSqlName(table.primaryKey)} = ?',
      whereArgs: [change.rowKey],
      limit: 1,
    );
    return rows.isEmpty ? null : typedRow(rows.first);
  }

  /// 按反向规则写回一条变化；调用前已经核对过当前值与业务约束。
  ///
  /// “反向”是相对传进来的变化说的：撤销普通提交时写回它的旧值；撤销一条撤销
  /// 提交（重做）时，传进来的是撤销提交的反向变化，写回的就是撤销前的值。
  /// 撤销更新与撤销删除都不把 `updated_at` 写回旧值，而是写成撤销时刻：撤销
  /// 之后这一行是“现在改过”的，维护列也不参与后续撤销的后续修改核对，同一行
  /// 之后改过其他列仍可撤销。
  Future<void> _apply(RawExecutor txn, RevisionChange change) async {
    final schema = await engine.tables(txn);
    final table = schema[change.table]!;
    final primaryKey = quoteSqlName(table.primaryKey);
    switch (change.op) {
      case ChangeOp.insert:
        await deleteRows(
          txn,
          table.name,
          where: '$primaryKey = ?',
          whereArgs: [change.rowKey],
        );
      case ChangeOp.delete:
        await insertRow(txn, table.name, _undoValues(table, change.before!));
      case ChangeOp.update:
        await updateRow(
          txn,
          table.name,
          _undoValues(table, change.before!),
          where: '$primaryKey = ?',
          whereArgs: [change.rowKey],
        );
    }
  }

  /// 撤销写回的值：旧值加上写成撤销时刻的维护列。
  ///
  /// `updated_at` 这类列在任何后续写入里都会改到，写回旧值等于把这一行标成
  /// 过去修改过；写成撤销时刻与“这次动作发生在现在”一致。表里没有的维护列
  /// 不补，避免给没有该列的表拼出无效的 UPDATE。
  Map<String, Object?> _undoValues(RevisionTable table, TypedRow old) {
    final now = formatDateTime(engine.clock());
    return {
      for (final entry in sqliteRow(old).entries)
        entry.key: revisionBookkeepingColumns.contains(entry.key)
            ? now
            : entry.value,
      for (final column in revisionBookkeepingColumns)
        if (!old.containsKey(column) && table.columns.contains(column))
          column: now,
    };
  }

  /// 清掉消息里指向这次提交的回执条目，不整行回滚 `structured_json`。
  ///
  /// 撤销接受建议时一并去掉已接受的标题，建议重新出现在讨论里；撤销记忆写入
  /// 时把对应的记忆卡片放回待确认，用户可以重新决定。
  Future<void> _cleanReceipts(
    RawExecutor txn, {
    required int commitId,
    required List<RevisionChange> changes,
  }) async {
    final titlesByMessage = <String, Set<String>>{};
    final stepIdsByMessage = <String, Set<String>>{};
    for (final change in changes) {
      if (change.table != 'plan_item' || change.op != ChangeOp.insert) {
        continue;
      }
      final row = change.after;
      if (row == null) continue;
      final title = row['title']?.value;
      if (title is! String || title.trim().isEmpty) continue;
      final origin = row['origin_json']?.value;
      final messageId = _originMessageId(origin);
      if (messageId == null) continue;
      titlesByMessage.putIfAbsent(messageId, () => <String>{}).add(title);
      final stepId = _originStepId(origin);
      if (stepId != null) {
        stepIdsByMessage.putIfAbsent(messageId, () => <String>{}).add(stepId);
      }
    }
    final messageIds = <String>{
      for (final change in changes)
        if (change.table == 'message') change.rowKey,
      ...titlesByMessage.keys,
    };
    for (final messageId in messageIds) {
      final rows = await selectRows(
        txn,
        'message',
        columns: ['structured_json'],
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final payload = ChatMessagePayload.decode(
        rows.first['structured_json'] as String?,
      );
      final updated = payload?.withoutReceipts(
        commitId,
        unacceptedTitles: titlesByMessage[messageId] ?? const {},
        unacceptedStepIds: stepIdsByMessage[messageId] ?? const {},
      );
      if (updated == null) continue;
      await updateRow(
        txn,
        'message',
        {'structured_json': updated.encode()},
        where: 'id = ?',
        whereArgs: [messageId],
      );
    }
  }

  String? _originStepId(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final stepId = decoded['step_id'];
      return stepId is String && stepId.trim().isNotEmpty
          ? stepId.trim()
          : null;
    } on FormatException {
      return null;
    }
  }

  String? _originMessageId(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final id = decoded['message_id'];
      return id is String ? id : null;
    } on FormatException {
      return null;
    }
  }
}
