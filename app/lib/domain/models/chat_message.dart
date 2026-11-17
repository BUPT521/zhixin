import 'dart:convert';

import '../rules/coded_enum.dart';
import 'chat_message_payload.dart';

/// 一条消息的作者角色（01 `message.role`）。
enum MessageRole implements CodedEnum {
  user('user', '你'),
  assistant('assistant', '搭子'),
  system('system', '系统'),
  unknown('', '角色未知');

  const MessageRole(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static MessageRole fromValue(String? value) =>
      codedValueOr(MessageRole.values, value, unknown: unknown);
}

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

  final String id;
  final String conversationId;

  String get identity => 'message:$conversationId:$id';

  /// 这条消息由谁写下；读库时认不出的值回落到 [MessageRole.unknown]。
  final MessageRole role;
  final String content;
  final List<String> imagePaths;
  final DateTime? createdAt;

  /// 结构化补充；没有时为空。
  final ChatMessagePayload? payload;

  bool get isUser => role == MessageRole.user;
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
