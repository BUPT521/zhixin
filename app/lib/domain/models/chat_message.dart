import 'dart:convert';

/// 一条讨论消息（01 `message`，开发期 schema 17）。
///
/// 只有图片时 `content` 是空字符串；原图路径放在 `imagePaths`。结构化补充
/// 保存本次回答来自模型还是本地规则、下一步建议与已接受的建议。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePaths = const [],
    this.createdAt,
    this.structuredJson,
  });

  final int id;
  final int conversationId;

  String get identity => 'message:$conversationId:$id';

  /// `user` / `assistant` / `system`。
  final String role;
  final String content;
  final List<String> imagePaths;
  final DateTime? createdAt;

  /// 结构化补充：本次引用、下一步建议与已接受的建议，供界面展示与撤销。
  final String? structuredJson;

  bool get isUser => role == 'user';
  bool get isSystem => role == 'system';
  bool get hasImages => imagePaths.isNotEmpty;

  Map<String, Object?>? get structured => decodeStructured(structuredJson);

  /// 这条回答是否在生成中被停止；历史记录里仍要标出来。
  bool get stopped => structured?['stopped'] == true;

  /// 这条回答是否在生成中断；历史记录里仍要标出来。
  bool get interrupted => structured?['interrupted'] == true;

  static Map<String, Object?>? decodeStructured(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String? encodePaths(List<String> paths) {
    final cleaned = paths
        .where((path) => path.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    return cleaned.isEmpty ? null : jsonEncode(cleaned);
  }
}
