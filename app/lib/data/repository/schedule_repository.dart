import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';
import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import 'schedule_conflicts.dart';

class ScheduleConflictException implements Exception {
  const ScheduleConflictException({
    required this.start,
    required this.end,
    required this.description,
  });

  final DateTime start;
  final DateTime end;
  final String description;

  @override
  String toString() =>
      '安排与$description冲突（${formatDateTime(start)}–${formatDateTime(end)}）';
}

/// 一次业务操作里的单条预约调整；多条一起校验、一起写入。
class ScheduleAdjustment {
  const ScheduleAdjustment({
    required this.id,
    required this.start,
    required this.end,
  });

  final int id;
  final DateTime start;
  final DateTime end;
}

/// 课表与时间块（01 `timetable_entry` / `schedule_block`）。
class ScheduleRepository {
  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect([RawExecutor? executor]) {
    final connection = (executor ?? _db).driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

  static ScheduleBlock _blockOf({
    required int id,
    required int planItemId,
    required String startAt,
    required String endAt,
    required String source,
    required String status,
    required int locked,
  }) => ScheduleBlock(
    id: id,
    planItemId: planItemId,
    startAt: parseDateTime(startAt),
    endAt: parseDateTime(endAt),
    source: source,
    status: status,
    locked: locked == 1,
  );

  static ScheduledItem _scheduledOf(BlocksOverlappingResult r) => ScheduledItem(
    block: _blockOf(
      id: r.id,
      planItemId: r.planItemId,
      startAt: r.startAt,
      endAt: r.endAt,
      source: r.source,
      status: r.status,
      locked: r.locked,
    ),
    itemTitle: r.pTitle,
    itemNote: r.pNote,
    itemStatus: PlanItemStatus.fromCode(r.pStatus),
  );

  static ScheduledItem _scheduledOfNext(NextPlannedBlockResult r) =>
      ScheduledItem(
        block: _blockOf(
          id: r.id,
          planItemId: r.planItemId,
          startAt: r.startAt,
          endAt: r.endAt,
          source: r.source,
          status: r.status,
          locked: r.locked,
        ),
        itemTitle: r.pTitle,
        itemNote: r.pNote,
        itemStatus: PlanItemStatus.fromCode(r.pStatus),
      );

  ScheduleRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<List<TimetableEntry>> timetable() async {
    final rows = await _connect().allTimetableEntries().get();
    return rows.map(_timetableOf).toList(growable: false);
  }

  /// 新增固定课表；先核对这条每周时段与既有预约是否重叠，再写入。
  ///
  /// 新建、改期预约时查课表，新增课表时反过来查已经排好的预约，两个方向共用
  /// [findRecurringTimetableConflict] 的判断。
  Future<int> addTimetable({
    required int weekday,
    required String startTime,
    required String endTime,
    required String title,
    String? location,
  }) async {
    final at = _clock();
    return _db.transaction((txn) async {
      final conflict = await findRecurringTimetableConflict(
        txn,
        weekday: weekday,
        startTime: startTime,
        endTime: endTime,
        now: at,
      );
      if (conflict != null) throw _exceptionFor(conflict);
      return txn.insert('timetable_entry', {
        'weekday': weekday,
        'start_time': startTime,
        'end_time': endTime,
        'title': title.trim(),
        'location': location?.trim(),
        'created_at': formatDateTime(at),
        'updated_at': formatDateTime(at),
      });
    });
  }

  Future<void> deleteTimetable(int id, {RawExecutor? executor}) async {
    await (executor ?? _db).delete(
      'timetable_entry',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 一段时间内的时间块，按开始时间排序，并带上对应事项。
  Future<List<ScheduledItem>> blocksBetween(
    DateTime start,
    DateTime end,
  ) async {
    final rows = await _connect()
        .blocksOverlapping(formatDateTime(end), formatDateTime(start))
        .get();
    return [for (final row in rows) _scheduledOf(row)];
  }

  Future<ScheduledItem?> nextAfter(DateTime now) async {
    final rows = await _connect().nextPlannedBlock(formatDateTime(now)).get();
    if (rows.isEmpty) return null;
    return _scheduledOfNext(rows.first);
  }

  Future<int> addBlock({
    required int planItemId,
    required DateTime start,
    required DateTime end,
    String source = 'user',
    bool locked = false,
    RawExecutor? executor,
  }) async {
    if (executor == null) {
      return _db.transaction(
        (txn) => addBlock(
          planItemId: planItemId,
          start: start,
          end: end,
          source: source,
          locked: locked,
          executor: txn,
        ),
      );
    }
    await _ensureNoConflict(executor, start: start, end: end);
    final now = formatDateTime(_clock());
    return executor.insert('schedule_block', {
      'plan_item_id': planItemId,
      'start_at': formatDateTime(start),
      'end_at': formatDateTime(end),
      'source': source,
      'status': 'planned',
      'locked': locked ? 1 : 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 一次业务操作调整多条预约：先按目标时间整体校验，全部通过才逐条写入。
  ///
  /// 与逐条移动不同，这里允许两条预约互换时段或形成暂时冲突的中间状态；校验
  /// 只看最终结果，既不与未参与调整的预约重叠，也不与课表重叠。
  Future<void> rescheduleGroup(
    List<ScheduleAdjustment> adjustments, {
    RawExecutor? executor,
  }) async {
    if (adjustments.isEmpty) return;
    if (executor == null) {
      return _db.transaction(
        (txn) => rescheduleGroup(adjustments, executor: txn),
      );
    }
    final ids = <int>{};
    for (final adjustment in adjustments) {
      if (!ids.add(adjustment.id)) {
        throw ArgumentError('同一预约在一次操作里只能调整一次');
      }
      if (!adjustment.end.isAfter(adjustment.start)) {
        throw ArgumentError('结束时间要晚于开始时间');
      }
    }
    final existing = await _connect(executor)
        .blocksByIds(jsonEncode(ids.toList()))
        .get();
    if (existing.length != ids.length) {
      throw StateError('部分时间安排已被删除');
    }
    for (var i = 0; i < adjustments.length; i++) {
      for (var j = i + 1; j < adjustments.length; j++) {
        final left = adjustments[i];
        final right = adjustments[j];
        if (left.start.isBefore(right.end) && left.end.isAfter(right.start)) {
          throw ScheduleConflictException(
            start: left.start.isAfter(right.start) ? left.start : right.start,
            end: left.end.isBefore(right.end) ? left.end : right.end,
            description: '同一次调整中的另一条安排',
          );
        }
      }
    }

    final planned = await _connect(executor).plannedBlockSpans().get();
    for (final row in planned) {
      final id = row.id;
      if (ids.contains(id)) continue;
      final blockStart = DateTime.parse(row.startAt);
      final blockEnd = DateTime.parse(row.endAt);
      for (final adjustment in adjustments) {
        if (blockStart.isBefore(adjustment.end) &&
            blockEnd.isAfter(adjustment.start)) {
          throw ScheduleConflictException(
            start: blockStart.isAfter(adjustment.start)
                ? blockStart
                : adjustment.start,
            end: blockEnd.isBefore(adjustment.end) ? blockEnd : adjustment.end,
            description: '“${row.title}”的安排',
          );
        }
      }
    }

    for (final adjustment in adjustments) {
      await _ensureNoTimetableConflict(
        executor,
        start: adjustment.start,
        end: adjustment.end,
      );
    }

    final now = formatDateTime(_clock());
    for (final adjustment in adjustments) {
      final changed = await executor.update(
        'schedule_block',
        {
          'start_at': formatDateTime(adjustment.start),
          'end_at': formatDateTime(adjustment.end),
          'status': 'planned',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [adjustment.id],
      );
      if (changed != 1) throw StateError('时间安排已被删除');
    }
  }

  Future<void> _ensureNoTimetableConflict(
    RawExecutor executor, {
    required DateTime start,
    required DateTime end,
  }) async {
    final conflict = await findTimetableConflict(
      executor,
      start: start,
      end: end,
    );
    if (conflict != null) throw _exceptionFor(conflict);
  }

  Future<void> moveBlock(
    int id, {
    required DateTime start,
    required DateTime end,
    RawExecutor? executor,
  }) async {
    if (executor == null) {
      return _db.transaction(
        (txn) => moveBlock(id, start: start, end: end, executor: txn),
      );
    }
    final current = await _connect(executor)
        .scheduleBlockById(id)
        .getSingleOrNull();
    if (current == null) throw StateError('未找到这条时间安排');
    await _ensureNoConflict(
      executor,
      start: start,
      end: end,
      excludeBlockId: id,
    );
    final changed = await executor.update(
      'schedule_block',
      {
        'start_at': formatDateTime(start),
        'end_at': formatDateTime(end),
        'status': 'planned',
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed != 1) throw StateError('时间安排已被删除');
  }

  Future<void> _ensureNoConflict(
    RawExecutor executor, {
    required DateTime start,
    required DateTime end,
    int? excludeBlockId,
  }) async {
    final conflict = await findScheduleConflict(
      executor,
      start: start,
      end: end,
      ignoredBlockIds: {?excludeBlockId},
    );
    if (conflict != null) throw _exceptionFor(conflict);
  }

  ScheduleConflictException _exceptionFor(ScheduleConflict conflict) {
    return ScheduleConflictException(
      start: conflict.start,
      end: conflict.end,
      description: conflict.description,
    );
  }

  /// 用户把这次安排固定下来；固定的块不参加自动调整。
  Future<void> setLocked(int id, bool locked, {RawExecutor? executor}) async {
    await (executor ?? _db).update(
      'schedule_block',
      {'locked': locked ? 1 : 0, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 最近仍有效的未来时间块，按开始时间排列。
  Future<List<ScheduleBlock>> futureBlocksForItem(
    int planItemId,
    DateTime now, {
    RawExecutor? executor,
  }) async {
    final rows = await _connect(executor)
        .upcomingBlocksForItem(planItemId, formatDateTime(now))
        .get();
    return rows.map(_blockOfRow).toList(growable: false);
  }

  /// 每个事项最近一次尚未结束的预约；正在进行的预约也在结果里。
  ///
  /// 计划页与日程摘要用它在同一步骤上显示时间并改期，已经结束或取消的
  /// 时间块不再参与。
  Future<Map<int, ScheduleBlock>> nextBlocksForItems(
    Iterable<int> planItemIds,
    DateTime now,
  ) async {
    final ids = planItemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final rows = await _connect()
        .firstLiveBlockPerItem(jsonEncode(ids), formatDateTime(now))
        .get();
    final result = <int, ScheduleBlock>{};
    for (final row in rows) {
      final block = _blockOfRow(row);
      result.putIfAbsent(block.planItemId, () => block);
    }
    return result;
  }

  Future<Map<int, List<ScheduleBlock>>> futureBlocksForItems(
    Iterable<int> planItemIds,
    DateTime now,
  ) async {
    final ids = planItemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final rows = await _connect()
        .upcomingBlocksForItems(jsonEncode(ids), formatDateTime(now))
        .get();
    final result = <int, List<ScheduleBlock>>{};
    for (final row in rows) {
      final block = _blockOfRow(row);
      result.putIfAbsent(block.planItemId, () => []).add(block);
    }
    return result;
  }

  /// 目标下尚未开始的弹性预约，按开始时间排列。
  ///
  /// 暂停目标前用它确定取消范围，界面也用同一份查询说明会取消几条，固定的块
  /// 不参与；[executor] 让这段读取与后面的取消落在同一个事务里。
  Future<List<ScheduleBlock>> flexibleFutureBlocksForGoal(
    int goalId,
    DateTime now, {
    RawExecutor? executor,
  }) async {
    final rows = await _connect(executor)
        .adjustableBlocksForGoal(goalId, formatDateTime(now))
        .get();
    return [
      for (final row in rows)
        ScheduleBlock(
          id: row.id,
          planItemId: row.planItemId,
          startAt: parseDateTime(row.startAt),
          endAt: parseDateTime(row.endAt),
          source: row.source,
          status: row.status,
          locked: row.locked == 1,
        ),
    ];
  }

  /// 一次取消多条预约；只写一条语句，与同一次业务操作的其他改动一起提交。
  ///
  /// 传入的预约里只要有一条已经取消或不再存在，就报错交给外层事务回滚，
  /// 不会只改掉其中一部分。
  Future<void> cancelBlocks(Iterable<int> ids, {RawExecutor? executor}) async {
    final list = ids.toSet().toList(growable: false);
    if (list.isEmpty) return;
    if (executor == null) {
      return _db.transaction((txn) => cancelBlocks(list, executor: txn));
    }
    final placeholders = List.filled(list.length, '?').join(', ');
    final changed = await executor.update(
      'schedule_block',
      {'status': 'cancelled', 'updated_at': formatDateTime(_clock())},
      where: "id IN ($placeholders) AND status = 'planned'",
      whereArgs: list,
    );
    if (changed != list.length) {
      throw StateError('部分时间安排已取消或不存在');
    }
  }

  /// 改预约状态；恢复为待开始时同样核对时间占用，避免绕开新建与改期的限制。
  Future<void> setBlockStatus(
    int id,
    String status, {
    RawExecutor? executor,
  }) async {
    if (executor == null) {
      return _db.transaction(
        (txn) => setBlockStatus(id, status, executor: txn),
      );
    }
    if (status == 'planned') {
      final block = await _connect(executor)
          .scheduleBlockById(id)
          .getSingleOrNull();
      if (block == null) throw StateError('未找到这条时间安排');
      await _ensureNoConflict(
        executor,
        start: DateTime.parse(block.startAt),
        end: DateTime.parse(block.endAt),
        excludeBlockId: id,
      );
    }
    await executor.update(
      'schedule_block',
      {'status': status, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteBlock(int id, {RawExecutor? executor}) async {
    await (executor ?? _db).delete(
      'schedule_block',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<ScheduleBlock?> blockById(int id) async {
    final row = await _connect().scheduleBlockById(id).getSingleOrNull();
    return row == null ? null : _blockOfRow(row);
  }

  Future<List<ScheduleBlock>> blocksForItem(int planItemId) async {
    final rows = await _connect().blocksForItem(planItemId).get();
    return rows.map(_blockOfRow).toList(growable: false);
  }

  /// 时间安排表的字段与领域模型同名，只补时间解析与锁定标记。
  static ScheduleBlock _blockOfRow(ScheduleBlockRow row) => ScheduleBlock(
    id: row.id,
    planItemId: row.planItemId,
    startAt: parseDateTime(row.startAt),
    endAt: parseDateTime(row.endAt),
    source: row.source,
    status: row.status,
    locked: row.locked == 1,
  );

  /// 课表行的字段与领域模型同名，只补地点。
  static TimetableEntry _timetableOf(TimetableEntryRow row) => TimetableEntry(
    id: row.id,
    weekday: row.weekday,
    startTime: row.startTime,
    endTime: row.endTime,
    title: row.title,
    location: row.location,
  );
}
