import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/chat_message.dart';
import '../../domain/models/chat_message_payload.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/material.dart';
import '../../domain/models/memory_draft.dart';
import '../../domain/models/question.dart';
import '../../domain/rules/attachments.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/text.dart';
import '../../domain/rules/uuid_v7.dart';

export '../../domain/models/chat_message.dart';
export '../../domain/models/conversation.dart';
import '../db/write_transactions.dart';

/// 记录列表与“继续上次”挑的列相同，映射按名字转交，不看位置。
///
/// 相邻的 `String?` 列有好几个（`title`、`goalId`、`materialId`、`endedAt`），
/// 位置参数写错顺序编译器看不出来；具名记录把每一列写清楚。
typedef ConversationRecordColumns = ({
  String id,
  String? title,
  String? goalId,
  String? materialId,
  int? pageNo,
  String? materialTitle,
  String? sourceFileName,
  String entryKind,
  String? endedAt,
  String createdAt,
  String updatedAt,
  int messageCount,
  String? preview,
  String? lastUserMessage,
  String? draftAnswer,
  String? draftUpdatedAt,
  bool hasAttempts,
  bool hasDraft,
});

/// 01 `conversation` / `message`：一条讨论就是一条学习记录。
///
/// 讨论可以没有目标归属，也可以只有图片消息；带入材料时记录材料与页码。
/// 题目不再单独存表：题干与图片取 `question_message_id` 指向的用户消息，作答
/// 由 `attempt` 直接指向这条记录。结构化回答、引用、下一步建议与已接受的
/// 建议一起存进 `structured_json`。
class ConversationRepository {
  ConversationRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  /// 消息整行还原成模型；图片字段按文件名列表解析。
  static ChatMessage _messageOf(MessageRow row) => ChatMessage(
    id: row.id,
    conversationId: row.conversationId,
    role: MessageRole.fromValue(row.role),
    content: row.content,
    imagePaths: decodeStoredAttachmentPaths(row.imageHashesJson),
    createdAt: optionalDateTime(row.createdAt),
    payload: ChatMessagePayload.decode(row.structuredJson),
  );

  /// 作答整行直接还原成模型；布尔列已经是 bool，提示条目统一走 [HelpEntry.decodeList]。
  static Attempt _attemptOf(AttemptRow row) => Attempt(
    id: row.id,
    conversationId: row.conversationId,
    sessionId: row.sessionId,
    redoOfAttemptId: row.redoOfAttemptId,
    userAnswer: row.userAnswer,
    solution: row.solution,
    isCorrect: row.isCorrect,
    independent: row.independent,
    helps: HelpEntry.decodeList(row.helpJson),
    feedback: row.feedback,
    delayed: row.delayed,
    submittedAt: optionalDateTime(row.submittedAt),
    createdAt: optionalDateTime(row.createdAt),
  );

  AttemptWithQuestion _attemptWithQuestionOf(RecentSubmittedResult r) {
    final attempt = Attempt(
      id: r.attemptId,
      conversationId: r.attemptConversationId,
      sessionId: r.attemptSessionId,
      userAnswer: r.attemptUserAnswer,
      solution: r.attemptSolution,
      isCorrect: r.attemptIsCorrect,
      independent: r.attemptIndependent,
      helps: HelpEntry.decodeList(r.attemptHelpJson),
      feedback: r.attemptFeedback,
      delayed: r.attemptDelayed,
      submittedAt: optionalDateTime(r.attemptSubmittedAt),
      createdAt: optionalDateTime(r.attemptCreatedAt),
    );
    return AttemptWithQuestion(
      attempt: attempt,
      question: _question(
        id: r.questionId,
        stem: r.questionStem ?? '',
        sourceRef: r.questionSourceRef,
        contextText: r.questionContextText,
        materialTitle: r.questionMaterialTitle,
        pageNo: r.questionPageNo,
        sourceFileName: r.sourceFileName,
        imageHashesJson: r.questionImageHashesJson,
        createdAt: r.questionCreatedAt,
        updatedAt: r.questionUpdatedAt,
      ),
    );
  }

