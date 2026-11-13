/// 容量规划的结果（01 `plan_item`、`schedule_block`）。
library;

import 'study.dart';

/// 本次预算里的一项候选学习事项。
class CapacityCandidate {
  const CapacityCandidate({
    required this.item,
    required this.minutes,
    required this.hasEstimate,
    required this.withinBudget,
    this.scheduledMinutes = 0,
    this.windows = const [],
    this.movableBlockId,
    this.movableStart,
    this.movableEnd,
  });

  final PlanItem item;

  /// 本次预算还要安排的分钟数：已有多个弹性预约时，扣掉这些预约覆盖的部分。
  final int minutes;

  /// 已经写在日程里的分钟数；只用于说明，不重复计入需求。
  final int scheduledMinutes;

  /// 事项是否由用户填写了估时；未填写时 [minutes] 只是预算占位。
  final bool hasEstimate;

  /// 按累计时间是否仍落在可用时间内，也就是能否完整做完。
  final bool withinBudget;

  /// 本次算给这项的空档，可以直接作为预约时间；为空表示截止时间之前没有空档。
  final List<CapacityWindow> windows;

  /// 已经存在且可调整的弹性块；为空表示预约时新建。
  final int? movableBlockId;

  /// 可调整的弹性块原来的时间；点选空档前用它说明这次会从哪里改到哪里。
  final DateTime? movableStart;
  final DateTime? movableEnd;

  /// 本次能安排给这项的分钟数；小于 [minutes] 时只能先做一部分。
  int get plannedMinutes {
    var total = 0;
    for (final window in windows) {
      total += window.minutes;
    }
    return total;
  }
}

/// 一段可以预约的空档，来自本次容量计算。
class CapacityWindow {
  const CapacityWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  int get minutes => end.difference(start).inMinutes;
}

/// 本次没有列入可预约范围的事项与原因。
class CapacitySkip {
  const CapacitySkip({
    required this.item,
    required this.reason,
    this.fixed = false,
  });

  final PlanItem item;
  final String reason;

  /// 已固定的安排，容量规划不会改动。
  final bool fixed;
}

/// 一次容量计算：可用时间、需求、优先顺序、可预约空档与说明。
///
/// 这里给出顺序、粗略预算与算好的空档；写入仍由用户点选其中一段后发生。
class CapacityPlan {
  const CapacityPlan({
    required this.from,
    required this.days,
    required this.availableMinutes,
    required this.demandMinutes,
    this.candidates = const [],
    this.skipped = const [],
    this.notes = const [],
    this.windowStart = '19:00',
    this.windowEnd = '21:30',
  });

  final DateTime from;
  final int days;
  final int availableMinutes;

  /// 待安排事项的合计估时；可调整的弹性块按重新安排处理，固定占用计入可用时间。
  final int demandMinutes;
  final List<CapacityCandidate> candidates;
  final List<CapacitySkip> skipped;
  final List<String> notes;
  final String windowStart;
  final String windowEnd;

  bool get overCapacity => demandMinutes > availableMinutes;
  bool get hasCandidates => candidates.isNotEmpty;

  String get availableBudget => roughMinutes(availableMinutes);
  String get demandBudget => roughMinutes(demandMinutes);
}

/// 粗略时间：不足一小时按十分钟向上取整，达到一小时按半小时四舍五入。
String roughMinutes(int minutes) {
  if (minutes <= 0) return '0 分钟';
  if (minutes < 60) {
    final rounded = ((minutes + 9) ~/ 10) * 10;
    return '约 $rounded 分钟';
  }
  final halfHours = (minutes / 30).round();
  final hours = halfHours ~/ 2;
  final text = halfHours.isOdd ? '$hours.5' : '$hours';
  return '约 $text 小时';
}
