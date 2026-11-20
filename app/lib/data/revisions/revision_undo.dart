import 'dart:convert';

import '../db/raw_executor.dart';
import '../db/sql.dart';

import '../repository/schedule_conflicts.dart';
import '../../domain/models/chat_message_payload.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import 'revision_actions.dart';
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
/// 数据层只做通用核对（代次、后续修改、当前值、白名单）；预约冲突、学习事项
/// 归属与课表这三类规则由实现方注册，阶段 0 的实现在数据层，之后移到
/// `lib/application/undo_guards/`（ADR-0039 第 3.4 节）。
abstract interface class UndoGuard {
  /// 这个 guard 负责的表。
  Set<String> get tables;

  /// 只对指定动作开放的表，例如更正材料页同一条提交里的材料行。
  Map<String, Set<String>> get actionTables;

  /// 恢复后不成立时返回不能撤销的原因，成立时返回空。
  Future<String?> check(UndoCheck check);
}

/// 预约冲突：撤销更新与撤销删除要核对恢复后的时间是否仍可执行。
class ScheduleUndoGuard implements UndoGuard {
  const ScheduleUndoGuard();

  @override
  Set<String> get tables => const {'schedule_block'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    // 撤销新增会删除预约，不需要再检查占用；撤销更新与撤销删除都要核对
    // 恢复后的时间是否仍可执行。
    if (change.op == ChangeOp.insert) return null;
    final row = change.op == ChangeOp.delete
        ? change.before!
        : _merged(current!, change.before!);
    final status = row['status']?.value as String? ?? 'planned';
    final start = row['start_at']?.value as String?;
    final end = row['end_at']?.value as String?;
    final planItemId = row['plan_item_id']?.value as String?;
    if (start == null || end == null || planItemId == null) {
      return '预约内容不完整，不能撤销';
    }
    final item = await selectRows(
      check.executor,
      'plan_item',
      columns: ['id', 'status', 'goal_id'],
      where: 'id = ?',
      whereArgs: [planItemId],
      limit: 1,
    );
    if (item.isEmpty) return '预约对应的学习事项已经不存在';
    final itemStatus = item.first['status'] as String?;
    if ((itemStatus == 'done' || itemStatus == 'deferred') &&
        !_restoresStatus(check.commitChanges, 'plan_item', change.rowKey)) {
      return '预约对应的学习事项已经完成或暂缓，不再恢复这条预约';
    }
    final goalId = item.first['goal_id'] as String?;
    if (goalId != null) {
      final goals = await selectRows(
        check.executor,
        'learning_goal',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [goalId],
        limit: 1,
      );
      final goalStatus = goals.isEmpty
          ? null
          : goals.first['status'] as String?;
      if (goalStatus != null &&
          goalStatus != 'active' &&
          !_restoresStatus(check.commitChanges, 'learning_goal', goalId)) {
        return '预约对应的学习目标已经暂停或结束，不再恢复这条预约';
      }
    }
    if (status != 'planned') return null;

    final DateTime? startAt;
    final DateTime? endAt;
    try {
      startAt = optionalDateTime(start);
      endAt = optionalDateTime(end);
    } on FormatException {
      return '预约时间不完整，不能撤销';
    }
    if (startAt == null || endAt == null || !endAt.isAfter(startAt)) {
      return '预约时间不完整，不能撤销';
    }
    final conflict = await findScheduleConflict(
      check.executor,
      start: startAt,
      end: endAt,
      ignoredBlockIds: {change.rowKey},
    );
    if (conflict != null) {
      return '恢复后的时间与${conflict.description}冲突';
    }
    return null;
  }
}

/// 学习事项的撤销要避开级联删除后续数据。
///
/// 撤销新建会删除这项事项，已有预约、学习场次或系统学习计划归属时不删；
/// 撤销删除会重新插入，原来的目标、讨论或计划已经不存在时不插。
class PlanItemUndoGuard implements UndoGuard {
  const PlanItemUndoGuard();

  @override
  Set<String> get tables => const {'plan_item'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    if (change.op == ChangeOp.insert) {
      if (current == null) return null;
      final planId = current['study_plan_id'];
      if (planId != null && !planId.isNull) {
        return '这项任务已归入系统学习计划，不能撤销';
      }
      final blocks = await selectRows(
        check.executor,
        'schedule_block',
        columns: ['id'],
        where: 'plan_item_id = ?',
        whereArgs: [change.rowKey],
        limit: 1,
      );
      if (blocks.isNotEmpty) return '这项任务已有预约，不能撤销';
      final sessions = await selectRows(
        check.executor,
        'study_session',
        columns: ['id'],
        where: 'plan_item_id = ?',
        whereArgs: [change.rowKey],
        limit: 1,
      );
      if (sessions.isNotEmpty) return '这项任务已有学习记录，不能撤销';
      return null;
    }
    if (change.op == ChangeOp.delete) {
      final row = change.before!;
      final references = <(String table, RevisionValue?)>[
        ('learning_goal', row['goal_id']),
        ('conversation', row['conversation_id']),
        ('study_plan', row['study_plan_id']),
      ];
      for (final (table, value) in references) {
        if (value == null || value.isNull) continue;
        final rows = await selectRows(
          check.executor,
          table,
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [value.value],
          limit: 1,
        );
        if (rows.isEmpty) {
          return '这项任务原来归属的目标、讨论或计划已经不存在，不能撤销删除';
        }
      }
    }
    return null;
  }
}