  /// 列表与“继续上次”挑的列相同，按同一组字段还原成领域模型。
  ///
  /// 讨论是否结束由 `ended_at` 推出，没有单独的状态列（审查 S20）。
  static ConversationRecord _record(ConversationRecordColumns row) =>
      ConversationRecord(
        id: row.id,
        title: row.title,
        goalId: row.goalId,
        materialId: row.materialId,
        pageNo: row.pageNo,
        materialTitle: row.materialTitle,
        materialIsDocx: isDocxFile(row.sourceFileName),
        entryKind: EntryKind.fromValue(row.entryKind),
        endedAt: optionalDateTime(row.endedAt),
        createdAt: requiredDateTime(row.createdAt),
        updatedAt: requiredDateTime(row.updatedAt),
        messageCount: row.messageCount,
        preview: row.preview,
        lastUserMessage: row.lastUserMessage,
        draftAnswer: row.draftAnswer,
        draftUpdatedAt: optionalDateTime(row.draftUpdatedAt),
        hasAttempts: row.hasAttempts,
        hasDraft: row.hasDraft,
      );

  static ConversationRecord _recordOfList(ConversationRecordsResult r) =>
      _record((
        id: r.id,
        title: r.title,
        goalId: r.goalId,
        materialId: r.materialId,
        pageNo: r.pageNo,
        materialTitle: r.materialTitle,
        sourceFileName: r.sourceFileName,
        entryKind: r.entryKind,
        endedAt: r.endedAt,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        messageCount: r.messageCount,
        preview: r.preview,
        lastUserMessage: r.lastUserMessage,
        draftAnswer: r.draftAnswer,
        draftUpdatedAt: r.draftUpdatedAt,
        hasAttempts: r.hasAttempts,
        hasDraft: r.hasDraft,
      ));

  static ConversationRecord _recordOfRecent(RecentlyActiveRecordsResult r) =>
      _record((
        id: r.id,
        title: r.title,
        goalId: r.goalId,
        materialId: r.materialId,
        pageNo: r.pageNo,
        materialTitle: r.materialTitle,
        sourceFileName: r.sourceFileName,
        entryKind: r.entryKind,
        endedAt: r.endedAt,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        messageCount: r.messageCount,
        preview: r.preview,
        lastUserMessage: r.lastUserMessage,
        draftAnswer: r.draftAnswer,
        draftUpdatedAt: r.draftUpdatedAt,
        hasAttempts: r.hasAttempts,
        hasDraft: r.hasDraft,
      ));

  /// 按标识取的那条不读消息条数与草稿内容，未读的列按空值还原，与原来一致。
  static ConversationRecord _recordOf(ConversationByIdResult r) =>
      ConversationRecord(
        id: r.id,
        title: r.title,
        goalId: r.goalId,
        materialId: r.materialId,
        pageNo: r.pageNo,
        materialTitle: r.materialTitle,
        materialIsDocx: isDocxFile(r.sourceFileName),
        entryKind: EntryKind.fromValue(r.entryKind),
        endedAt: optionalDateTime(r.endedAt ?? ''),
        lastMessageAt: optionalDateTime(r.updatedAt),
        createdAt: requiredDateTime(r.createdAt),
        updatedAt: requiredDateTime(r.updatedAt),
        hasAttempts: r.hasAttempts,
        hasDraft: r.hasDraft,
      );

