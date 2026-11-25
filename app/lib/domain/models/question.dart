import 'dart:convert';

import '../rules/notices.dart';
import '../rules/time_format.dart';
import 'chat_message_payload.dart';
import 'memory_draft.dart';

/// 题目视图，由一条学习记录（conversation）与开始作答时确定的用户消息派生。
///
/// 题目不再单独存表：`id` 就是 conversation 的标识，题干与图片取
/// `question_message_id` 指向的用户消息，出处与材料摘录取 conversation 的
/// `source_ref` 与 `context_text`。只有图片、没有文字的题目 `stem` 为空，
/// 界面按 [displayStem] 显示，原文仍是原图。
class Question {
  const Question({
    required this.id,
    required this.stem,
    this.sourceRef,
    this.contextText,
    this.imagePaths = const [],
    this.createdAt,
    this.updatedAt,
  });

  /// 学习记录的标识。
  final String id;
  final String stem;
  final String? sourceRef;
  final String? contextText;
  final List<String> imagePaths;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 讨论标识就是记录本身；保留这个读法，调用方不必区分两者。
  String get conversationId => id;

  bool get hasImages => imagePaths.isNotEmpty;

  /// 列表、卡片与提示词里的题目名称；只有图片时给出可读的占位。
  String get displayStem {
    final text = stem.trim();
    if (text.isNotEmpty) return text;
    return hasImages ? '图片题目' : '未命名题目';
  }
}

/// 列表里一行题目带最近一次已提交尝试，用来显示状态与时间。
class QuestionRow {
  const QuestionRow({
    required this.question,
    this.lastAttempt,
    this.hasDraft = false,
  });

  final Question question;
  final Attempt? lastAttempt;

  /// 是否有已经保存的未提交草稿；为真时直接给出“继续作答”。
  final bool hasDraft;

  /// `open`（没有提交过）、`unjudged`（提交了但没判断对错）、`wrong`、`correct`。
  String get status {
    final attempt = lastAttempt;
    if (attempt == null) return 'open';
    if (!attempt.submitted || attempt.isCorrect == null) return 'unjudged';
    return attempt.isCorrect! ? 'correct' : 'wrong';
  }
}

/// 一次求助、作答与自评（01 `attempt`）。
class Attempt {
  const Attempt({
    required this.id,
    required this.conversationId,
    this.sessionId,
    this.redoOfAttemptId,
    this.userAnswer,
    this.solution,
    this.isCorrect,
    this.independent,
    this.helps = const [],
    this.feedback,
    this.delayed = false,
    this.submittedAt,
    this.createdAt,
  });

  final String id;

  /// 这次作答属于哪条学习记录。
  final String conversationId;
  final String? sessionId;

  /// 独立重做时被复查的那次已提交作答；为空表示普通作答。
  final String? redoOfAttemptId;
  final String? userAnswer;

  /// 单独保存的解法；不覆盖答案、帮助与困难。
  final String? solution;
  final bool? isCorrect;

  /// 用过任何来源的帮助：应用内帮助有记录，应用外帮助由用户声明。
  bool get hintUsed => helps.isNotEmpty || independent == false;

  /// 是否独立完成；未声明时为 null，不按 false 处理。
  final bool? independent;
  final List<HelpEntry> helps;
  final String? feedback;

  /// 是否为隔一段时间后重做；用于区分当场完成与延迟后的独立表现。
  final bool delayed;
  final DateTime? submittedAt;
  final DateTime? createdAt;

  bool get submitted => submittedAt != null;
  bool get isOpen => submittedAt == null;

  /// 自评结果：由作答记录本身推出，不再单独保存一条判断。
  ///
  /// 应用内帮助由记录带出，优先于独立性声明；独立性只采信用户明确的选择，
  /// 没有选择时记录为未说明，不从“应用内没有帮助”推断独立完成。
  String get selfResult {
    if (!submitted) return '未提交';
    if (helps.isNotEmpty) return '辅助完成（应用内帮助）';
    if (independent == false) return '辅助完成（应用外帮助）';
    if (independent == null) return '独立性未说明';
    if (delayed) return '延迟后独立完成';
    return '独立完成';
  }

