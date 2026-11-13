import 'package:material_ui/material_ui.dart';

/// 正在生成回答的讨论，跨页面共享。
///
/// 讨论页离开之后请求仍会完成并写入记录，记录与“继续上次”据此显示“正在生成
/// 回答”；生成结束、停止或失败后移除，两处列表重读一次，消息数与摘要随之更新。
class DiscussionActivity {
  DiscussionActivity._();

  static final ValueNotifier<Set<int>> generating = ValueNotifier<Set<int>>(
    const <int>{},
  );

  static bool isGenerating(int conversationId) =>
      generating.value.contains(conversationId);

  static void begin(int conversationId) {
    if (generating.value.contains(conversationId)) return;
    generating.value = {...generating.value, conversationId};
  }

  static void end(int conversationId) {
    if (!generating.value.contains(conversationId)) return;
    final next = {...generating.value}..remove(conversationId);
    generating.value = next;
  }
}