/// 课表：撤销删除会把这一节课重新加回每周课表，先核对现有待开始预约。
///
/// 新增课表本来就会反向查预约（2026-11-11 判例），撤销删除也要走同一份规则；
/// 撤销新增只是删除课表，不需要检查。
class TimetableUndoGuard implements UndoGuard {
  const TimetableUndoGuard();

  @override
  Set<String> get tables => const {'timetable_entry'};

  @override
  Map<String, Set<String>> get actionTables => const {};

  @override
  Future<String?> check(UndoCheck check) async {
    final change = check.change;
    final current = check.current;
    if (change.op == ChangeOp.insert) return null;
    final row = change.op == ChangeOp.delete
        ? change.before!
        : _merged(current!, change.before!);
    final weekday = row['weekday']?.value as int?;
    final start = row['start_time']?.value as String?;
    final end = row['end_time']?.value as String?;
    if (weekday == null || start == null || end == null) {
      return '课表内容不完整，不能撤销';
    }
    final conflict = await findRecurringTimetableConflict(
      check.executor,
      weekday: weekday,
      startTime: start,
      endTime: end,
      now: check.clock(),
    );
    if (conflict != null) {
      return '恢复课表后的时间与${conflict.description}冲突';
    }
    return null;
  }
}

/// 默认注册的三条业务约束；应用层可以按同一接口替换或追加。
const List<UndoGuard> defaultUndoGuards = [
  ScheduleUndoGuard(),
  PlanItemUndoGuard(),
  TimetableUndoGuard(),
];

