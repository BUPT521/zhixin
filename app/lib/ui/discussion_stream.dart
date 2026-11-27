import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../ai/llm_client.dart';

/// 讨论页的流式回答状态：正文缓冲、生成标志与这一次的取消信号。
///
/// 页面原先把这些字段和三个帧回调都写在 State 里，发送与重答各复位一遍；
/// 现在收进一个普通控制器，页面只读它的字段，把变化画到时间线与输入区。
class DiscussionStream {
  /// 只让正在生成的气泡跟着正文重建，不带着整页消息一起重建。
  final ValueNotifier<String> text = ValueNotifier<String>('');

  /// 还没交给界面的最新正文：网络分片再密，一帧最多更新一次。
  String? _pending;
  bool _flushScheduled = false;

  bool _streaming = false;
  bool _sending = false;
  bool _retrying = false;

  /// 开始作答的入口在等待打开页面，期间不重复发起。
  bool answering = false;

  /// 本次发送的取消信号；生成中按停止时用它中止请求。
  LlmCancelToken? _cancelToken;

  /// 生成中的回答出现之后用于判断订阅是否已经读回这条回答。
  String? _answeringAfterMessageId;

  bool get streaming => _streaming;
  bool get sending => _sending;
  bool get retrying => _retrying;
  String? get answeringAfterMessageId => _answeringAfterMessageId;

  /// 发送与重答共用的开头：换一个取消信号、清空流式正文并进入生成状态。
  ///
  /// [afterMessageId] 是这次回答之前最后一条消息的编号，订阅读回它之后的
  /// 回答时据此收起生成气泡。
  LlmCancelToken begin({
    required bool retrying,
    required String? afterMessageId,
  }) {
    final cancel = LlmCancelToken();
    _cancelToken = cancel;
    _answeringAfterMessageId = afterMessageId;
    text.value = '';
    _pending = null;
    _streaming = true;
    if (retrying) {
      _retrying = true;
    } else {
      _sending = true;
    }
    return cancel;
  }

  /// 用户消息已经落库、回答还没有回来：保持生成状态，清掉上一轮的正文。
  void resume() {
    text.value = '';
    _pending = null;
    _streaming = true;
  }

  /// 流式正文按帧合并：一帧里来多少分片，正文都只重排一次。
  ///
  /// 长回答每次更新都要重新解析并排版整段 Markdown，分片越密越贵；合并之后
  /// 正文每帧最多换一次，肉眼分辨不出，长回答末尾的贴底滚动也不再发涩。
  /// 没有别的绘制要跑时先给自己排一帧，正文不会因为等不到帧卡住。
  void showPartial(String value) {
    if (!_streaming) return;
    _pending = value;
    if (_flushScheduled) return;
    _flushScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _flushScheduled = false;
      _flushPending();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// 把攒下的最新正文交给界面；生成已经结束时丢掉，不覆盖收尾后的状态。
  void _flushPending() {
    final pending = _pending;
    _pending = null;
    if (!_streaming || pending == null) return;
    text.value = pending;
  }

  /// 一次回答结束：收起生成状态，流式正文不再更新。
  void settle() {
    text.value = '';
    _pending = null;
    _streaming = false;
  }

  /// 一次回答没有写回：收起生成状态；原因由页面给出。
  void fail() {
    text.value = '';
    _pending = null;
    _streaming = false;
  }

  /// 一次回答结束后复位按钮与取消信号；只清理这一次的。
  void end(LlmCancelToken cancel, {required bool retrying}) {
    if (identical(_cancelToken, cancel)) _cancelToken = null;
    if (retrying) {
      _retrying = false;
    } else {
      _sending = false;
    }
  }

  /// 停止本次生成；服务会把已经显示的部分保存为回答。
  void stop() => _cancelToken?.cancel();

  void dispose() => text.dispose();

  /// 订阅已经读回这条回答：生成气泡收起，交给正式消息显示。
  void receivedAnswer() {
    _streaming = false;
    text.value = '';
    _pending = null;
  }
}
