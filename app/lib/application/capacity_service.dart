import '../data/db/write_transactions.dart';
import '../data/repository/schedule_repository.dart';
import '../data/repository/settings_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/capacity.dart';
import '../domain/models/study.dart';
import '../domain/rules/capacity_budget.dart';
import 'service_runtime.dart';

/// 一段自由时间。
class _Slot {
  const _Slot(this.start, this.end);

  final DateTime start;
  final DateTime end;

  int get minutes => end.difference(start).inMinutes;
}

/// 容量预估：按常用时段估算可用时间，给出优先顺序、粗略预算与可预约空档。
///
/// 估时来自事项填写，未填写时只用默认值占位，实际用时未必可靠；因此这一层
/// 只给出顺序、预算与算好的空档，不写入任何时间块。用户点选其中一段空档后，
/// 再由 [book] 新建或改期该事项的时间块，其他事项与固定安排保持原样。
class CapacityService {
  CapacityService({
    required this.settings,
    required this.tasks,
    required this.schedule,
    required this.runtime,
    required this.transactions,
  });

  final SettingsRepository settings;
  final TaskRepository tasks;
  final ScheduleRepository schedule;
  final ServiceRuntime runtime;

  /// 点选空档也是一次业务写入；提交编号随预约一起回到界面，用于撤销。
  final WriteTransactions transactions;

  static const String windowStartKey = 'capacity_window_start';
  static const String windowEndKey = 'capacity_window_end';
  static const String defaultWindowStart = '19:00';
  static const String defaultWindowEnd = '21:30';
  static const int defaultEstimateMinutes = 20;

  Future<({String start, String end})> window() async {
    final start = await settings.metadata(windowStartKey) ?? defaultWindowStart;
    final end = await settings.metadata(windowEndKey) ?? defaultWindowEnd;
    return (start: start, end: end);
  }

  Future<void> setWindow({required String start, required String end}) async {
    if (_minutesOf(start) == null || _minutesOf(end) == null) {
      throw ArgumentError('时间格式应为 HH:MM');
    }
    if (_minutesOf(end)! <= _minutesOf(start)!) {
      throw ArgumentError('结束时间要晚于开始时间');
    }
    await settings.setMetadata(windowStartKey, start, runtime.policy.now);
    await settings.setMetadata(windowEndKey, end, runtime.policy.now);
  }

  /// 按当前自然周计算：从今天到本周日，入口用“这周能做什么”时不再把
  /// 下周一以后的时间算进本周预算。
  Future<CapacityPlan> computeThisWeek({int? goalId}) {
    final now = runtime.policy.now;
    final today = DateTime(now.year, now.month, now.day);
    final week = runtime.policy.naturalWeekRange(now);
    final remaining = week.endExclusive.difference(today).inDays;
    final days = remaining < 1 ? 1 : (remaining > 7 ? 7 : remaining);
    return compute(days: days, goalId: goalId);
  }

