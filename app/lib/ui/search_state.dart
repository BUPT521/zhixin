import 'package:flutter/foundation.dart';

import '../application/paged_result.dart';
import '../application/request_gate.dart';
import 'format.dart';

/// 取一页结果：参数是这一页的起点，页大小由调用方的服务决定。
typedef SearchPage<T> = Future<PagedResult<T>> Function(int offset);

/// 查找结果的状态：还没有条件、正在读、已经读到与读取失败。
enum SearchPhase { idle, loading, ready, failed }

/// 一次查找的共用状态：请求序号、防抖、分页、结果状态与空态。
///
/// 页面只提供取页函数与自己的条件是否为空，状态对象负责：
/// - 连续输入时等 [debounceDuration] 再查，只有最后一次生效；
/// - 条件变化或重新查找时换一个请求序号，晚到的旧结果丢弃；
/// - 翻页时按 [PagedResult.nextOffset] 取下一页并追加，正在读时不重复发；
/// - 用 [phase] 表示正在读、已读到与失败，用 [isEmpty] 表示查到但没有命中。
///
/// 记录查找、安排查找、记忆查找与材料查找原先各有一份 `_search`、`_loadMore`
/// 与几个布尔字段；批次 8 与批次 9 把它们换成这一份。取页函数把服务返回值
/// 转成 [PagedResult]，失败说明仍由页面用 `describeFailure` 生成，这里只保存
/// 原始错误；查询条件由页面持有，翻页用的闭包在每次查找时更新。
class SearchState<T> extends ChangeNotifier {
  /// [key] 用来在翻页时去重；不给时按两页不重叠处理。
  SearchState({
    this.pageSize = kSearchPageSize,
    this.debounceDuration = kDebounceDelay,
    this.key,
  });

  /// 一页的条数；页面交给服务层，作为四个页大小常量的替代。
  final int pageSize;

  /// 输入停下之后等待的时长。
  final Duration debounceDuration;

  /// 翻页去重用的键；为空时不去重。
  final Object? Function(T item)? key;

  late final Debouncer _debounce = Debouncer(duration: debounceDuration);
  final RequestGate _requests = RequestGate();

  bool _active = false;
  SearchPhase _phase = SearchPhase.idle;
  PagedResult<T>? _page;
  Object? _error;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  SearchPage<T>? _fetch;
  bool _disposed = false;

  /// 当前是否有关查找条件；由页面在每次查找前给出。
  bool get active => _active;

  SearchPhase get phase => _phase;

  /// 已经取回的这一页；还没有结果时为空。
  PagedResult<T>? get page => _page;

  /// 已经显示的条目。
  List<T> get items => _page?.items ?? const [];

  /// 最近一次失败的原始错误；失败说明由页面转换。
  Object? get error => _error;

  bool get hasMore => _page?.hasMore ?? false;

  int get nextOffset => _page?.nextOffset ?? 0;

  /// 正在读第一页。
  bool get isLoading => _phase == SearchPhase.loading;

  /// 第一页读取失败。
  bool get isFailed => _phase == SearchPhase.failed;

  /// 正在读下一页。
  bool get loadingMore => _loadingMore;

  /// 读下一页失败；已经显示的结果保持不动，可以再点一次重试。
  bool get loadMoreFailed => _loadMoreFailed;

  /// 有条件且已经读到结果，但没有一条命中；条件为空时不算空态。
  bool get isEmpty =>
      _active && _phase == SearchPhase.ready && (_page?.isEmpty ?? true);

  /// 可以继续翻页：有条件、已经读到第一页、后面还有，而且当前没有在读。
  bool get canLoadMore =>
      _active &&
      _phase == SearchPhase.ready &&
      !_loadingMore &&
      (_page?.hasMore ?? false);

  /// 条件变化后取第一页：先显示读取中，等 [debounceDuration] 再真正发起，
  /// 连续调用只发最后一条；条件被清空时回到入口状态。
  void onQueryChanged({required bool active, required SearchPage<T> fetch}) {
    _active = active;
    _fetch = fetch;
    _debounce.cancel();
    // 条件一变就换序号，正在读的旧请求回来时直接丢弃。
    _requests.start();
    _error = null;
    _loadMoreFailed = false;
    _loadingMore = false;
    if (!active) {
      _page = null;
      _phase = SearchPhase.idle;
      _notify();
      return;
    }
    _phase = SearchPhase.loading;
    _notify();
    _debounce(() => refresh(active: active, fetch: fetch));
  }

  /// 立即取第一页：用于提交、筛选变化与重试。
  Future<void> refresh({
    required bool active,
    required SearchPage<T> fetch,
  }) async {
    _debounce.cancel();
    _active = active;
    _fetch = fetch;
    final request = _requests.start();
    _error = null;
    _loadMoreFailed = false;
    _loadingMore = false;
    if (!active) {
      _page = null;
      _phase = SearchPhase.idle;
      _notify();
      return;
    }
    _phase = SearchPhase.loading;
    _notify();
    try {
      final page = await fetch(0);
      if (_disposed || !_requests.isCurrent(request)) return;
      _page = page;
      _phase = SearchPhase.ready;
      _notify();
    } catch (error) {
      if (_disposed || !_requests.isCurrent(request)) return;
      _page = null;
      _error = error;
      _phase = SearchPhase.failed;
      _notify();
    }
  }

  /// 接着向后取一页；没有条件、没有下一页或正在读时不发请求。
  Future<void> loadMore() async {
    final page = _page;
    final fetch = _fetch;
    if (fetch == null || page == null || !canLoadMore) return;
    final request = _requests.start();
    _loadingMore = true;
    _loadMoreFailed = false;
    _notify();
    try {
      final next = await fetch(page.nextOffset);
      if (_disposed || !_requests.isCurrent(request)) return;
      _page = page.append(next, key: key);
      _loadingMore = false;
      _notify();
    } catch (error) {
      if (_disposed || !_requests.isCurrent(request)) return;
      _loadingMore = false;
      _loadMoreFailed = true;
      _error = error;
      _notify();
    }
  }

  /// 清空条件、结果与错误，并让在途请求失效。
  void clear() {
    _debounce.cancel();
    _requests.start();
    _fetch = null;
    _active = false;
    _page = null;
    _error = null;
    _phase = SearchPhase.idle;
    _loadingMore = false;
    _loadMoreFailed = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce.cancel();
    super.dispose();
  }
}
