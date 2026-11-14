import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/chat_message.dart';
import '../../domain/models/conversation.dart';
import '../../domain/models/material.dart';
import '../../domain/models/question.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';

export '../../domain/models/chat_message.dart';
export '../../domain/models/conversation.dart';
import '../db/write_transactions.dart';

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

  static const String _questionUserMessage =
      "COALESCE(c.question_message_id, (SELECT m.id FROM message m "
      "WHERE m.conversation_id = c.id AND m.role = 'user' "
      "ORDER BY m.id LIMIT 1))";
  static const String _firstUserContent =
      "(SELECT m.content FROM message m WHERE m.conversation_id = c.id "
      "AND m.role = 'user' AND m.id = $_questionUserMessage LIMIT 1)";
  static const String _firstUserImages =
      "(SELECT m.image_paths_json FROM message m WHERE m.conversation_id = c.id "
      "AND m.role = 'user' AND m.id = $_questionUserMessage LIMIT 1)";
  static const String _materialFileName =
      '(SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name';

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect([RawExecutor? executor]) {
    final connection = (executor ?? _db).driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

  /// 列表与“继续上次”挑的列相同，按同一组字段还原成领域模型。
  static ConversationRecord _record(
    int id,
    String? title,
    int? goalId,
    int? materialId,
    int? pageNo,
    String? materialTitle,
    String? sourceFileName,
    String entryKind,
    String status,
    String? endedAt,
    String? lastMessageAt,
    String createdAt,
    String updatedAt,
    int messageCount,
    String? preview,
    String? lastUserMessage,
    String? draftAnswer,
    String? draftUpdatedAt,
    bool hasAttempts,
    bool hasDraft,
  ) => ConversationRecord(
    id: id,
    title: title,
    goalId: goalId,
    materialId: materialId,
    pageNo: pageNo,
    materialTitle: materialTitle,
    materialIsDocx: isDocxFile(sourceFileName),
    entryKind: entryKind,
    status: status,
    endedAt: DateTime.tryParse(endedAt ?? ''),
    lastMessageAt: DateTime.tryParse(lastMessageAt ?? ''),
    createdAt: DateTime.tryParse(createdAt),
    updatedAt: DateTime.tryParse(updatedAt),
    messageCount: messageCount,
    preview: preview,
    lastUserMessage: lastUserMessage,
    draftAnswer: draftAnswer,
    draftUpdatedAt: DateTime.tryParse(draftUpdatedAt ?? ''),
    hasAttempts: hasAttempts,
    hasDraft: hasDraft,
  );

  static ConversationRecord _recordOfList(ConversationRecordsResult r) =>
      _record(
        r.id,
        r.title,
        r.goalId,
        r.materialId,
        r.pageNo,
        r.materialTitle,
        r.sourceFileName,
        r.entryKind,
        r.status,
        r.endedAt,
        r.lastMessageAt,
        r.createdAt,
        r.updatedAt,
        r.messageCount,
        r.preview,
        r.lastUserMessage,
        r.draftAnswer,
        r.draftUpdatedAt,
        r.hasAttempts,
        r.hasDraft,
      );

  static ConversationRecord _recordOfRecent(RecentlyActiveRecordsResult r) =>
      _record(
        r.id,
        r.title,
        r.goalId,
        r.materialId,
        r.pageNo,
        r.materialTitle,
        r.sourceFileName,
        r.entryKind,
        r.status,
        r.endedAt,
        r.lastMessageAt,
        r.createdAt,
        r.updatedAt,
        r.messageCount,
        r.preview,
        r.lastUserMessage,
        r.draftAnswer,
        r.draftUpdatedAt,
        r.hasAttempts,
        r.hasDraft,
      );

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
        entryKind: r.entryKind,
        status: r.status,
        endedAt: DateTime.tryParse(r.endedAt ?? ''),
        lastMessageAt: DateTime.tryParse(r.lastMessageAt ?? ''),
        createdAt: DateTime.tryParse(r.createdAt),
        updatedAt: DateTime.tryParse(r.updatedAt),
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
    imagePathsJson: r.imagePathsJson,
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
      imagePathsJson: r.imagePathsJson,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
    final attemptId = r.lastAttemptId;
    return QuestionRow(
      question: question,
      hasDraft: r.hasDraft,
      lastAttempt: attemptId == null
          ? null
          : Attempt.fromRow({
              'id': attemptId,
              'conversation_id': question.id,
              'session_id': r.lastAttemptSessionId,
              'user_answer': r.lastAttemptUserAnswer,
              'solution': r.lastAttemptSolution,
              'is_correct': r.lastAttemptIsCorrect,
              'independent': r.lastAttemptIndependent,
              'help_json': r.lastAttemptHelpJson,
              'feedback': r.lastAttemptFeedback,
              'delayed': r.lastAttemptDelayed,
              'submitted_at': r.lastAttemptSubmittedAt,
              'created_at': r.lastAttemptCreatedAt,
            }),
    );
  }

  /// 题目的出处缺省时按材料标题与页码补一条，口径与原实现相同。
  Question _question({
    required int id,
    required String stem,
    required String? sourceRef,
    required String? contextText,
    required String? materialTitle,
    required int? pageNo,
    required String? sourceFileName,
    required String? imagePathsJson,
    required String createdAt,
    required String updatedAt,
  }) {
    return _recordQuestion({
      'id': id,
      'stem': stem,
      'source_ref': sourceRef,
      'context_text': contextText,
      'image_paths_json': imagePathsJson,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'material_title': materialTitle,
      'page_no': pageNo,
      'source_file_name': sourceFileName,
    });
  }

  Question _recordQuestion(Map<String, Object?> row) {
    final question = Question.fromRow(row);
    if (question.sourceRef != null) return question;
    final title = row['material_title'] as String?;
    final pageNo = row['page_no'] as int?;
    if (title == null || pageNo == null) return question;
    return Question(
      id: question.id,
      stem: question.stem,
      sourceRef:
          '《$title》${materialPosition(pageNo, isDocx: isDocxFile(row['source_file_name'] as String?))}',
      contextText: question.contextText,
      imagePaths: question.imagePaths,
      createdAt: question.createdAt,
      updatedAt: question.updatedAt,
    );
  }

  /// 新建一条讨论；`entryKind` 记录这次求助来自文字、图片还是两者。
  Future<int> create({
    String? title,
    String entryKind = 'text',
    int? goalId,
    int? materialId,
    int? pageNo,
    String? sourceRef,
    String? contextText,
    WriteTransaction? transaction,
  }) async {
    final now = formatDateTime(_clock());
    return writeExecutor(transaction, _db).insert('conversation', {
      'title': _clean(title),
      'goal_id': goalId,
      'material_id': materialId,
      'page_no': pageNo,
      'source_ref': _clean(sourceRef),
      'context_text': _clean(contextText),
      'entry_kind': entryKind,
      'status': 'open',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<ConversationRecord?> byId(
    int conversationId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await _connect(executor)
        .conversationById(conversationId)
        .get();
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
    int? goalId,
    bool unassignedOnly = false,
    String? answerStatus,
    int? limit = 200,
    int offset = 0,
  }) async {
    final rows = await _connect()
        .conversationRecords(
          goalId ?? 0,
          unassignedOnly ? 1 : 0,
          answerStatus ?? '',
          limit ?? (1 << 30),
          limit == null ? 0 : offset,
        )
        .get();
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
    final rows = await _connect().recentlyActiveRecords(limit).get();
    return rows.map(_recordOfRecent).toList(growable: false);
  }

  /// 一条学习记录对应的题目视图：题干与图片取开始作答时确定的用户消息。
  Future<Question?> question(int conversationId) async {
    final rows = await _connect().conversationQuestion(conversationId).get();
    return rows.isEmpty ? null : _questionOf(rows.first);
  }

  /// 有作答记录的学习记录，按最近更新倒序。
  ///
  /// [conversationIds] 只取这些记录；记录页按页读取时用它把题目视图限制在
  /// 当前这一页，不再为整库记录各读一次首条消息与最近一次作答。
  Future<List<QuestionRow>> questionRows({
    int? limit,
    Iterable<int>? conversationIds,
  }) async {
    final ids = conversationIds?.toSet().toList(growable: false);
    if (ids != null && ids.isEmpty) return const [];
    final rows = await _connect()
        .questionRows(jsonEncode(ids ?? const <int>[]), limit ?? (1 << 30))
        .get();
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
    int? goalId,
    int? materialId,
    int? conversationId,
    Set<int> broughtAttemptIds = const {},
  }) async {
    final where = <String>['a.submitted_at IS NOT NULL'];
    final args = <Object?>[];
    final scopes = <String>[];
    if (goalId != null) {
      scopes.add('c.goal_id = ?');
      args.add(goalId);
    }
    if (materialId != null) {
      scopes.add('c.material_id = ?');
      args.add(materialId);
    }
    if (goalId == null && materialId == null) {
      final restricted = <String>[];
      if (conversationId != null) {
        restricted.add('c.id = ?');
        args.add(conversationId);
      }
      if (broughtAttemptIds.isNotEmpty) {
        restricted.add(
          'a.id IN (${List.filled(broughtAttemptIds.length, '?').join(', ')})',
        );
        args.addAll(broughtAttemptIds);
      }
      scopes.add(
        '(c.goal_id IS NULL AND c.material_id IS NULL '
        'AND (${restricted.isEmpty ? '0' : restricted.join(' OR ')}))',
      );
    } else {
      // 有目标或材料时仍取同目标、同材料与无归属的记录，再放行本轮带入的作答。
      scopes.add('(c.goal_id IS NULL AND c.material_id IS NULL)');
      if (broughtAttemptIds.isNotEmpty) {
        scopes.add(
          'a.id IN (${List.filled(broughtAttemptIds.length, '?').join(', ')})',
        );
        args.addAll(broughtAttemptIds);
      }
    }
    where.add('(${scopes.join(' OR ')})');
    if (limit != null) args.add(limit);
    final rows = await _db.rawQuery('''
      SELECT
        a.id AS attempt_id,
        a.conversation_id AS attempt_conversation_id,
        a.session_id AS attempt_session_id,
        a.user_answer AS attempt_user_answer,
        a.solution AS attempt_solution,
        a.is_correct AS attempt_is_correct,
        a.independent AS attempt_independent,
        a.help_json AS attempt_help_json,
        a.feedback AS attempt_feedback,
        a.delayed AS attempt_delayed,
        a.submitted_at AS attempt_submitted_at,
        a.created_at AS attempt_created_at,
        c.id AS question_id,
        c.source_ref AS question_source_ref,
        c.context_text AS question_context_text,
        c.page_no AS question_page_no,
        c.created_at AS question_created_at,
        c.updated_at AS question_updated_at,
        (SELECT title FROM material WHERE id = c.material_id)
          AS question_material_title,
        $_materialFileName,
        $_firstUserContent AS question_stem,
        $_firstUserImages AS question_image_paths_json
      FROM attempt a
      JOIN conversation c ON c.id = a.conversation_id
      WHERE ${where.join(' AND ')}
      ORDER BY a.submitted_at DESC, a.id DESC
      ${limit == null ? '' : 'LIMIT ?'}
      ''', args);
    return rows
        .map((row) {
          final attempt = Attempt.fromRow({
            'id': row['attempt_id'],
            'conversation_id': row['attempt_conversation_id'],
            'session_id': row['attempt_session_id'],
            'user_answer': row['attempt_user_answer'],
            'solution': row['attempt_solution'],
            'is_correct': row['attempt_is_correct'],
            'independent': row['attempt_independent'],
            'help_json': row['attempt_help_json'],
            'feedback': row['attempt_feedback'],
            'delayed': row['attempt_delayed'],
            'submitted_at': row['attempt_submitted_at'],
            'created_at': row['attempt_created_at'],
          });
          final question = _recordQuestion({
            'id': row['question_id'],
            'source_ref': row['question_source_ref'],
            'context_text': row['question_context_text'],
            'page_no': row['question_page_no'],
            'created_at': row['question_created_at'],
            'updated_at': row['question_updated_at'],
            'material_title': row['question_material_title'],
            'source_file_name': row['source_file_name'],
            'stem': row['question_stem'],
            'image_paths_json': row['question_image_paths_json'],
          });
          return AttemptWithQuestion(attempt: attempt, question: question);
        })
        .toList(growable: false);
  }

  Future<Attempt?> latestSubmitted(int conversationId) async {
    final rows = await _db.query(
      'attempt',
      where: 'conversation_id = ? AND submitted_at IS NOT NULL',
      whereArgs: [conversationId],
      orderBy: 'submitted_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Attempt.fromRow(rows.first);
  }

  /// 最近的消息，按编号升序返回；[limit] 为空时返回全部。
  ///
  /// 讨论界面用 [historyPage] 分页，这里给需要完整历史的调用方（例如把
  /// 讨论里的回答导入作答帮助）使用。
  Future<List<ChatMessage>> recent(
    int conversationId, {
    int? limit = 100,
    WriteTransaction? transaction,
  }) async {
    final rows = await writeExecutor(transaction, _db).query(
      'message',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows
        .map(ChatMessage.fromRow)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  Future<({List<ChatMessage> messages, bool hasOlder})> historyPage(
    int conversationId, {
    int? beforeMessageId,
    int limit = 50,
  }) async {
    final where = <String>['conversation_id = ?'];
    final args = <Object?>[conversationId];
    if (beforeMessageId != null) {
      where.add('id < ?');
      args.add(beforeMessageId);
    }
    final rows = await _db.query(
      'message',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'id DESC',
      limit: limit + 1,
    );
    final hasOlder = rows.length > limit;
    final page = rows.take(limit).map(ChatMessage.fromRow).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return (messages: page, hasOlder: hasOlder);
  }

  /// 这条记录的第一条用户消息；[beforeMessageId] 为空时取整条记录的第一条。
  ///
  /// 提示词的预算之外仍要保留这次讨论的原问题；重答时给出正在重答的
  /// [beforeMessageId] 之前的第一条，避免把这条问题又放进历史。
  Future<ChatMessage?> firstUserMessage(
    int conversationId, {
    int? beforeMessageId,
  }) => _edgeUserMessage(
    conversationId,
    beforeMessageId: beforeMessageId,
    first: true,
  );

  /// 这条记录的最后一条用户消息；重答用它取问题，不读回整条讨论。
  Future<ChatMessage?> lastUserMessage(int conversationId) =>
      _edgeUserMessage(conversationId, first: false);

  Future<ChatMessage?> _edgeUserMessage(
    int conversationId, {
    required bool first,
    int? beforeMessageId,
  }) async {
    final where = <String>[
      'conversation_id = ?',
      "role = 'user'",
      "(TRIM(content) != '' OR image_paths_json IS NOT NULL)",
    ];
    final args = <Object?>[conversationId];
    if (beforeMessageId != null) {
      where.add('id < ?');
      args.add(beforeMessageId);
    }
    final rows = await _db.query(
      'message',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: first ? 'id' : 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : ChatMessage.fromRow(rows.first);
  }

  Future<ChatMessage?> messageById(
    int messageId, {
    WriteTransaction? transaction,
  }) async {
    final rows = await writeExecutor(
      transaction,
      _db,
    ).query('message', where: 'id = ?', whereArgs: [messageId], limit: 1);
    return rows.isEmpty ? null : ChatMessage.fromRow(rows.single);
  }

  /// 追加一条消息；只有图片时 `content` 可以为空。
  Future<ChatMessage> append(
    int conversationId, {
    required String role,
    String content = '',
    List<String> imagePaths = const [],
    Map<String, Object?>? structured,
    WriteTransaction? transaction,
  }) async {
    if (role != 'user' && role != 'assistant' && role != 'system') {
      throw ArgumentError("role 只能是 'user'、'assistant' 或 'system'");
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
    final structuredJson = structured == null ? null : jsonEncode(structured);
    final writer = writeExecutor(transaction, _db);
    final id = await writer.insert('message', {
      'conversation_id': conversationId,
      'role': role,
      'content': text,
      'image_paths_json': ChatMessage.encodePaths(paths),
      'structured_json': structuredJson,
      'created_at': stamp,
    });
    await writer.update(
      'conversation',
      {'updated_at': stamp, 'last_message_at': stamp},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: text,
      imagePaths: paths,
      createdAt: now,
      structuredJson: structuredJson,
    );
  }

  /// 记下用户明确选择的归属；传入空值表示改回无归属。
  Future<void> setGoal(int conversationId, int? goalId) async {
    await _db.update(
      'conversation',
      {'goal_id': goalId, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 记下这次讨论依据的材料与页码；传空表示不再带入材料。
  Future<void> setMaterial(
    int conversationId, {
    required int? materialId,
    int? pageNo,
  }) async {
    await _db.update(
      'conversation',
      {
        'material_id': materialId,
        'page_no': materialId == null ? null : pageNo,
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 确定这条记录的原题消息。
  ///
  /// 用户在讨论里先问方法、后来才补完整题目时，开始作答要以当时的那条消息
  /// 为原题，不能一直沿用它前面那条更早的求助；找到后不再随后的追问改动。
  Future<void> setQuestionMessage(
    int conversationId,
    int messageId, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(transaction, _db).update(
      'conversation',
      {'question_message_id': messageId},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 结束一次求助；之后再发消息会重新打开同一条讨论。
  Future<void> end(int conversationId) async {
    final now = formatDateTime(_clock());
    await _db.update(
      'conversation',
      {'status': 'ended', 'ended_at': now, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 清空一条学习记录：删掉消息与记录；作答随外键级联删除。
  ///
  /// 场次没有指向记录的列，只能从作答反查；这条记录清空后如果某个场次
  /// 已经没有其他作答，就一起删掉，避免留下永远不结束的后台场次。
  Future<List<String>> clear(int conversationId) async {
    return _db.transaction((txn) async {
      final sessionRows = await txn.query(
        'attempt',
        columns: ['session_id'],
        where: 'conversation_id = ? AND session_id IS NOT NULL',
        whereArgs: [conversationId],
      );
      final sessionIds = <int>{
        for (final row in sessionRows) row['session_id']! as int,
      };
      final rows = await txn.query(
        'message',
        columns: ['image_paths_json'],
        where: 'conversation_id = ? AND image_paths_json IS NOT NULL',
        whereArgs: [conversationId],
      );
      final imagePaths = <String>{};
      for (final row in rows) {
        final encoded = row['image_paths_json'] as String?;
        if (encoded == null || encoded.isEmpty) continue;
        try {
          final decoded = jsonDecode(encoded);
          if (decoded is List) imagePaths.addAll(decoded.whereType<String>());
        } catch (_) {
          // 损坏的路径记录不应阻止清空；启动清理会回收失去引用的文件。
        }
      }
      await txn.delete(
        'message',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
      );
      await txn.delete(
        'conversation',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      for (final sessionId in sessionIds) {
        final remaining = await txn.query(
          'attempt',
          columns: ['id'],
          where: 'session_id = ?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (remaining.isEmpty) {
          await txn.delete(
            'study_session',
            where: 'id = ?',
            whereArgs: [sessionId],
          );
        }
      }
      return imagePaths.toList(growable: false);
    });
  }

  Future<void> reopen(
    int conversationId, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(transaction, _db).update(
      'conversation',
      {
        'status': 'open',
        'ended_at': null,
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// 接受一条下一步建议后，在原消息里记下标题与提交编号；重新打开不会重复
  /// 保存，回执可以按提交撤销。
  Future<void> markNextStepAccepted(
    int messageId,
    String title, {
    String? stepId,
    required int commitId,
    WriteTransaction? transaction,
  }) async {
    await _updateSuggestionState(
      messageId,
      title,
      stepId: stepId,
      state: 'accepted',
      commitId: commitId,
      transaction: transaction,
    );
  }

  Map<String, Object?> _decodeStructured(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?>
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } catch (_) {
      return {};
    }
  }

  Future<void> markNextStepDismissed(
    int messageId,
    String title, {
    String? stepId,
    WriteTransaction? transaction,
  }) => _updateSuggestionState(
    messageId,
    title,
    stepId: stepId,
    state: 'dismissed',
    transaction: transaction,
  );

  /// 记下一条记忆卡片的处理结果：待确认、已写入或已忽略。
  Future<void> setMemoryItemStatus(
    int messageId,
    String itemId, {
    required String status,
    int? commitId,
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.query(
      'message',
      columns: ['structured_json'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final structured = _decodeStructured(rows.single['structured_json']);
    final raw = structured['memory_items'];
    if (raw is! List) return;
    final items = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final copy = <String, Object?>{};
      item.forEach((key, value) {
        if (key is String) copy[key] = value;
      });
      items.add(copy);
    }
    var found = false;
    for (final item in items) {
      if (item['id'] != itemId) continue;
      item['status'] = status;
      if (commitId != null) item['commit_id'] = commitId;
      found = true;
    }
    if (!found) return;
    structured['memory_items'] = items;
    await executor.update(
      'message',
      {'structured_json': jsonEncode(structured)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> _updateSuggestionState(
    int messageId,
    String title, {
    String? stepId,
    required String state,
    int? commitId,
    WriteTransaction? transaction,
  }) async {
    final database = writeExecutor(transaction, _db);
    final rows = await database.query(
      'message',
      columns: ['structured_json'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final structured = _decodeStructured(rows.single['structured_json']);
    final titles = _stringList(structured[state]);
    if (!titles.contains(title)) titles.add(title);
    structured[state] = titles;
    if (stepId != null) {
      final key = '${state}_ids';
      final ids = _stringList(structured[key]);
      if (!ids.contains(stepId)) ids.add(stepId);
      structured[key] = ids;
    }
    if (commitId != null) {
      final operations = _operationList(structured['operations'])
        ..removeWhere((item) => item['commit_id'] == commitId);
      operations.add({'commit_id': commitId, 'text': '已添加安排：$title'});
      structured['operations'] = operations;
    }
    await database.update(
      'message',
      {'structured_json': jsonEncode(structured)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  static List<String> _stringList(Object? raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
  ];

  static List<Map<String, Object?>> _operationList(Object? raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is Map && item['commit_id'] is int && item['text'] is String)
          {
            'commit_id': item['commit_id'] as int,
            'text': item['text'] as String,
          },
  ];

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