  /// 自评依据：把帮助次数、独立性声明与作答条件写成一句，供界面与模型核对。
  String get selfBasis =>
      '应用内帮助：${helps.length} 次'
      '${independent == null
          ? '，独立性未说明'
          : independent!
          ? '，用户记为独立完成'
          : '，用户记为使用了应用外帮助'}'
      '${delayed ? '，间隔后重做' : '，当场作答'}'
      '${isCorrect == null
          ? '，暂未判断对错'
          : isCorrect!
          ? '；自评：正确'
          : '；自评：有误'}';

  /// 对错的展示文字；未判断时不再当成做错。
  String get judgmentLabel => isCorrect == null
      ? '未判断'
      : isCorrect!
      ? '自评做对'
      : '自评做错';
}

/// 最近一次已提交尝试与它所属的学习记录，给首页与模型上下文用。
class AttemptWithQuestion {
  const AttemptWithQuestion({required this.attempt, required this.question});

  final Attempt attempt;
  final Question question;
}

/// 一次提示、讲解或检查；挂在尝试上，不单独算作答。
class HelpEntry {
  const HelpEntry({
    required this.kind,
    required this.content,
    required this.at,
    this.memories = const [],
    this.fromModel,
    this.notices = const [],
    this.failureName,
    this.quotaReason,
    this.usedPages = const [],
  });

  /// `hint` / `explain` / `check` / `discuss`。
  final String kind;
  final String content;
  final DateTime? at;

  /// 这条帮助给出的记忆建议；没有建议时为空。
  final List<MemoryDraft> memories;
  final bool? fromModel;
  final List<Notice> notices;
  final String? failureName;

  /// 额度用完的具体原因名（`QuotaExhaustedReason.name`）；旧记录没有这一项。
  final String? quotaReason;

  /// 这条帮助读到的材料页；重试同一次求助时按这些位置接续。
  final List<ChatUsedPage> usedPages;

  HelpEntry withMemories(List<MemoryDraft> memories) => HelpEntry(
    kind: kind,
    content: content,
    at: at,
    memories: memories,
    fromModel: fromModel,
    notices: notices,
    failureName: failureName,
    quotaReason: quotaReason,
    usedPages: usedPages,
  );

  Map<String, Object?> toJson() => {
    'kind': kind,
    'content': content,
    'at': at == null ? null : formatDateTime(at!),
    if (memories.isNotEmpty)
      'memories': [for (final memory in memories) memory.toJson()],
    if (fromModel != null) 'from_model': fromModel,
    if (notices.isNotEmpty)
      'notices': [for (final notice in notices) notice.value],
    if (failureName != null) 'model_failure': failureName,
    if (quotaReason != null) 'model_quota_reason': quotaReason,
    if (usedPages.isNotEmpty)
      'used_pages': [for (final page in usedPages) page.toJson()],
  };

  static HelpEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = value['kind'];
    final content = value['content'];
    final at = value['at'];
    final fromModel = value['from_model'];
    final notices = value['notices'];
    final failureName = value['model_failure'];
    final quotaReason = value['model_quota_reason'];
    if (kind is! String || content is! String) return null;
    final DateTime? parsedAt;
    try {
      parsedAt = at is String ? optionalDateTime(at) : null;
    } on FormatException {
      return null;
    }
    return HelpEntry(
      kind: kind,
      content: content,
      at: parsedAt,
      memories: MemoryDraft.decodeList(value['memories']),
      fromModel: fromModel is bool ? fromModel : null,
      notices: [
        if (notices is List)
          for (final notice in notices.whereType<String>())
            ?noticeFromValue(notice),
      ],
      failureName: failureName is String ? failureName : null,
      quotaReason: quotaReason is String && quotaReason.trim().isNotEmpty
          ? quotaReason.trim()
          : null,
      usedPages: [
        if (value['used_pages'] case final List raw)
          for (final page in raw) ?ChatUsedPage.fromJson(page),
      ],
    );
  }

  static List<HelpEntry> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(HelpEntry.fromJson)
          .whereType<HelpEntry>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<HelpEntry> helps) =>
      jsonEncode([for (final help in helps) help.toJson()]);
}
