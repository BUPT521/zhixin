import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import 'discussion_chat.dart';

/// 从“记录”打开的讨论：同一条记录，可以继续发消息。
///
/// 标题栏、状态行与输入区都由 [DiscussionChat] 自己排出：标题栏里的“开始作答”
/// 与更多操作要读当前消息与记录，放在页面外面够不着这些状态。
class DiscussionPage extends StatelessWidget {
  const DiscussionPage({
    super.key,
    this.conversationId,
    this.startNew = false,
    this.initialText = '',
    this.initialImages = const [],
    this.onSubmitted,
  }) : assert(conversationId != null || startNew, '打开讨论要给出记录编号，或者明确说这是新讨论');

  final String? conversationId;
  final bool startNew;

  /// 首页带进来的文字与图片：进页面时先摆进输入区，由用户确认后发送。
  final String initialText;
  final List<XFile> initialImages;

  /// 首条消息写进记录之后回调，首页用它清空已经转进讨论的草稿。
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return DiscussionChat(
      conversationId: conversationId,
      startNew: startNew,
      initialText: initialText,
      initialImages: initialImages,
      onSubmitted: onSubmitted,
    );
  }
}