/// 单项撤销：由业务动作给出反向规则，在同一个事务里核对后续修改、当前值、
/// 依赖与约束，全部通过才整组写回，并追加一条撤销提交。
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
    this.clock = systemClock,
    this.guards = defaultUndoGuards,
  });

  final RevisionEngine engine;
  final Clock clock;
  final List<UndoGuard> guards;

  static const Set<String> _allowedTables = {
    'learning_goal',
    'schedule_block',
    'timetable_entry',
    'memory',
    'plan_item',
    'message',
    'material_page',
    'profile',
  };

  /// 更正材料页会在同一条提交里更新材料行的 `updated_at`；这一行只随
  /// “更正材料页”一起撤销，新增一页、调整归属等动作仍不开放单项撤销。
  static const Map<String, Set<String>> _actionTables = {
    correctMaterialPageAction: {'material'},
    // 确认作答记忆同时把帮助里的建议标为已写入；撤销时这条 update 要一起回放，
    // 建议才会回到待确认。
    confirmAttemptMemoryAction: {'attempt'},
  };

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
      final reverted = await _revertedTargets(txn);
      final changes = await engine.changesFor(txn, commitId);
      final blocked = _blockedReason(
        target: target,
        headGeneration: head.generation,
        reverted: reverted.contains(commitId),
        changes: changes,
      );
      if (blocked != null) {
        return RevisionUndoResult(applied: false, message: blocked);
      }

      final changeRows = [
        for (final change in changes)
          if (change.table != 'message') change,
      ];
      final conflict = await _validate(txn, target, changeRows);
      if (conflict != null) {
        return RevisionUndoResult(applied: false, message: conflict);
      }

      await engine.beginCommand(txn);
      for (final change in changeRows) {
        await _apply(txn, change);
      }
      await _cleanReceipts(txn, commitId: commitId, changes: changes);
      final commit = await engine.finishCommand(
        txn,
        action: '撤销操作',
        actor: 'user',
        kind: RevisionKind.undo,
        revertedCommitId: commitId,
      );
      if (commit == null) {
        return const RevisionUndoResult(applied: false, message: '没有产生需要写入的变化');
      }
      // 撤销之后这次动作不再是有效提交，释放它的请求编号：用户重新做同一个
      // 动作时按新动作处理，不会被当成重试，也不会撞上 request_id 的唯一索引。
      if (target.requestId != null) {
        await updateRow(
          txn,
          'revision_commit',
          {'request_id': null},
          where: 'id = ?',
          whereArgs: [commitId],
        );
      }
      return RevisionUndoResult(
        applied: true,
        message: '已撤销这次操作',
        commit: commit,
      );
    });
  }

  /// 提交列表用的判断：同一套白名单、代次与撤销范围，给出每条提交不能撤销
  /// 的原因；值为 null 表示结构上可以撤销，当前值与后续修改仍在撤销时核对。
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
    final reverted = await _revertedTargets(executor);
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
    return {
      for (final commit in list)
        commit.id: _blockedReason(
          target: commit,
          headGeneration: head.generation,
          reverted: reverted.contains(commit.id),
          changes: changesByCommit[commit.id] ?? const [],
        ),
    };
  }

  Future<Set<int>> _revertedTargets(RawExecutor executor) async {
    final rows = await selectRows(
      executor,
      'revision_commit',
      columns: ['reverted_commit_id'],
      where: 'reverted_commit_id IS NOT NULL',
    );
    return {for (final row in rows) row['reverted_commit_id']! as int};
  }

  /// 撤销前的结构判断；单项撤销与提交列表共用这一份规则。
  String? _blockedReason({
    required RevisionCommit target,
    required int headGeneration,
    required bool reverted,
    required List<RevisionChange> changes,
  }) {
    if (target.isBaseline) return '找不到要撤销的提交';
    if (target.generation != headGeneration) {
      return '整版恢复或导入之后，不能撤销更早的提交';
    }
    if (target.isUndo) {
      // 撤销提交里的回执清理是定向改写的，反向回放无法把消息里的回执
      // 完整装回去，因此把撤销操作本身排除在撤销范围外；需要回到更早的
      // 状态时用整版恢复。
      return '撤销提交本身不能再撤销，需要回到更早的状态请用整版恢复';
    }
    if (reverted) return '这次操作已经撤销';
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
      ...?_actionTables[target.action],
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

  Future<String?> _validate(
    RawExecutor txn,
    RevisionCommit target,
    List<RevisionChange> changes,
  ) async {
    for (final change in changes) {
      final later = await _laterChanges(txn, target.id, change);
      if (later.isNotEmpty) {
        return '这次操作之后，同一项内容又被修改过，不能撤销';
      }

      final current = await _currentRow(txn, change);
      switch (change.op) {
        case ChangeOp.insert:
          if (current == null) return '要撤销的新增内容已经不存在';
          if (!typedRowsEqual(current, change.after!)) {
            return '新增之后内容又有变化，不能撤销';
          }
        case ChangeOp.delete:
          if (current != null) return '要撤销的删除位置已经有新内容';
        case ChangeOp.update:
          if (current == null) return '要撤销的内容已经不存在';
          for (final entry in change.after!.entries) {
            final value = current[entry.key];
            if (value == null || !value.equals(entry.value)) {
              return '要撤销的内容已经不是原来的样子';
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

  Future<List<RevisionChange>> _laterChanges(
    RawExecutor txn,
    int commitId,
    RevisionChange target,
  ) async {
    final rows = await selectRows(
      txn,
      'revision_change',
      where: 'commit_id > ? AND table_name = ? AND row_key = ?',
      whereArgs: [commitId, target.table, target.rowKey],
      orderBy: 'commit_id, seq',
    );
    final result = <RevisionChange>[];
    for (final row in rows) {
      final change = RevisionChange.fromRow(row);
      final targetColumns = <String>{
        ...?target.after?.keys,
        ...?target.before?.keys,
      };
      if (target.op != ChangeOp.update) {
        result.add(change);
        continue;
      }
      final columns = <String>{...?change.after?.keys, ...?change.before?.keys};
      if (targetColumns.intersection(columns).isNotEmpty) {
        result.add(change);
      }
    }
    return result;
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

  /// 按反向规则写回一行；调用前已经核对过当前值与业务约束。
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
        await insertRow(txn, table.name, sqliteRow(change.before!));
      case ChangeOp.update:
        await updateRow(
          txn,
          table.name,
          sqliteRow(change.before!),
          where: '$primaryKey = ?',
          whereArgs: [change.rowKey],
        );
    }
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

TypedRow _merged(TypedRow current, TypedRow after) => {
  ...current,
  for (final entry in after.entries) entry.key: entry.value,
};

/// 同一条提交是否会把事项或目标恢复为可以继续安排的状态。
bool _restoresStatus(
  List<RevisionChange> changes,
  String table,
  String rowKey,
) {
  for (final change in changes) {
    if (change.table != table ||
        change.rowKey != rowKey ||
        change.op != ChangeOp.update) {
      continue;
    }
    final status = change.before?['status']?.value;
    if (table == 'learning_goal' && status == 'active') return true;
    if (table == 'plan_item' && (status == 'todo' || status == 'doing')) {
      return true;
    }
  }
  return false;
}