  /// 按常用时段估算可用时间，并给出事项的优先顺序与粗略预算。
  Future<CapacityPlan> compute({
    int days = 7,
    int? goalId,
    String? windowStart,
    String? windowEnd,
  }) async {
    final current = runtime.policy;
    final now = current.now;
    final stored = await window();
    final startClock = windowStart ?? stored.start;
    final endClock = windowEnd ?? stored.end;
    final startMinutes = _minutesOf(startClock) ?? 19 * 60;
    final endMinutes = _minutesOf(endClock) ?? 21 * 60 + 30;
    final today = DateTime(now.year, now.month, now.day);
    final rangeEnd = today.add(Duration(days: days));

    final entries = await schedule.timetable();
    final blocks = await schedule.blocksBetween(today, rangeEnd);
    final open = await tasks.items(openOnly: true, onlyActiveGoals: true);
    final ordered =
        open.where((item) => goalId == null || item.goalId == goalId).toList()
          ..sort(_compareItems);
    final futureByItem = await schedule.futureBlocksForItems(
      ordered.map((item) => item.id),
      now,
    );

    final candidates = <CapacityCandidate>[];
    final skipped = <CapacitySkip>[];
    final movableIds = <int>{};
    for (final item in ordered) {
      final future = futureByItem[item.id] ?? const <ScheduleBlock>[];
      if (future.any((block) => block.locked)) {
        skipped.add(
          CapacitySkip(item: item, reason: '已有固定安排，时间保持原样', fixed: true),
        );
        continue;
      }
      if (future.length > 1) {
        final scheduled = future.fold<int>(
          0,
          (sum, block) => sum + block.endAt.difference(block.startAt).inMinutes,
        );
        final remaining = (_minutes(item) - scheduled).clamp(0, 240);
        if (remaining == 0) {
          skipped.add(
            CapacitySkip(item: item, reason: '已有预约覆盖了这项的全部估时，保留现有时间'),
          );
          continue;
        }
        candidates.add(
          CapacityCandidate(
            item: item,
            minutes: remaining,
            scheduledMinutes: scheduled,
            hasEstimate: item.estMinutes != null,
            withinBudget: false,
            movableBlockId: null,
            movableStart: null,
            movableEnd: null,
          ),
        );
        continue;
      }
      final movable = future.length == 1 ? future.single : null;
      if (movable != null) movableIds.add(movable.id);
      final minutes = _minutes(item);
      candidates.add(
        CapacityCandidate(
          item: item,
          minutes: minutes,
          hasEstimate: item.estMinutes != null,
          withinBudget: false,
          movableBlockId: movable?.id,
          movableStart: movable?.startAt,
          movableEnd: movable?.endAt,
        ),
      );
    }

    final slots = <_Slot>[];
    for (var offset = 0; offset < days; offset++) {
      final day = today.add(Duration(days: offset));
      var start = DateTime(
        day.year,
        day.month,
        day.day,
        startMinutes ~/ 60,
        startMinutes % 60,
      );
      final end = DateTime(
        day.year,
        day.month,
        day.day,
        endMinutes ~/ 60,
        endMinutes % 60,
      );
      if (!end.isAfter(start)) continue;
      if (!start.isAfter(now)) {
        start = _roundUp(now, 5);
      }
      if (end.difference(start).inMinutes < 10) continue;

      final occupied = <_Slot>[];
      for (final entry in entries.where(
        (entry) => entry.weekday == day.weekday,
      )) {
        final from = _clockMinutes(entry.startTime);
        final to = _clockMinutes(entry.endTime);
        if (from == null || to == null) continue;
        occupied.add(
          _Slot(
            DateTime(day.year, day.month, day.day, from ~/ 60, from % 60),
            DateTime(day.year, day.month, day.day, to ~/ 60, to % 60),
          ),
        );
      }
      for (final block in blocks) {
        if (block.block.status != 'planned' ||
            movableIds.contains(block.block.id)) {
          continue;
        }
        final itemStart = block.block.startAt;
        final itemEnd = block.block.endAt;
        if (itemEnd.isBefore(day) ||
            !itemStart.isBefore(day.add(const Duration(days: 1)))) {
          continue;
        }
        occupied.add(_Slot(itemStart, itemEnd));
      }
      slots.addAll(_subtract(occupied, start, end));
    }

    final available = slots.fold<int>(0, (sum, slot) => sum + slot.minutes);
    final fits = fitByDeadline(
      slots: [
        for (final slot in slots)
          CapacitySlot(start: slot.start, end: slot.end),
      ],
      demands: [
        for (final candidate in candidates)
          CapacityDemand(
            id: candidate.item.id,
            minutes: candidate.minutes,
            dueAt: candidate.item.dueAt,
          ),
      ],
      now: now,
      horizonEnd: rangeEnd,
    );
    final fitsById = {for (final fit in fits) fit.id: fit};
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final fit = fitsById[candidate.item.id];
      candidates[index] = CapacityCandidate(
        item: candidate.item,
        minutes: candidate.minutes,
        scheduledMinutes: candidate.scheduledMinutes,
        hasEstimate: candidate.hasEstimate,
        withinBudget: fit != null && fit.fits,
        windows: [
          for (final window in fit?.windows ?? const [])
            CapacityWindow(start: window.start, end: window.end),
        ],
        movableBlockId: candidate.movableBlockId,
        movableStart: candidate.movableStart,
        movableEnd: candidate.movableEnd,
      );
    }

