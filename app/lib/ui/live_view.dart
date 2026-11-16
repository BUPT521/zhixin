import 'dart:async';

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// 订阅跟随写入更新的读取（ADR-0014）。
///
/// 页面把一次视图需要的读法交给服务，服务返回一条流；数据到达就重建，写入
/// 之后的重新读取、过期结果丢弃与换库之后的重读都由数据层完成，页面不再在
/// 写入之后自己重读。出错时保留上一份结果并把错误交给 [onError]，一次读取
/// 失败不会让已经显示的内容变成空白。
///
/// 换筛选、换周或换页签时页面会给出另一条流，这里退订旧的、订阅新的；
/// 上一份结果留到新结果到达，界面因此不会闪一下。
class LiveView<T> extends StatefulWidget {
  const LiveView({
    super.key,
    required this.stream,
    required this.builder,
    this.onError,
    this.onData,
    this.contentTransition,
  });

  /// 跟随写入更新的读取；为空时只显示 [builder] 的空状态。
  final Stream<T>? stream;

  /// 数据、首读中的状态与重建；`data` 在第一次结果到达之前为空。
  final Widget Function(BuildContext context, T? data, bool loading) builder;

  /// 读取失败：页面据此提示一次，已经显示的内容保持不变。
  final void Function(Object error, StackTrace stack)? onError;

  /// 每次结果到达之后调用；分页合并这类界面状态从这里更新。
  final void Function(T data)? onData;

  /// 调用方传入的页签切换动画；有它时回填等它结束。
  final Animation<double>? contentTransition;

  @override
  State<LiveView<T>> createState() => _LiveViewState<T>();
}

class _LiveViewState<T> extends State<LiveView<T>> {
  StreamSubscription<T>? _subscription;
  T? _data;
  bool _received = false;

  /// 结果序号：两次结果之间又来了新的，前一次就不再回填。
  int _latest = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant LiveView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.stream, widget.stream)) _subscribe();
  }

  void _subscribe() {
    final previous = _subscription;
    _subscription = null;
    if (previous != null) unawaited(previous.cancel());
    final stream = widget.stream;
    if (stream == null) return;
    _subscription = stream.listen(
      (data) async {
        if (!mounted) return;
        final request = ++_latest;
        // 读取可以立刻发起，回填要等切栏、返回与推入动画结束（ADR-0007）。
        await context.afterTransition(
          contentTransition: widget.contentTransition,
        );
        if (!mounted || request != _latest) return;
        setState(() {
          _data = data;
          _received = true;
        });
        widget.onData?.call(data);
      },
      onError: (Object error, StackTrace stack) {
        if (!mounted) return;
        widget.onError?.call(error, stack);
      },
    );
  }

  @override
  void dispose() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _data, !_received);
  }
}
