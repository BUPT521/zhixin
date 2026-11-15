/// 最近一次请求的守卫：页面快速切换查询、筛选或周次时，只让最后一次写入。
///
/// 每个异步入口先调用 [start] 取编号，写回前用 [isCurrent] 确认；期间有更新的
/// 请求时，旧结果直接丢弃。查找、安排页、记录页与材料页原先各写一份计数，
/// 现在共用这一个对象。
class RequestGate {
  int _current = 0;

  /// 开始一次请求，返回递增编号。
  int start() => ++_current;

  /// 这次请求是否仍是最新的一次。
  bool isCurrent(int request) => request == _current;
}
