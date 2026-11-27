import 'package:flutter/widgets.dart';

import '../application/request_gate.dart';
import '../domain/models/chat_message.dart';
import '../domain/rules/discussion_search.dart';

/// 讨论页的会话内查找：查询、命中、当前一处与读取整条讨论的状态。
///
/// 页面原来把这些字段、请求编号与三次 `setState` 都写在 State 里，打开、关闭、
/// 换查询与跳转各写一遍复位；现在收进一个普通控制器。页面只提供读取整条讨论
/// 与失败说明，并处理需要滚动与定位的两步：跳到当前一处、关闭时恢复列表。
class DiscussionSearch {
  DiscussionSearch({
    required this.input,
    required this.focus,
    required this.onChanged,
    required this.onReveal,
    required this.isMounted,
    required this.conversationId,
    required this.loadMessages,
    required this.describeError,
    required this.onMessagesLoaded,
  }) {
    input.addListener(_onTextChanged);
  }

  final TextEditingController input;
  final FocusNode focus;

  /// 状态变了让页面重建。
  final VoidCallback onChanged;

  /// 跳到当前命中；滚动与定位由页面做。
  final VoidCallback onReveal;

  final bool Function() isMounted;

  /// 当前讨论的编号；还没有记录时为空，查找只在已经读到的消息里进行。
  final String? Function() conversationId;

  final Future<List<ChatMessage>> Function(String conversationId) loadMessages;

  /// 读取整条讨论失败时的说明；页面用 `describeFailure` 生成。
  final String Function(Object error, StackTrace stack) describeError;

  /// 读到整条讨论之后交给页面：时间线要接上全部消息，跳到较早的命中才有那一条。
  final void Function(List<ChatMessage> messages) onMessagesLoaded;

  /// 每次查询换一个编号，晚到的旧结果直接丢弃。
  final RequestGate _requests = RequestGate();

  bool open = false;
  bool loading = false;
  bool ready = false;
  String? failure;

  /// 整条讨论的消息快照；查找覆盖已经翻到与没有翻到的全部消息。
  List<ChatMessage> allMessages = const [];
  List<ChatMessage> hits = const [];

  /// 当前是第几处，从 0 起；没有命中时为 -1。
  int index = -1;

  /// 打开查找之前已经读到的更早几页与滚动位置，关闭时原位恢复。
  List<ChatMessage> savedOlder = const [];
  double savedOffset = 0;

  /// 查找命中的当前一条；查找关闭或没有命中时为空。
  String? get highlightedId =>
      !open || index < 0 || index >= hits.length ? null : hits[index].id;

  /// 打开查找条：记下当前列表与滚动位置，关闭时原样恢复。
  void openBar({required List<ChatMessage> older, required double offset}) {
    if (open) return;
    savedOlder = older;
    savedOffset = offset;
    open = true;
    _clearHits();
    onChanged();
    input.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted() && open) focus.requestFocus();
    });
  }

  /// 关闭查找并返回打开之前的列表与滚动位置；还在读取的那次结果不再回填。
  ({List<ChatMessage> older, double offset}) close() {
    if (!open) return (older: savedOlder, offset: savedOffset);
    final restore = (older: savedOlder, offset: savedOffset);
    _requests.start();
    focus.unfocus();
    open = false;
    _clearHits();
    savedOlder = const [];
    onChanged();
    input.clear();
    return restore;
  }

  void _clearHits() {
    loading = false;
    ready = false;
    failure = null;
    allMessages = const [];
    hits = const [];
    index = -1;
  }

  void _onTextChanged() {
    if (!open) return;
    run(input.text);
  }

  void retry() {
    if (!isMounted()) return;
    failure = null;
    ready = false;
    onChanged();
    run(input.text);
  }

  /// 查询变化只保留最后一次结果；第一次查询先读整条讨论的消息。
  Future<void> run(String text) async {
    final query = text.trim();
    final request = _requests.start();
    if (query.isEmpty) {
      loading = false;
      failure = null;
      hits = const [];
      index = -1;
      onChanged();
      return;
    }
    if (ready) {
      _apply(query);
      return;
    }
    final id = conversationId();
    if (id == null) {
      _apply(query);
      return;
    }
    loading = true;
    failure = null;
    onChanged();
    try {
      final messages = await loadMessages(id);
      if (!isMounted() || !_requests.isCurrent(request)) return;
      ready = true;
      allMessages = messages;
      loading = false;
      // 查找覆盖整条讨论：时间线先接上全部消息，跳到较早的命中才有那一条。
      onMessagesLoaded(messages);
      _apply(input.text.trim());
    } catch (error, stack) {
      if (!isMounted() || !_requests.isCurrent(request)) return;
      loading = false;
      failure = describeError(error, stack);
      onChanged();
    }
  }

  void _apply(String query) {
    final result = searchDiscussionMessages(allMessages, query);
    if (!isMounted()) return;
    hits = result;
    index = result.isEmpty ? -1 : 0;
    loading = false;
    failure = null;
    onChanged();
    if (result.isNotEmpty) onReveal();
  }

  /// 上一处与下一处循环跳转；每次只让当前这一条带高亮。
  void step(int delta) {
    if (hits.isEmpty) return;
    index = (index + delta) % hits.length;
    onChanged();
    onReveal();
  }

  void dispose() {
    input.removeListener(_onTextChanged);
    input.dispose();
    focus.dispose();
  }
}
