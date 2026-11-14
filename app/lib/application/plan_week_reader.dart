import 'plan_service.dart';

/// 安排页的一次换周读取：编号辨认结果是否仍然有效，周一是这次要读的目标周。
class PlanWeekTarget {
  const PlanWeekTarget({required this.request, required this.weekStart});

  /// 递增的请求编号；只有最新一次请求的结果会写回界面。
  final int request;

  /// 这次要读取的自然周周一。
  final DateTime weekStart;
}

/// 安排页的选周与读取：上一周、下一周、横滑、回到本周与下拉刷新共用一套
/// 请求编号，只有最后一次请求的成功结果、错误与分页结果会写回。
///
/// 页面在过渡动画结束之后用 [isCurrent] 再确认一次：读取期间又选了别的周，
/// 旧结果就丢掉，标题、日历、预约与课表始终对应同一个目标周。
class PlanWeekReader {
  PlanWeekReader({required this.read});

  /// 读取一个自然周的数据；换周与刷新都走这里。
  final Future<PlanWeek> Function(DateTime weekStart) read;

  int _request = 0;
  DateTime? _weekStart;

  /// 当前目标周的周一；还没有选过周时为空。
  DateTime? get weekStart => _weekStart;

  /// 选一周；仍是当前目标周时返回空，不重复读取。
  PlanWeekTarget? select(DateTime weekStart) {
    if (weekStart == _weekStart) return null;
    _weekStart = weekStart;
    return PlanWeekTarget(request: ++_request, weekStart: weekStart);
  }

  /// 重新读取当前目标周；写入之后与下拉刷新都用它。
  ///
  /// 请求编号加一，更早发出、还没有写回的读取因此作废。
  PlanWeekTarget? refresh() {
    final weekStart = _weekStart;
    if (weekStart == null) return null;
    return PlanWeekTarget(request: ++_request, weekStart: weekStart);
  }

  /// 这次请求的结果是否仍然要写回界面。
  bool isCurrent(PlanWeekTarget target) => target.request == _request;
}
