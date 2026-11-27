import 'package:flutter/foundation.dart';

import '../domain/models/material.dart';
import '../domain/rules/search_terms.dart';
import 'format.dart';

/// 材料正文里的一处命中：第几页、从第几个字符开始、有多长。
class MaterialPageMatch {
  const MaterialPageMatch({
    required this.pageNo,
    required this.start,
    required this.length,
  });

  final int pageNo;
  final int start;
  final int length;
}

/// 材料详情内的正文查找：输入防抖、逐页命中与当前一处。
///
/// 页面只把输入、订阅读到的页面与上一处、下一处交给它；命中位置、当前序号与
/// 命中计数由这里算，`build` 里只读这些字段，不在排版时改状态。页面提供
/// [onJumpRequested]，在查询生效与切换当前一处之后滚到对应页。
class MaterialFindController extends ChangeNotifier {
  MaterialFindController({this.debounceDuration = kDebounceDelay});

  /// 输入停下之后等待的时长。
  final Duration debounceDuration;

  late final Debouncer _debounce = Debouncer(duration: debounceDuration);

  /// 查询生效或当前一处变化之后调用；页面据此滚到当前这一处。
  VoidCallback? onJumpRequested;

  List<MaterialPage> _pages = const [];
  List<MaterialPageMatch> _matches = const [];
  String _query = '';
  int _index = 0;

  /// 已经生效的查询词。
  String get query => _query;

  bool get hasQuery => _query.isNotEmpty;

  /// 这一份材料里逐页的全部命中，按页码与位置先后排列。
  List<MaterialPageMatch> get matches => _matches;

  /// 当前这一处在 [matches] 里的位置；没有命中时为 0。
  int get index => _index;

  /// 当前这一处；没有命中时为空。
  MaterialPageMatch? get current => _matches.isEmpty ? null : _matches[_index];

  /// 这一份材料已读到的全部页面；材料内查找与滚动定位共用。
  List<MaterialPage> get pages => _pages;

  /// 输入变化：等输入停下来再扫一遍这一份材料，连续输入只留最后一次。
  void onInputChanged(String text) {
    _debounce(() => apply(text));
  }

  /// 立即生效一次查询；空查询撤掉全部命中，也不请求滚动。
  void apply(String text) {
    _debounce.cancel();
    _query = text.trim();
    _index = 0;
    _recompute();
    notifyListeners();
    if (_query.isNotEmpty) onJumpRequested?.call();
  }

  /// 订阅读到新的页面：重算命中并把当前序号收进范围。
  ///
  /// 只在订阅结果的回调里调用，不在 `build` 里调用。
  void updatePages(List<MaterialPage> pages) {
    _pages = List<MaterialPage>.unmodifiable(pages);
    _recompute();
    notifyListeners();
  }

  /// 上一处、下一处；到头之后从另一头继续，按键始终可用。
  void step(int delta) {
    if (_matches.isEmpty) return;
    _index = (_index + delta + _matches.length) % _matches.length;
    notifyListeners();
    onJumpRequested?.call();
  }

  /// 清空查询与命中，页面回到不带高亮的原样。
  void clear() {
    _query = '';
    _debounce.cancel();
    _index = 0;
    _matches = const [];
    notifyListeners();
  }

  void _recompute() {
    _matches = _findIn(_pages, _query);
    _index = _matches.isEmpty ? 0 : _index.clamp(0, _matches.length - 1);
  }

  /// 这一份材料里与查询逐字相同的每一处，按页码与位置先后排列。
  static List<MaterialPageMatch> _findIn(
    List<MaterialPage> pages,
    String query,
  ) {
    if (query.isEmpty) return const [];
    final matches = <MaterialPageMatch>[];
    for (final page in pages) {
      for (final start in literalOccurrences(page.content, query)) {
        matches.add(
          MaterialPageMatch(
            pageNo: page.pageNo,
            start: start,
            length: query.length,
          ),
        );
      }
    }
    return matches;
  }

  @override
  void dispose() {
    _debounce.cancel();
    super.dispose();
  }
}