  Question _questionOf(ConversationQuestionResult r) => _question(
    id: r.id,
    stem: r.stem ?? '',
    sourceRef: r.sourceRef,
    contextText: r.contextText,
    materialTitle: r.materialTitle,
    pageNo: r.pageNo,
    sourceFileName: r.sourceFileName,
    imageHashesJson: r.imageHashesJson,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  QuestionRow _questionRowOf(QuestionRowsResult r) {
    final question = _question(
      id: r.id,
      stem: r.stem ?? '',
      sourceRef: r.sourceRef,
      contextText: r.contextText,
      materialTitle: r.materialTitle,
      pageNo: r.pageNo,
      sourceFileName: r.sourceFileName,
      imageHashesJson: r.imageHashesJson,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
    final attemptId = r.lastAttemptId;
    return QuestionRow(
      question: question,
      hasDraft: r.hasDraft,
      lastAttempt: attemptId == null
          ? null
          : Attempt(
              id: attemptId,
              conversationId: question.id,
              sessionId: r.lastAttemptSessionId,
              userAnswer: r.lastAttemptUserAnswer,
              solution: r.lastAttemptSolution,
              isCorrect: r.lastAttemptIsCorrect,
              independent: r.lastAttemptIndependent,
              helps: HelpEntry.decodeList(r.lastAttemptHelpJson),
              feedback: r.lastAttemptFeedback,
              // 左连接没有作答时这一列也是空，按未标记处理。
              delayed: r.lastAttemptDelayed ?? false,
              submittedAt: optionalDateTime(r.lastAttemptSubmittedAt),
              createdAt: optionalDateTime(r.lastAttemptCreatedAt),
            ),
    );
  }

  /// 题目的出处缺省时按材料标题与页码补一条，口径与原实现相同。
  Question _question({
    required String id,
    required String stem,
    required String? sourceRef,
    required String? contextText,
    required String? materialTitle,
    required int? pageNo,
    required String? sourceFileName,
    required String? imageHashesJson,
    required String createdAt,
    required String updatedAt,
  }) {
    final title = materialTitle;
    final page = pageNo;
    return Question(
      id: id,
      stem: stem,
      sourceRef:
          sourceRef ??
          (title == null || page == null
              ? null
              : '《$title》${materialPosition(page, isDocx: isDocxFile(sourceFileName))}'),
      contextText: contextText,
      imagePaths: decodeStoredAttachmentPaths(imageHashesJson),
      createdAt: optionalDateTime(createdAt),
      updatedAt: optionalDateTime(updatedAt),
    );
  }

  /// 新建一条讨论；`entryKind` 记录这次求助来自文字、图片还是两者。
  Future<String> create({
    String? title,
    EntryKind entryKind = EntryKind.text,
    String? goalId,
    String? materialId,
    int? pageNo,
    String? sourceRef,
    String? contextText,
    WriteTransaction? transaction,
  }) async {
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertConversationRecord(
        id,
        nullableText(title),
        goalId,
        materialId,
        pageNo,
        nullableText(sourceRef),
        nullableText(contextText),
        entryKind.value,
        now,
      ),
    );
    return id;
  }

  Future<ConversationRecord?> byId(
    String conversationId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.selectGenerated(
      (db) => db.conversationById(conversationId).get(),
    );
    return rows.isEmpty ? null : _recordOf(rows.first);
  }

  /// 记录列表，按最近更新时间倒序，并带出消息条数、最后一条消息的摘要、
  /// 最后一条用户消息与未提交草稿，供“继续上次”判断排序与展示线索。
  ///
  /// [answerStatus] 按最近一次已提交作答的判定筛选，口径与 [QuestionRow.status]
  /// 相同；`open` 只包含已经有作答记录、但还没有提交过的记录。筛选放在查询里，
  /// 界面不必先读回全部记录再逐条比较。
  ///
  /// [limit] 与 [offset] 用于分页读取。排序键固定，翻页不会重复或漏行；读取量
  /// 只跟这一页的条数有关，不随库里的记录总数增长。
  Future<List<ConversationRecord>> list({
    String? goalId,
    bool unassignedOnly = false,
    String? answerStatus,
    int? limit = 200,
    int offset = 0,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .conversationRecords(
            goalId,
            unassignedOnly ? 1 : 0,
            answerStatus,
            limit,
            limit == null ? 0 : offset,
          )
          .get(),
    );
    return rows.map(_recordOfList).toList(growable: false);
  }

  /// “继续上次”的候选记录：按最近一次学习行为取前 [limit] 条。
  ///
  /// 一条记录最近一次学习行为的时间，是 `conversation.updated_at` 与未提交
  /// 草稿保存时间中较晚的一个；写草稿不改 `updated_at`，只看后者会把刚写下的
  /// 草稿排到后面。两类时间各自排名后取并集：任何一条进入全局前 [limit] 名的
  /// 记录，其时间来自哪一类，就一定在那一类的前 [limit] 名里，所以结果与读全库
  /// 再排序相同，读取量只跟 [limit] 有关，不随记录总数增长。
  Future<List<ConversationRecord>> listRecentlyActive({int limit = 4}) async {
    if (limit <= 0) return const [];
    final rows = await _db.selectGenerated(
      (db) => db.recentlyActiveRecords(limit).get(),
    );
    return rows.map(_recordOfRecent).toList(growable: false);
  }

  /// 一条学习记录对应的题目视图：题干与图片取开始作答时确定的用户消息。
  Future<Question?> question(String conversationId) async {
    final rows = await _db.selectGenerated(
      (db) => db.conversationQuestion(conversationId).get(),
    );
    return rows.isEmpty ? null : _questionOf(rows.first);
  }

  /// 有作答记录的学习记录，按最近更新倒序。
  ///
  /// [conversationIds] 只取这些记录；记录页按页读取时用它把题目视图限制在
  /// 当前这一页，不再为整库记录各读一次首条消息与最近一次作答。
  Future<List<QuestionRow>> questionRows({
    int? limit,
    Iterable<String>? conversationIds,
  }) async {
    final ids = conversationIds?.toSet().toList(growable: false);
    if (ids != null && ids.isEmpty) return const [];
    final rows = await _db.selectGenerated(
      (db) =>
          db.questionRows(ids == null ? null : jsonEncode(ids), limit).get(),
    );
    return [for (final row in rows) _questionRowOf(row)];
  }

  /// 最近提交的作答，带上所属记录，给首页与模型上下文用。
  ///
  /// [limit] 为空时返回范围内全部已提交作答，不按条数截断；范围由这次请求的
  /// 目标或材料决定，避免把其他目标的作答也带进回答上下文。没有明确归属时
  /// 只取当前这条讨论的作答，另外放行用户本轮带入的作答标识；其他无归属
  /// 讨论的作答不进入这次上下文。
  Future<List<AttemptWithQuestion>> recentSubmitted({
    int? limit = 20,
    String? goalId,
    String? materialId,
    String? conversationId,
    Set<String> broughtAttemptIds = const {},
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .recentSubmitted(
            goalId,
            materialId,
            conversationId,
            jsonEncode(broughtAttemptIds.toList(growable: false)),
            limit,
          )
          .get(),
    );
    return [for (final row in rows) _attemptWithQuestionOf(row)];
  }

  Future<Attempt?> latestSubmitted(String conversationId) async {
    final row = await _db.selectGenerated(
      (db) => db.latestSubmittedAttempt(conversationId).getSingleOrNull(),
    );
    return row == null ? null : _attemptOf(row);
  }

  /// 最近的消息，按编号升序返回；[limit] 为空时返回全部。
  ///
  /// 讨论界面用 [historyPage] 分页，这里给需要完整历史的调用方（例如把
  /// 讨论里的回答导入作答帮助）使用。
  Future<List<ChatMessage>> recent(
    String conversationId, {
    int? limit = 100,
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.selectGenerated(
      (db) => db.recentMessages(conversationId, limit).get(),
    );
    return rows
        .map(_messageOf)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  Future<({List<ChatMessage> messages, bool hasOlder})> historyPage(
    String conversationId, {
    String? beforeMessageId,
    int limit = 50,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db.messagesPage(conversationId, beforeMessageId, limit + 1).get(),
    );
    final hasOlder = rows.length > limit;
    final page = rows.take(limit).map(_messageOf).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return (messages: page, hasOlder: hasOlder);
  }

  /// 这条记录的第一条用户消息；[beforeMessageId] 为空时取整条记录的第一条。
  ///
  /// 提示词的预算之外仍要保留这次讨论的原问题；重答时给出正在重答的
  /// [beforeMessageId] 之前的第一条，避免把这条问题又放进历史。
  Future<ChatMessage?> firstUserMessage(
    String conversationId, {
    String? beforeMessageId,
  }) => _edgeUserMessage(
    conversationId,
    beforeMessageId: beforeMessageId,
    first: true,
  );

  /// 这条记录的最后一条用户消息；重答用它取问题，不读回整条讨论。
  Future<ChatMessage?> lastUserMessage(String conversationId) =>
      _edgeUserMessage(conversationId, first: false);

  Future<ChatMessage?> _edgeUserMessage(
    String conversationId, {
    required bool first,
    String? beforeMessageId,
  }) async {
    final row = await _db.selectGenerated(
      (db) => first
          ? db
                .firstUserMessage(conversationId, beforeMessageId)
                .getSingleOrNull()
          : db.lastUserMessage(conversationId).getSingleOrNull(),
    );
    return row == null ? null : _messageOf(row);
  }

  Future<ChatMessage?> messageById(
    String messageId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.messageById(messageId).getSingleOrNull(),
    );
    return row == null ? null : _messageOf(row);
  }

  /// 追加一条消息；只有图片时 `content` 可以为空。
  ///
  /// 角色只有用户、搭子与系统三种真实取值，未知值不写库，避免把坏数据留给
  /// 后面的读取与提示词拼装。
  Future<ChatMessage> append(
    String conversationId, {
    required MessageRole role,
    String content = '',
    List<String> imagePaths = const [],
    ChatMessagePayload? payload,
    WriteTransaction? transaction,
  }) async {
    if (role == MessageRole.unknown) {
      throw ArgumentError('消息角色不能为空或未知');
    }
    final text = content.trim();
    final paths = imagePaths
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
    if (text.isEmpty && paths.isEmpty) {
      throw ArgumentError('消息不能为空');
    }
    final now = _clock();
    final stamp = formatDateTime(now);
    final structuredJson = payload?.encode();
    final writer = writeExecutor(transaction, _db);
    final id = newUuidV7();
    await writer.writeGenerated(
      (db) => db.insertConversationMessage(
        id,
        conversationId,
        role.value,
        text,
        ChatMessage.encodePaths(paths),
        structuredJson,
        stamp,
      ),
    );
    await writer.writeGenerated(
      (db) => db.recordLastMessageTime(stamp, conversationId),
    );
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: text,
      imagePaths: paths,
      createdAt: now,
      payload: payload,
    );
  }

  /// 记下用户明确选择的归属；传入空值表示改回无归属。
  Future<void> setGoal(String conversationId, String? goalId) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated(
      (db) => db.setConversationGoal(goalId, stamp, conversationId),
    );
  }