    final demand = candidates.fold<int>(0, (sum, item) => sum + item.minutes);
    final complete = candidates.where((item) => item.withinBudget).toList();
    final partial = candidates
        .where((item) => !item.withinBudget && item.plannedMinutes > 0)
        .toList();
    final withoutSlot = candidates
        .where((item) => item.plannedMinutes == 0)
        .toList();

    final notes = <String>[];
    if (partial.isNotEmpty) {
      final first = partial.first;
      final left = first.minutes - first.plannedMinutes;
      notes.add(
        complete.isEmpty
            ? '按这个时段估算，时间不够完整做完任何一项；可以先做「${first.item.title}」'
                  '${first.plannedMinutes} 分钟，还差 $left 分钟，其余事项需要缩小范围或改期。'
            : '按这个时段估算，可以先完整做完 ${complete.length} 项；'
                  '「${first.item.title}」只能先做 ${first.plannedMinutes} 分钟，还差 $left 分钟，'
                  '其余事项需要缩小范围或改期。',
      );
    } else if (complete.isNotEmpty && demand > available) {
      notes.add('按这个时段估算，可以先完整做完 ${complete.length} 项，其余事项需要缩小范围或改期。');
    } else if (complete.isEmpty && candidates.isNotEmpty) {
      notes.add('按这个时段估算，这些事项在截止时间之前都没有可用空档，需要缩小范围或改期。');
    }
    if (withoutSlot.isNotEmpty && demand <= available && complete.isNotEmpty) {
      notes.add(
        withoutSlot.length == 1
            ? '「${withoutSlot.single.item.title}」在截止时间之前没有可用空档，需要改期或缩短估时。'
            : '「${withoutSlot.first.item.title}」等 ${withoutSlot.length} 项在截止时间之前没有可用空档，'
                  '需要改期或缩短估时。',
      );
    }
    final noEstimate = candidates.where((item) => !item.hasEstimate).length;
    if (noEstimate > 0) {
      notes.add(
        '$noEstimate 项没有估时，预算按每项 $defaultEstimateMinutes 分钟计算，实际用时可能不同。',
      );
    }
    final fixedCount = skipped.where((skip) => skip.fixed).length;
    if (fixedCount > 0) {
      notes.add('$fixedCount 项已有固定安排，时间保持原样。');
    }
    notes.add(
      '可用时间按每天 $startClock–$endClock 估算，课表和保留的已排时间已扣除；'
      '预算按每项截止时间之前的空档核算，晚到期的事项不会占用早到期事项的时间；'
      '本次可调整的弹性安排会重新计算，列出的空档互不重叠，点选其中一段就是这次的预约时间。',
    );

