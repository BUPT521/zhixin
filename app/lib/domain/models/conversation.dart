/// 一条讨论记录（01 `conversation`）。
///
/// 讨论由 `id` 打开，日期只用于展示和筛选；没有目标归属时 `goalId` 为空，
/// 带入材料时 `materialId` 与 `pageNo` 指向引用位置。一条讨论就是一条学习
/// 记录：题目取开始作答时确定的用户消息与图片，开始作答后 `hasAttempts` 为真。
library;

import 'material.dart';

import '../rules/search_terms.dart';

class ConversationRecord {
  const ConversationRecord({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.materialTitle,
    this.materialIsDocx = false,
    this.entryKind = 'text',
    this.status = 'open',
    this.endedAt,
    this.lastMessageAt,
    this.createdAt,
    this.updatedAt,
    this.messageCount = 0,
    this.preview,
    this.lastUserMessage,
    this.draftAnswer,
    this.draftUpdatedAt,
    this.hasAttempts = false,
    this.hasDraft = false,
  });

  factory ConversationRecord.fromRow(Map<String, Object?> row) {
    return ConversationRecord(
      id: row['id']! as int,
      title: row['title'] as String?,
      goalId: row['goal_id'] as int?,
      materialId: row['material_id'] as int?,
      pageNo: row['page_no'] as int?,
      materialTitle: row['material_title'] as String?,
      materialIsDocx: isDocxFile(row['source_file_name'] as String?),
      entryKind: (row['entry_kind'] as String?) ?? 'text',
      status: (row['status'] as String?) ?? 'open',
      endedAt: DateTime.tryParse(row['ended_at'] as String? ?? ''),
      lastMessageAt: DateTime.tryParse(row['last_message_at'] as String? ?? ''),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
      messageCount: (row['message_count'] as int?) ?? 0,
      preview: row['preview'] as String?,
      lastUserMessage: row['last_user_message'] as String?,
      draftAnswer: row['draft_answer'] as String?,
      draftUpdatedAt: DateTime.tryParse(
        row['draft_updated_at'] as String? ?? '',
      ),
      hasAttempts: row['has_attempts'] == 1,
      hasDraft: row['has_draft'] == 1,
    );
  }

  final int id;
  final String? title;

  /// 用户明确选择的目标；为空表示无归属。
  final int? goalId;

  /// 这次讨论依据的材料与页码；为空表示没有带入材料。
  final int? materialId;
  final int? pageNo;
  final String? materialTitle;
  final bool materialIsDocx;

  /// `text` / `photo` / `text_photo`。
  final String entryKind;

  /// `open` / `ended`。
  final String status;
  final DateTime? endedAt;
  final DateTime? lastMessageAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 列表查询带出的消息条数与最后一条消息的摘要；单条读取时为 0 与空。
  final int messageCount;
  final String? preview;

  /// 列表查询带出的最后一条用户消息与未提交草稿；单条读取时为空。
  final String? lastUserMessage;
  final String? draftAnswer;
  final DateTime? draftUpdatedAt;

  /// 这条记录是否已经有作答；开始作答后为真。
  final bool hasAttempts;

  /// 是否有已经保存的未提交草稿；为真时列表直接给出“继续作答”。
  final bool hasDraft;

  bool get open => status == 'open';

  /// 继续入口使用的时间：有草稿时取草稿的保存时间，因为写草稿不会改
  /// `conversation.updated_at`，只看记录更新时间会把刚写下的草稿排到后面。
  DateTime? get lastActiveAt {
    final updated = updatedAt ?? lastMessageAt ?? createdAt;
    if (!hasDraft) return updated;
    final draft = draftUpdatedAt;
    if (draft == null) return updated;
    if (updated == null || draft.isAfter(updated)) return draft;
    return updated;
  }

  /// 草稿里已经写下的内容；没有草稿或草稿为空时为空。
  String? get draftSnippet {
    final text = draftAnswer?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// 记录列表与“现在”页展示的标题。
  String get displayTitle {
    final text = title?.trim();
    if (text != null && text.isNotEmpty) return text;
    return entryKind == 'photo' ? '图片求助' : '一次求助';
  }

  String get kindLabel => switch (entryKind) {
    'photo' => '只有图片',
    'text_photo' => '文字与图片',
    _ => '文字',
  };

  bool get hasMaterial => materialId != null && pageNo != null;

  String get materialLabel => hasMaterial
      ? '《${materialTitle ?? '材料'}》${materialPosition(pageNo, isDocx: materialIsDocx)}'
      : '未带入材料';
}

/// 检索到的一条较早消息；只用于带入上下文，不改变原记录。
class RelatedRecord {
  const RelatedRecord({
    required this.conversationId,
    required this.content,
    this.title,
    this.createdAt,
    this.snippetText,
  });

  factory RelatedRecord.fromRow(Map<String, Object?> row) {
    return RelatedRecord(
      conversationId: row['conversation_id']! as int,
      title: row['conversation_title'] as String?,
      content: row['content']! as String,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
    );
  }

  final int conversationId;
  final String content;
  final String? title;
  final DateTime? createdAt;
  final String? snippetText;

  String get snippet =>
      snippetText ?? searchSnippet(content, const <String>[], limit: 80);
}
