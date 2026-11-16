import '../models/study.dart';
import '../models/study_plan.dart';

/// 改一个学习步骤的状态时要连带做的写入。
///
/// 判定只由状态与所属计划决定：同一份计划里只保留一个进行中的步骤，完成时
/// 结算这段时间的预约，延后时取消还没开始的预约。仓库按这份判定执行单表
/// 写入，不再自己判断状态语义。
class StudyStepStatusChange {
  const StudyStepStatusChange({
    required this.status,
    this.planId,
    this.resetOtherActive = false,
    this.settleBlocks = false,
    this.cancelPlannedBlocks = false,
  });

  final PlanItemStatus status;

  /// 步骤所属的计划；为空表示不属于任何计划，只有状态本身要写。
  final String? planId;

  /// 把同计划里其他进行中的步骤改回待开始，保证只有一个进行中。
  final bool resetOtherActive;

  /// 把这次完成对应的预约结算为完成，到过时间却没有场次的按取消处理。
  final bool settleBlocks;

  /// 把这一步还没开始的预约取消。
  final bool cancelPlannedBlocks;
}

/// 按步骤状态与所属计划算出要连带写入的内容。
StudyStepStatusChange studyStepStatusChange(
  PlanItemStatus status, {
  String? planId,
}) => StudyStepStatusChange(
  status: status,
  planId: planId,
  resetOtherActive: status == PlanItemStatus.doing && planId != null,
  settleBlocks: status == PlanItemStatus.done,
  cancelPlannedBlocks: status == PlanItemStatus.deferred,
);

/// 核对学习步骤的页码范围、顺序与所选页面的覆盖情况。
String? studyStepsProblem({
  required List<StudyStepDraft> steps,
  required Iterable<int> pageNos,
  required int pageFrom,
  required int pageTo,
}) {
  var lastPageTo = pageFrom - 1;
  final missing = pageNos.toSet();
  for (final step in steps) {
    final from = step.pageFrom;
    final to = step.pageTo;
    if (from == null && to == null) continue;
    if (from == null || to == null) {
      return '学习步骤必须同时提供起始页和结束页';
    }
    if (from < pageFrom || to > pageTo || to < from) {
      return '学习步骤页码必须处于第 $pageFrom–$pageTo 页内';
    }
    if (from <= lastPageTo) {
      return '学习步骤页码重复或顺序颠倒';
    }
    lastPageTo = to;
    missing.removeWhere((pageNo) => pageNo >= from && pageNo <= to);
  }
  if (missing.isNotEmpty) {
    return '学习步骤没有覆盖第 ${_rangesOf(missing.toList()..sort())} 页';
  }
  return null;
}

String _rangesOf(List<int> pageNos) {
  final parts = <String>[];
  var start = pageNos.first;
  var end = start;
  for (final pageNo in pageNos.skip(1)) {
    if (pageNo == end + 1) {
      end = pageNo;
      continue;
    }
    parts.add(start == end ? '$start' : '$start–$end');
    start = pageNo;
    end = pageNo;
  }
  parts.add(start == end ? '$start' : '$start–$end');
  return parts.join('、');
}
