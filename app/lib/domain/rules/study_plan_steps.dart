import '../models/study_plan.dart';

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
