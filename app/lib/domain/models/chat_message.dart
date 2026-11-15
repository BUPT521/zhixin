import 'dart:convert';

import 'chat_message_payload.dart';

/// 一条讨论消息（01 `message`，开发期 schema 17）。
///
/// 只有图片时 `content` 是空字符串；原图路径放在 `imagePaths`。结构化补充
/// 保存本次回答的来源、引用、下一步建议与记忆卡片，统一由 [ChatMessagePayload]
/// 读写，界面与撤销不再直接解析 JSON。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePaths = const [],
    this.createdAt,
    this.payload,
  });

  final int id;
  final int conversationId;

  String get identity => 'message:$conversationId:$id';

  /// `user` / `assistant` / `system`。
  final String role;
  final String content;
  final List<String> imagePaths;
  final DateTime? createdAt;

  /// 结构化补充；没有时为空。
  final ChatMessagePayload? payload;

  bool get isUser => role == 'user';
  bool get isSystem => role == 'system';
  bool get hasImages => imagePaths.isNotEmpty;

  /// 这条回答是否在生成中被停止；历史记录里仍要标出来。
  bool get stopped => payload?.stopped == true;

  /// 这条回答是否在生成中断；历史记录里仍要标出来。
  bool get interrupted => payload?.interrupted == true;

  static String? encodePaths(List<String> paths) {
    final cleaned = paths
        .where((path) => path.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    return cleaned.isEmpty ? null : jsonEncode(cleaned);
  }
}
