/// 一条讨论记录（01 `conversation`）。
///
/// 讨论由 `id` 打开，日期只用于展示和筛选；没有目标归属时 `goalId` 为空，
/// 带入材料时 `materialId` 与 `pageNo` 指向引用位置。一条讨论就是一条学习
/// 记录：题目取开始作答时确定的用户消息与图片，开始作答后 `hasAttempts` 为真。
library;

import '../rules/coded_enum.dart';
import '../rules/text.dart';
import 'material.dart';

import '../rules/search_terms.dart';

/// 一次求助的入口（01 `conversation.entry_kind`）：文字、图片或两者。
enum EntryKind implements CodedEnum {
  text('text', '文字'),
  photo('photo', '只有图片'),
  textPhoto('text_photo', '文字与图片'),
  unknown('', '类型未知');

  const EntryKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static EntryKind fromValue(String? value) =>
      codedValueOr(EntryKind.values, value, unknown: unknown);
}

/// 讨论当前状态（01 `conversation.status`）；结束时记录结束时间。
enum ConversationStatus implements CodedEnum {
  open('open', '进行中'),
  ended('ended', '已结束'),
  unknown('', '状态未知');

  const ConversationStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static ConversationStatus fromValue(String? value) =>
      codedValueOr(ConversationStatus.values, value, unknown: unknown);
}

class ConversationRecord {
  const ConversationRecord({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.materialTitle,
    this.materialIsDocx = false,
    this.entryKind = EntryKind.text,
    this.status = ConversationStatus.open,
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

  final String id;
  final String? title;

  /// 用户明确选择的目标；为空表示无归属。
  final String? goalId;

  /// 这次讨论依据的材料与页码；为空表示没有带入材料。
  final String? materialId;
  final int? pageNo;
  final String? materialTitle;
  final bool materialIsDocx;

  /// 这次求助来自文字、图片还是两者。
  final EntryKind entryKind;

  /// 讨论是否还在进行；读库时认不出的值回落到 [ConversationStatus.unknown]。
  final ConversationStatus status;
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

  bool get open => status == ConversationStatus.open;

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
    return nullableText(draftAnswer);
  }

  /// 记录列表与“现在”页展示的标题。
  String get displayTitle {
    final text = nullableText(title);
    if (text != null) return text;
    return entryKind == EntryKind.photo ? '图片求助' : '一次求助';
  }

  String get kindLabel => entryKind.label;

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

  final String conversationId;
  final String content;
  final String? title;
  final DateTime? createdAt;
  final String? snippetText;

  String get snippet =>
      snippetText ?? searchSnippet(content, const <String>[], limit: 80);
}