    return CapacityPlan(
      from: today,
      days: days,
      availableMinutes: available,
      demandMinutes: demand,
      candidates: candidates,
      skipped: skipped,
      notes: notes,
      windowStart: startClock,
      windowEnd: endClock,
    );
  }

  /// 为用户选定的事项预约时间：已有可调整的弹性块时改期，否则新建。
  ///
  /// [append] 为真时保留已有的弹性块，为同一事项再加一段；界面在已有预约时
  /// 同时给出“改到”和“再加一段”两个选择。确认时在写事务里重查事项、目标、
  /// 原预约与时间冲突，预览之后状态变了就拒绝写入，不把旧方案落库。
  /// [expectedBlockId] 是预览时看到的可调整预约，[expectedBlockStart] 与
  /// [expectedBlockEnd] 是它当时的时间；[expectedNone] 表示预览时这一项还没有
  /// 任何预约；三者用来辨认状态是否已经变化。
  Future<({int blockId, int commitId})> book({
    required PlanItem item,
    required DateTime start,
    required DateTime end,
    bool append = false,
    int? expectedBlockId,
    DateTime? expectedBlockStart,
    DateTime? expectedBlockEnd,
    bool expectedNone = false,
  }) async {
    if (!end.isAfter(start)) throw ArgumentError('结束时间要晚于开始时间');
    final now = runtime.policy.now;
    return transactions.run((txn) async {
      final current = await tasks.byId(item.id, transaction: txn);
      if (current == null) throw StateError('这个事项已经被删除，请重新估算');
      if (!current.open) throw StateError('这个事项已经完成或暂缓，请重新估算');
      final goalId = current.goalId;
      if (goalId != null) {
        final goal = await tasks.goalById(goalId, transaction: txn);
        if (goal == null || !goal.active) {
          throw StateError('这个事项所属目标已暂停或结束，请先恢复目标');
        }
      }
      final future = await schedule.futureBlocksForItem(
        current.id,
        now,
        executor: txn.executor,
      );
      if (future.any((block) => block.locked)) {
        throw StateError('这个事项已有固定安排，请先调整原安排');
      }
      if (expectedNone && future.isNotEmpty) {
        throw StateError('这项已经有新的预约，请重新估算后再选');
      }
      if (expectedBlockId != null) {
        final expected = future.where((block) => block.id == expectedBlockId);
        if (future.length != 1 || expected.isEmpty) {
          throw StateError('原预约已经变化，请重新估算后再选');
        }
        final block = expected.single;
        if ((expectedBlockStart != null &&
                block.startAt != expectedBlockStart) ||
            (expectedBlockEnd != null && block.endAt != expectedBlockEnd)) {
          throw StateError('原预约时间已经变化，请重新估算后再选');
        }
      }
      if (append || future.length > 1) {
        final blockId = await schedule.addBlock(
          planItemId: current.id,
          start: start,
          end: end,
          executor: txn.executor,
        );
        return (blockId: blockId, commitId: await txn.requireCommitId());
      }
      final movable = future.firstOrNull;
      if (movable != null) {
        await schedule.moveBlock(
          movable.id,
          start: start,
          end: end,
          executor: txn.executor,
        );
        return (blockId: movable.id, commitId: await txn.requireCommitId());
      }
      final blockId = await schedule.addBlock(
        planItemId: current.id,
        start: start,
        end: end,
        executor: txn.executor,
      );
      return (blockId: blockId, commitId: await txn.requireCommitId());
    }, label: append ? '追加一段预约' : '按空档预约');
  }

  static int _compareItems(PlanItem a, PlanItem b) {
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    final aDue = a.dueAt;
    final bDue = b.dueAt;
    if (aDue != null && bDue != null) {
      final byDue = aDue.compareTo(bDue);
      if (byDue != 0) return byDue;
    } else if (aDue != null) {
      return -1;
    } else if (bDue != null) {
      return 1;
    }
    return a.id.compareTo(b.id);
  }

  static int _minutes(PlanItem item) {
    final value = item.estMinutes ?? defaultEstimateMinutes;
    return value.clamp(5, 240);
  }

  static List<_Slot> _subtract(
    List<_Slot> occupied,
    DateTime start,
    DateTime end,
  ) {
    final clipped = <_Slot>[];
    for (final slot in occupied) {
      final from = slot.start.isBefore(start) ? start : slot.start;
      final to = slot.end.isAfter(end) ? end : slot.end;
      if (to.isAfter(from)) clipped.add(_Slot(from, to));
    }
    clipped.sort((a, b) => a.start.compareTo(b.start));
    final result = <_Slot>[];
    var cursor = start;
    for (final slot in clipped) {
      if (slot.start.isAfter(cursor)) {
        final to = slot.start.isBefore(end) ? slot.start : end;
        if (to.difference(cursor).inMinutes >= 10) {
          result.add(_Slot(cursor, to));
        }
      }
      if (slot.end.isAfter(cursor)) cursor = slot.end;
      if (!cursor.isBefore(end)) break;
    }
    if (cursor.isBefore(end) && end.difference(cursor).inMinutes >= 10) {
      result.add(_Slot(cursor, end));
    }
    return result;
  }

  static DateTime _roundUp(DateTime time, int minutes) {
    final remainder = time.minute % minutes;
    final add = remainder == 0 ? 0 : minutes - remainder;
    return DateTime(
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute + add,
    );
  }

  static int? _minutesOf(String clock) {
    final parts = clock.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static int? _clockMinutes(String clock) => _minutesOf(clock);
}
