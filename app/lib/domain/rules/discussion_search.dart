import '../models/chat_message.dart';

/// 讨论内查找：一条消息算一处命中。
///
/// 只在用户与搭子的消息正文里按原文匹配，空查询与只有图片的消息不算命中。
/// 命中按消息在讨论里的先后排列，调用方据此显示“第几处”并逐处跳转。查找只读
/// 已经保存的消息，不读网络、不写库，也不改消息顺序与已读状态。
List<ChatMessage> searchDiscussionMessages(
  Iterable<ChatMessage> messages,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  return [
    for (final message in messages)
      if (_searchable(message) &&
          message.content.toLowerCase().contains(needle))
        message,
  ];
}

/// 讨论里真正进入查找的角色：用户消息与搭子的回答；系统行不参与。
bool _searchable(ChatMessage message) =>
    message.role == MessageRole.user || message.role == MessageRole.assistant;
