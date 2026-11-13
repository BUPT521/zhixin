/// 按截止时间分配可用时段的纯函数（01 `plan_item`、`schedule_block`）。
///
/// 这里回答的问题是：在每一项自己的截止时间之前，是否还有足够空档，以及
/// 分到的是哪几段。分配按截止时间从早到晚进行，同一截止时间按传入顺序；
/// 没有截止时间的项使用整个窗口，排在最后。分到的各段互不重叠，可以直接
/// 作为预约时的候选时间；写入仍由用户点选其中一段后发生。
library;

/// 一段可用时间。
class CapacitySlot {
  const CapacitySlot({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  int get minutes => end.difference(start).inMinutes;
}

/// 一项待安排事项：需要的分钟数与截止时间。
class CapacityDemand {
  const CapacityDemand({required this.id, required this.minutes, this.dueAt});

  final int id;
  final int minutes;
  final DateTime? dueAt;
}

/// 一项需求分到的时间。
class CapacityFit {
  const CapacityFit({
    required this.id,
    required this.minutes,
    required this.allocated,
    this.windows = const [],
  });

  final int id;
  final int minutes;
  final int allocated;

  /// 分配到的具体空档，按开始时间排列，合计等于 [allocated]。
  ///
  /// 每一项只取自己截止时间之前的空档，因此这些时段不会与排在前面的事项
  /// 重合；时长不足 [minutes] 时，最后一段只到截止时间为止。
  final List<({DateTime start, DateTime end})> windows;

  bool get fits => allocated >= minutes;
  int get shortfall => minutes - allocated;
}

/// 把 [slots] 按截止时间分给 [demands]，返回与 [demands] 同序的结果。
///
/// 每一项只使用自己截止时间之前的空档，已经分出的时间不再重复使用，
/// 因此晚到期的事项不会占用早到期事项还需要的时间。截止时间以
/// [horizonEnd] 封顶；截止时间早于 [now] 的事项分不到时间。
List<CapacityFit> fitByDeadline({
  required List<CapacitySlot> slots,
  required List<CapacityDemand> demands,
  required DateTime now,
  required DateTime horizonEnd,
}) {
  final remaining = <_SlotCursor>[
    for (final slot in slots)
      if (slot.end.isAfter(now))
        _SlotCursor(
          start: slot.start.isBefore(now) ? now : slot.start,
          end: slot.end,
        ),
  ]..sort((a, b) => a.start.compareTo(b.start));

  final ordered =
      <({int index, CapacityDemand demand})>[
        for (var index = 0; index < demands.length; index++)
          (index: index, demand: demands[index]),
      ]..sort((a, b) {
        final left = a.demand.dueAt ?? horizonEnd;
        final right = b.demand.dueAt ?? horizonEnd;
        final byDue = left.compareTo(right);
        return byDue != 0 ? byDue : a.index.compareTo(b.index);
      });

  final allocatedById = <int, int>{};
  final windowsById = <int, List<({DateTime start, DateTime end})>>{};
  for (final entry in ordered) {
    final demand = entry.demand;
    final due = demand.dueAt;
    final deadline = due == null || due.isAfter(horizonEnd) ? horizonEnd : due;
    final wanted = demand.minutes < 0 ? 0 : demand.minutes;
    var allocated = 0;
    final windows = <({DateTime start, DateTime end})>[];
    for (final slot in remaining) {
      if (allocated >= wanted) break;
      final end = slot.end.isBefore(deadline) ? slot.end : deadline;
      final available = end.difference(slot.cursor).inMinutes;
      if (available <= 0) continue;
      final use = available < wanted - allocated
          ? available
          : wanted - allocated;
      windows.add((
        start: slot.cursor,
        end: slot.cursor.add(Duration(minutes: use)),
      ));
      allocated += use;
      slot.cursor = slot.cursor.add(Duration(minutes: use));
    }
    allocatedById[demand.id] = allocated;
    windowsById[demand.id] = windows;
  }

  return [
    for (final demand in demands)
      CapacityFit(
        id: demand.id,
        minutes: demand.minutes,
        allocated: allocatedById[demand.id] ?? 0,
        windows: windowsById[demand.id] ?? const [],
      ),
  ];
}

class _SlotCursor {
  _SlotCursor({required this.start, required this.end}) : cursor = start;

  final DateTime start;
  final DateTime end;
  DateTime cursor;
}