  /// 记下这次讨论依据的材料与页码；传空表示不再带入材料。
  Future<void> setMaterial(
    String conversationId, {
    required String? materialId,
    int? pageNo,
  }) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated(
      (db) => db.setConversationMaterial(
        materialId,
        materialId == null ? null : pageNo,
        stamp,
        conversationId,
      ),
    );
  }

  /// 确定这条记录的原题消息。
  ///
  /// 用户在讨论里先问方法、后来才补完整题目时，开始作答要以当时的那条消息
  /// 为原题，不能一直沿用它前面那条更早的求助；找到后不再随后的追问改动。
  Future<void> setQuestionMessage(
    String conversationId,
    String messageId, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setQuestionMessage(messageId, conversationId));
  }

  /// 结束一次求助；之后再发消息会重新打开同一条讨论。
  Future<void> end(String conversationId) async {
    final now = formatDateTime(_clock());
    await _db.writeGenerated((db) => db.endConversation(now, conversationId));
  }

  /// 清空一条学习记录：删掉消息与记录；作答随外键级联删除。
  ///
  /// 场次没有指向记录的列，只能从作答反查；这条记录清空后如果某个场次
  /// 已经没有其他作答，就一起删掉，避免留下永远不结束的后台场次。
  Future<List<String>> clear(
    String conversationId, {
    WriteTransaction? transaction,
  }) async {
    final txn = writeExecutor(transaction, _db);
    final linkedSessionIds = await txn.selectGenerated(
      (db) => db.sessionIdsOfConversation(conversationId).get(),
    );
    final sessionIds = <String>{for (final id in linkedSessionIds) ?id};
    final encodedPaths = await txn.selectGenerated(
      (db) => db.imageHashesOfConversation(conversationId).get(),
    );
    final imagePaths = <String>{};
    for (final encoded in encodedPaths) {
      if (encoded == null || encoded.isEmpty) continue;
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is List) imagePaths.addAll(decoded.whereType<String>());
      } catch (_) {
        // 损坏的路径记录不应阻止清空；启动清理会回收失去引用的文件。
      }
    }
    await txn.writeGenerated(
      (db) => db.deleteConversationMessages(conversationId),
    );
    await txn.writeGenerated(
      (db) => db.deleteConversationRecord(conversationId),
    );
    for (final sessionId in sessionIds) {
      final remainingId = await txn.selectGenerated(
        (db) => db.attemptsInSession(sessionId).getSingleOrNull(),
      );
      if (remainingId == null) {
        await txn.writeGenerated((db) => db.deleteStudySession(sessionId));
      }
    }
    return imagePaths.toList(growable: false);
  }

  Future<void> reopen(
    String conversationId, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.reopenConversation(stamp, conversationId));
  }

  /// 接受一条下一步建议后，在原消息里记下标题与提交编号；重新打开不会重复
  /// 保存，回执可以按提交撤销。
  Future<void> markNextStepAccepted(
    String messageId,
    String title, {
    String? stepId,
    required int commitId,
    WriteTransaction? transaction,
  }) async {
    await _updatePayload(
      messageId,
      transaction: transaction,
      update: (payload) =>
          payload.acceptedStep(title, stepId: stepId, commitId: commitId),
    );
  }

  Future<void> markNextStepDismissed(
    String messageId,
    String title, {
    String? stepId,
    WriteTransaction? transaction,
  }) async {
    await _updatePayload(
      messageId,
      transaction: transaction,
      update: (payload) => payload.dismissedStep(title, stepId: stepId),
    );
  }

  /// 记下一条记忆卡片的处理结果：待确认、已写入或已忽略。
  Future<void> setMemoryItemStatus(
    String messageId,
    String itemId, {
    required MemoryCardStatus status,
    int? commitId,
    WriteTransaction? transaction,
  }) async {
    await _updatePayload(
      messageId,
      transaction: transaction,
      update: (payload) =>
          payload.memoryItemStatus(itemId, status, commitId: commitId),
    );
  }

  /// 读出消息的结构化补充，改完写回；没有这条消息或没有改动时不写。
  Future<ChatMessagePayload?> _updatePayload(
    String messageId, {
    required WriteTransaction? transaction,
    required ChatMessagePayload? Function(ChatMessagePayload payload) update,
  }) async {
    final database = writeExecutor(transaction, _db);
    final message = await database.selectGenerated(
      (db) => db.messageById(messageId).getSingleOrNull(),
    );
    if (message == null) return null;
    final current = ChatMessagePayload.decode(message.structuredJson);
    final updated = update(current ?? const ChatMessagePayload());
    if (updated == null || updated.isEmpty) return null;
    await database.writeGenerated(
      (db) => db.setMessageStructuredState(updated.encode(), messageId),
    );
    return updated;
  }
}
