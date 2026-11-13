import '../db/raw_executor.dart';

import '../../domain/models/evidence.dart';
import '../../domain/models/material.dart';
import '../../domain/models/question.dart';
import '../../domain/rules/embedding.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/query_shape.dart';
import '../../domain/rules/search_terms.dart';

/// 一条跨次作答：作答本身、所属记录与题目出处。
class ThreadAttempt {
  const ThreadAttempt({
    required this.attempt,
    required this.conversationId,
    required this.stem,
    this.sourceRef,
    this.materialId,
    this.pageNo,
    this.goalId,
  });

  final Attempt attempt;
  final int conversationId;
  final String stem;
  final String? sourceRef;
  final int? materialId;
  final int? pageNo;
  final int? goalId;
}

/// 可进入语义索引的一条来源：定位、用于嵌入的正文与读取时的来源版本。
class SemanticSource {
  const SemanticSource({
    required this.locator,
    required this.content,
    required this.sourceVersion,
    this.updatedAt,
  });

  final SemanticLocator locator;
  final String content;
  final String sourceVersion;
  final DateTime? updatedAt;
}

/// 一批用户查找候选继续向后读取的位置；每种来源分别记主键或提交时间。
class SearchCursor {
  const SearchCursor({
    this.materialPage,
    this.messageId,
    this.questionId,
    this.answerSubmittedAt,
    this.answerId,
  });

  /// 材料页按 `(material_id DESC, page_no ASC)` 读出，记住最后一次的位置。
  final (int, int)? materialPage;

  /// 消息与题目按主键倒序读出。
  final int? messageId;
  final int? questionId;

  /// 已提交作答按 `(submitted_at DESC, id DESC)` 读出。
  final String? answerSubmittedAt;
  final int? answerId;
}

/// 一批用户查找候选；[cursor] 为空表示四类来源都已经读完。
class EvidenceSearchPage {
  const EvidenceSearchPage({required this.hits, this.cursor});

  final List<EvidenceHit> hits;
  final SearchCursor? cursor;

  bool get hasMore => cursor != null;
}

/// 原文查找与候选读取：字面命中用带绑定参数的 `instr`，关键词检索用转义后的
/// `LIKE`，两类查询都把范围条件放进 SQL，不由界面事后过滤。
///
/// 字面查找覆盖材料页、讨论消息、题目与已提交作答；`instr` 不对通配符做特殊
/// 处理，因此 `a_b`、`f(x)` 只会命中同样的字符序列。读取命中之后还可以按记录
/// 标识重新读一次当前记录，核对范围、版本与删除状态，供语义索引的迟到结果
/// 使用。
class EvidenceRepository {
  EvidenceRepository(this._db);

  final RawDatabase _db;

  /// 按原样查找字面文本；`limitPerKind` 限制每类来源的条数，结果合并后再排序。
  Future<List<EvidenceHit>> literal(
    String query, {
    required EvidenceScope scope,
    int limitPerKind = 20,
    int? excludeConversationId,
    (int, int)? excludePage,
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final shape = QueryShape(text: text, literal: true);
    return _search(
      shape,
      scope: scope,
      limitPerKind: limitPerKind,
      excludeConversationId: excludeConversationId,
      excludePage: excludePage,
      literal: true,
    );
  }

  /// 按关键词查找；关键词先切分，再用转义后的 `LIKE` 匹配。
  Future<List<EvidenceHit>> keyword(
    String query, {
    required EvidenceScope scope,
    int limitPerKind = 20,
    int? excludeConversationId,
    (int, int)? excludePage,
  }) async {
    final shape = shapeQuery(query);
    if (shape.terms.isEmpty) return const [];
    return _search(
      QueryShape(text: shape.text, literal: false),
      scope: scope,
      limitPerKind: limitPerKind,
      excludeConversationId: excludeConversationId,
      excludePage: excludePage,
      literal: false,
    );
  }

  Future<List<EvidenceHit>> _search(
    QueryShape shape, {
    required EvidenceScope scope,
    required int limitPerKind,
    required bool literal,
    int? excludeConversationId,
    (int, int)? excludePage,
  }) async {
    final hits = <EvidenceHit>[
      ...await _pages(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        excludePage: excludePage,
      ),
      ...await _messages(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        excludeConversationId: excludeConversationId,
      ),
      ...await _questions(shape, scope, limit: limitPerKind, literal: literal),
      ...await _answers(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        excludeConversationId: excludeConversationId,
      ),
    ];
    return hits;
  }

  /// 分批读取用户查找的候选：每类来源最多读 [batchSize] 条，从 [after] 之后
  /// 继续，返回这一批命中和下一次继续的位置。
  ///
  /// 四类来源共用同一个游标对象，但各自按自己的主键或提交时间向后读；某一类
  /// 先读完时，游标仍指向它最后一条，下一次查询因此不会再读到重复记录。只有
  /// 至少一类还有更多候选时才返回游标，四类都读完时游标为空。
  Future<EvidenceSearchPage> searchBatch(
    String query, {
    required EvidenceScope scope,
    required bool literal,
    int batchSize = 100,
    SearchCursor? after,
    int? excludeConversationId,
    (int, int)? excludePage,
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const EvidenceSearchPage(hits: []);
    final shape = literal
        ? QueryShape(text: text, literal: true)
        : shapeQuery(text);
    if (!literal && shape.terms.isEmpty) {
      return const EvidenceSearchPage(hits: []);
    }
    final pages = await _pages(
      shape,
      scope,
      limit: batchSize + 1,
      literal: literal,
      excludePage: excludePage,
      after: after,
    );
    final messages = await _messages(
      shape,
      scope,
      limit: batchSize + 1,
      literal: literal,
      excludeConversationId: excludeConversationId,
      after: after,
    );
    final questions = await _questions(
      shape,
      scope,
      limit: batchSize + 1,
      literal: literal,
      after: after,
    );
    final answers = await _answers(
      shape,
      scope,
      limit: batchSize + 1,
      literal: literal,
      excludeConversationId: excludeConversationId,
      after: after,
    );

    var more = false;
    List<EvidenceHit> take(List<EvidenceHit> rows) {
      if (rows.length <= batchSize) return rows;
      more = true;
      return rows.sublist(0, batchSize);
    }

    final pagedPages = take(pages);
    final pagedMessages = take(messages);
    final pagedQuestions = take(questions);
    final pagedAnswers = take(answers);
    final hits = <EvidenceHit>[
      ...pagedPages,
      ...pagedMessages,
      ...pagedQuestions,
      ...pagedAnswers,
    ];
    if (!more) return EvidenceSearchPage(hits: hits);
    return EvidenceSearchPage(
      hits: hits,
      cursor: SearchCursor(
        materialPage: pagedPages.isEmpty
            ? const (0, 0)
            : (
                pagedPages.last.location.materialId!,
                pagedPages.last.location.pageNo!,
              ),
        messageId: pagedMessages.isEmpty
            ? 0
            : pagedMessages.last.location.messageId,
        questionId: pagedQuestions.isEmpty
            ? 0
            : pagedQuestions.last.location.conversationId,
        answerSubmittedAt: pagedAnswers.isEmpty
            ? '0000'
            : formatDateTime(pagedAnswers.last.createdAt!),
        answerId: pagedAnswers.isEmpty
            ? 0
            : pagedAnswers.last.location.attemptId,
      ),
    );
  }

  /// 按原样读出全部命中：按主键或提交时间分批继续读，不预先按类别截断。
  ///
  /// 用户查找要看到全部命中并把排序交给完整候选，因此这里一直读到游标为空；
  /// 每批的条数有限，不会一次把所有记录读进内存。
  Future<List<EvidenceHit>> allLiteral(
    String query, {
    required EvidenceScope scope,
    int? excludeConversationId,
    (int, int)? excludePage,
    int batchSize = 200,
  }) {
    return _loadAll(
      query,
      scope: scope,
      literal: true,
      excludeConversationId: excludeConversationId,
      excludePage: excludePage,
      batchSize: batchSize,
    );
  }

  /// 按关键词读出全部命中，分批方式与 [allLiteral] 相同。
  Future<List<EvidenceHit>> allKeyword(
    String query, {
    required EvidenceScope scope,
    int? excludeConversationId,
    (int, int)? excludePage,
    int batchSize = 200,
  }) {
    return _loadAll(
      query,
      scope: scope,
      literal: false,
      excludeConversationId: excludeConversationId,
      excludePage: excludePage,
      batchSize: batchSize,
    );
  }

  Future<List<EvidenceHit>> _loadAll(
    String query, {
    required EvidenceScope scope,
    required bool literal,
    int? excludeConversationId,
    (int, int)? excludePage,
    required int batchSize,
  }) async {
    final hits = <EvidenceHit>[];
    SearchCursor? cursor;
    // 游标只会在至少一类来源还没读完时返回，因此循环次数受命中总数限制。
    do {
      final page = await searchBatch(
        query,
        scope: scope,
        literal: literal,
        batchSize: batchSize,
        after: cursor,
        excludeConversationId: excludeConversationId,
        excludePage: excludePage,
      );
      hits.addAll(page.hits);
      cursor = page.hasMore ? page.cursor : null;
    } while (cursor != null);
    return hits;
  }

  /// 重新读取这条命中对应的当前记录；记录已删除或换了版本时返回空。
  ///
  /// 语义索引会落后于业务库，因此使用索引结果之前必须先过这一关：内容或
  /// 更新时间与命中时的版本不一致、记录已被删除、归属已超出本次范围，都
  /// 不再使用。
  Future<EvidenceHit?> current(EvidenceHit hit) async {
    final scope = hit.location;
    switch (hit.kind) {
      case EvidenceKind.materialPage:
        final materialId = scope.materialId;
        final pageNo = scope.pageNo;
        if (materialId == null || pageNo == null) return null;
        final rows = await _db.rawQuery(
          'SELECT mp.content, mp.label, mp.updated_at, m.title, m.source_file_name '
          'FROM material_page mp JOIN material m ON m.id = mp.material_id '
          'WHERE mp.material_id = ? AND mp.page_no = ? LIMIT 1',
          [materialId, pageNo],
        );
        if (rows.isEmpty) return null;
        final row = rows.first;
        final content = row['content']! as String;
        return EvidenceHit(
          kind: EvidenceKind.materialPage,
          identity: hit.identity,
          title:
              '《${row['title']}》${materialPosition(pageNo, isDocx: isDocxFile(row['source_file_name'] as String?))}',
          snippet: hit.snippet,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            materialId: materialId,
            pageNo: pageNo,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(content, row['updated_at']),
          createdAt: hit.createdAt,
          text: content,
        );
      case EvidenceKind.message:
        final messageId = scope.messageId;
        if (messageId == null) return null;
        final rows = await _db.rawQuery(
          'SELECT m.content, m.created_at, c.id AS conversation_id, '
          'c.title, c.goal_id, c.material_id '
          'FROM message m JOIN conversation c ON c.id = m.conversation_id '
          'WHERE m.id = ? LIMIT 1',
          [messageId],
        );
        if (rows.isEmpty) return null;
        final row = rows.first;
        final content = row['content']! as String;
        return EvidenceHit(
          kind: EvidenceKind.message,
          identity: hit.identity,
          title: (row['title'] as String?) ?? '一次讨论',
          snippet: hit.snippet,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: row['conversation_id']! as int,
            messageId: messageId,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(content, row['created_at']),
          createdAt: DateTime.tryParse(row['created_at']! as String),
          text: content,
        );
      case EvidenceKind.question:
        final conversationId = scope.conversationId;
        if (conversationId == null) return null;
        final row = await _questionRow(conversationId);
        if (row == null) return null;
        final content = (row['stem'] as String?) ?? '';
        return EvidenceHit(
          kind: EvidenceKind.question,
          identity: hit.identity,
          title: _conversationTitle(row),
          snippet: hit.snippet,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: conversationId,
            messageId: row['question_message_id'] as int?,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(
            '$content\n${row['source_ref'] ?? ''}\n${row['context_text'] ?? ''}',
            row['updated_at'],
          ),
          createdAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
          sourceRef: row['source_ref'] as String?,
          text: content,
        );
      case EvidenceKind.answer:
        final attemptId = scope.attemptId;
        if (attemptId == null) return null;
        final rows = await _db.rawQuery(
          'SELECT a.id, a.conversation_id, a.user_answer, a.solution, '
          'a.feedback, a.submitted_at, c.title, c.source_ref '
          'FROM attempt a JOIN conversation c ON c.id = a.conversation_id '
          'WHERE a.id = ? AND a.submitted_at IS NOT NULL LIMIT 1',
          [attemptId],
        );
        if (rows.isEmpty) return null;
        final row = rows.first;
        final answer = (row['user_answer'] as String?) ?? '';
        return EvidenceHit(
          kind: EvidenceKind.answer,
          identity: hit.identity,
          title: _answerTitle(attemptId),
          snippet: hit.snippet,
          text: '$answer\n${row['solution'] ?? ''}\n${row['feedback'] ?? ''}',
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: row['conversation_id']! as int,
            attemptId: attemptId,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(
            '$answer\n${row['solution'] ?? ''}\n${row['feedback'] ?? ''}',
            row['submitted_at'],
          ),
          createdAt: DateTime.tryParse('${row['submitted_at'] ?? ''}'),
          sourceRef: row['source_ref'] as String?,
        );
    }
  }

  /// 沿同一道题、同一份材料页或用户选定的目标找齐作答。
  ///
  /// [conversationId] 限定当前讨论，[stem] 匹配跨记录的同题首条消息，[goalId]
  /// 取用户明确选择的目标；[from] 与 [to] 是显式时间条件。先按提交时间倒序取
  /// 最近的 [limit] 次，再反转成时间正序，回答据此区分当时用了什么帮助、后来
  /// 是否独立完成；同一道题超过 [limit] 次作答时，“上次”因此是本次之前最近
  /// 的一次，不会退回到最早几次。只读已提交的作答。
  Future<List<ThreadAttempt>> threadAttempts({
    int? conversationId,
    String? stem,
    int? goalId,
    bool includeUnassigned = false,
    int? materialId,
    int? pageNo,
    DateTime? from,
    DateTime? to,
    int limit = 8,
  }) async {
    final where = <String>['a.submitted_at IS NOT NULL'];
    final args = <Object?>[];
    final thread = <String>[];
    final threadArgs = <Object?>[];
    if (conversationId != null) {
      thread.add('c.id = ?');
      threadArgs.add(conversationId);
    }
    final trimmed = stem?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      thread.add('$_firstUserContent = ?');
      threadArgs.add(trimmed);
    }
    if (materialId != null) {
      thread.add('c.material_id = ?');
      threadArgs.add(materialId);
      if (pageNo != null) {
        thread.add('c.page_no = ?');
        threadArgs.add(pageNo);
      }
    }
    if (goalId != null) {
      thread.add(
        includeUnassigned
            ? '(c.goal_id = ? OR c.goal_id IS NULL)'
            : 'c.goal_id = ?',
      );
      threadArgs.add(goalId);
    }
    if (thread.isNotEmpty) {
      // 调用方每次只传一条线索，线索内部的条件是“且”关系：材料与页码同时
      // 成立才算同一条线索，不同线索由跨次服务分层查询。
      where.add('(${thread.join(' AND ')})');
      args.addAll(threadArgs);
    }
    if (from != null) {
      where.add('a.submitted_at >= ?');
      args.add(formatDateTime(from));
    }
    if (to != null) {
      where.add('a.submitted_at < ?');
      args.add(formatDateTime(to));
    }
    // 先取最近若干次再反转：外层只做排序，截断发生在外层之前，因此时间倒序
    // 读到的就是本次之前最近的几次作答。
    final rows = await _db.rawQuery(
      'SELECT * FROM ('
      'SELECT a.*, c.source_ref AS thread_source_ref, '
      'c.material_id AS thread_material_id, c.page_no AS thread_page_no, '
      'c.goal_id AS thread_goal_id, '
      "COALESCE($_firstUserContent, '') AS thread_stem "
      'FROM attempt a JOIN conversation c ON c.id = a.conversation_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY a.submitted_at DESC, a.id DESC LIMIT ?'
      ') ORDER BY submitted_at ASC, id ASC',
      [...args, limit],
    );
    return rows
        .map(
          (row) => ThreadAttempt(
            attempt: Attempt.fromRow(row),
            conversationId: row['conversation_id']! as int,
            stem: (row['thread_stem'] as String?) ?? '',
            sourceRef: row['thread_source_ref'] as String?,
            materialId: row['thread_material_id'] as int?,
            pageNo: row['thread_page_no'] as int?,
            goalId: row['thread_goal_id'] as int?,
          ),
        )
        .toList(growable: false);
  }

  /// 语义索引可用的全部来源：材料页、讨论消息与已提交作答。
  ///
  /// 读取顺序按最近更新倒序，后台可以分批处理；索引只保存可重建的数据，
  /// 范围与有效性在查询时再按业务记录核对。
  Future<List<SemanticSource>> semanticSources({int? limit}) async {
    final result = <SemanticSource>[];
    final pages = await _db.rawQuery(
      'SELECT mp.material_id, mp.page_no, mp.content, mp.updated_at '
      'FROM material_page mp ORDER BY mp.updated_at DESC, mp.material_id, '
      'mp.page_no',
    );
    for (final row in pages) {
      final content = row['content']! as String;
      final materialId = row['material_id']! as int;
      final pageNo = row['page_no']! as int;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.materialPage.value,
            sourceKey: 'material_page:$materialId:$pageNo',
            materialId: materialId,
            pageNo: pageNo,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row['updated_at']),
          updatedAt: DateTime.tryParse('${row['updated_at'] ?? ''}'),
        ),
      );
    }
    final messages = await _db.rawQuery(
      'SELECT m.id, m.conversation_id, m.content, m.created_at, '
      'c.material_id FROM message m '
      'JOIN conversation c ON c.id = m.conversation_id '
      "WHERE m.role IN ('user', 'assistant') AND m.content != '' "
      'ORDER BY m.id DESC',
    );
    for (final row in messages) {
      final content = row['content']! as String;
      final id = row['id']! as int;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.message.value,
            sourceKey: 'message:$id',
            conversationId: row['conversation_id']! as int,
            materialId: row['material_id'] as int?,
            messageId: id,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row['created_at']),
          updatedAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
        ),
      );
    }
    final answers = await _db.rawQuery(
      'SELECT a.id, a.conversation_id, a.user_answer, a.solution, '
      'a.feedback, a.submitted_at, c.material_id FROM attempt a '
      'JOIN conversation c ON c.id = a.conversation_id '
      'WHERE a.submitted_at IS NOT NULL ORDER BY a.submitted_at DESC, a.id DESC',
    );
    for (final row in answers) {
      final parts = [
        row['user_answer'] as String?,
        row['solution'] as String?,
        row['feedback'] as String?,
      ].whereType<String>().where((part) => part.trim().isNotEmpty);
      final content = parts.join('\n');
      if (content.trim().isEmpty) continue;
      final id = row['id']! as int;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.answer.value,
            sourceKey: 'attempt:$id',
            conversationId: row['conversation_id']! as int,
            materialId: row['material_id'] as int?,
            attemptId: id,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row['submitted_at']),
          updatedAt: DateTime.tryParse('${row['submitted_at'] ?? ''}'),
        ),
      );
    }
    if (limit != null && result.length > limit) {
      return result.take(limit).toList(growable: false);
    }
    return result;
  }

  /// 重新读取一条来源的当前版本；来源已删除时返回空。
  ///
  /// 嵌入请求可能很慢，写回之前必须重新读一次，避免把等待模型期间被更正、
  /// 删除或撤销的内容写进索引。
  Future<SemanticSource?> semanticSource(SemanticLocator locator) async {
    switch (locator.kind) {
      case 'material_page':
        final materialId = locator.materialId;
        final pageNo = locator.pageNo;
        if (materialId == null || pageNo == null) return null;
        final rows = await _db.rawQuery(
          'SELECT content, updated_at FROM material_page '
          'WHERE material_id = ? AND page_no = ? LIMIT 1',
          [materialId, pageNo],
        );
        if (rows.isEmpty) return null;
        final content = rows.first['content']! as String;
        return SemanticSource(
          locator: locator,
          content: content,
          sourceVersion: evidenceSourceVersion(
            content,
            rows.first['updated_at'],
          ),
          updatedAt: DateTime.tryParse('${rows.first['updated_at'] ?? ''}'),
        );
      case 'message':
        final messageId = locator.messageId;
        if (messageId == null) return null;
        final rows = await _db.rawQuery(
          'SELECT content, created_at FROM message WHERE id = ? LIMIT 1',
          [messageId],
        );
        if (rows.isEmpty) return null;
        final content = rows.first['content']! as String;
        return SemanticSource(
          locator: locator,
          content: content,
          sourceVersion: evidenceSourceVersion(
            content,
            rows.first['created_at'],
          ),
          updatedAt: DateTime.tryParse('${rows.first['created_at'] ?? ''}'),
        );
      case 'answer':
        final attemptId = locator.attemptId;
        if (attemptId == null) return null;
        final rows = await _db.rawQuery(
          'SELECT user_answer, solution, feedback, submitted_at FROM attempt '
          'WHERE id = ? AND submitted_at IS NOT NULL LIMIT 1',
          [attemptId],
        );
        if (rows.isEmpty) return null;
        final parts = [
          rows.first['user_answer'] as String?,
          rows.first['solution'] as String?,
          rows.first['feedback'] as String?,
        ].whereType<String>().where((part) => part.trim().isNotEmpty);
        final content = parts.join('\n');
        return SemanticSource(
          locator: locator,
          content: content,
          sourceVersion: evidenceSourceVersion(
            content,
            rows.first['submitted_at'],
          ),
          updatedAt: DateTime.tryParse('${rows.first['submitted_at'] ?? ''}'),
        );
      default:
        return null;
    }
  }

  /// 这条命中是否仍在给定范围内；范围变化（改归属、换材料）之后不再使用。
  Future<bool> inScope(EvidenceHit hit, EvidenceScope scope) async {
    final conversationId = hit.location.conversationId;
    if (conversationId != null) {
      final rows = await _db.query(
        'conversation',
        columns: ['goal_id', 'material_id'],
        where: 'id = ?',
        whereArgs: [conversationId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      return _conversationInScope(
        conversationId,
        rows.first['goal_id'] as int?,
        rows.first['material_id'] as int?,
        scope,
        identity: hit.identity,
      );
    }
    final materialId = hit.location.materialId;
    if (materialId != null) {
      final rows = await _db.query(
        'material',
        columns: ['goal_id'],
        where: 'id = ?',
        whereArgs: [materialId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      return _materialInScope(
        materialId,
        rows.first['goal_id'] as int?,
        scope,
        identity: hit.identity,
      );
    }
    return false;
  }

  Future<Map<String, Object?>?> _questionRow(int conversationId) async {
    final rows = await _db.rawQuery(
      'SELECT $_questionMessageId AS question_message_id, '
      'COALESCE(c.source_ref, '
      "(CASE WHEN (SELECT title FROM material WHERE id = c.material_id) "
      "IS NOT NULL AND c.page_no IS NOT NULL THEN '《' || "
      "(SELECT title FROM material WHERE id = c.material_id) || '》第 ' || "
      "c.page_no || ' 页' END)) AS source_ref, "
      "c.title, c.context_text, c.page_no, c.created_at, c.updated_at, "
      '$_firstUserContent AS stem '
      'FROM conversation c WHERE c.id = ? LIMIT 1',
      [conversationId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  static const String _questionMessageId =
      'COALESCE(c.question_message_id, (SELECT m.id FROM message m '
      "WHERE m.conversation_id = c.id AND m.role = 'user' "
      'ORDER BY m.id LIMIT 1))';

  static const String _firstUserContent =
      '(SELECT m.content FROM message m WHERE m.conversation_id = c.id '
      "AND m.role = 'user' AND m.id = $_questionMessageId LIMIT 1)";

  Future<List<EvidenceHit>> _pages(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    (int, int)? excludePage,
    SearchCursor? after,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    final scopeClause = _materialScope(scope);
    if (scopeClause.where.isNotEmpty) {
      where.add(scopeClause.where);
      args.addAll(scopeClause.args);
    }
    if (excludePage != null) {
      where.add('NOT (mp.material_id = ? AND mp.page_no = ?)');
      args.addAll([excludePage.$1, excludePage.$2]);
    }
    final pageAfter = after?.materialPage;
    if (pageAfter != null) {
      where.add(
        '(mp.material_id < ? OR (mp.material_id = ? AND mp.page_no > ?))',
      );
      args.addAll([pageAfter.$1, pageAfter.$1, pageAfter.$2]);
    }
    final (match, matchArgs) = _pageMatch(shape, literal);
    where.add(match);
    args.addAll(matchArgs);
    final rows = await _db.rawQuery(
      'SELECT mp.material_id, mp.page_no, mp.label, mp.content, '
      'mp.updated_at, m.title AS material_title, m.source_file_name '
      'FROM material_page mp JOIN material m ON m.id = mp.material_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY mp.material_id DESC, mp.page_no '
      'LIMIT ?',
      [...args, limit],
    );
    return rows
        .map((row) {
          final content = row['content']! as String;
          final label = row['label'] as String?;
          final pageNo = row['page_no']! as int;
          final offset = literal
              ? _literalOffset(content, label, shape.text)
              : _termOffset(content, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.materialPage,
            identity: 'material_page:${row['material_id']}:$pageNo',
            title:
                '《${row['material_title']}》${materialPosition(pageNo, isDocx: isDocxFile(row['source_file_name'] as String?))}',
            snippet: searchSnippet(content, _termsFor(shape, literal)),
            text: content,
            matchedText: _matchedText(content, shape, literal, offset),
            literal: literal,
            score: _score(shape, literal, offset, content),
            location: EvidenceLocation(
              materialId: row['material_id']! as int,
              pageNo: pageNo,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(content, row['updated_at']),
            createdAt: DateTime.tryParse('${row['updated_at'] ?? ''}'),
          );
        })
        .toList(growable: false);
  }

  Future<List<EvidenceHit>> _messages(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    int? excludeConversationId,
    SearchCursor? after,
  }) async {
    final where = <String>[
      "m.role IN ('user', 'assistant')",
      "m.content != ''",
    ];
    final args = <Object?>[];
    if (excludeConversationId != null) {
      where.add('m.conversation_id != ?');
      args.add(excludeConversationId);
    }
    if (after != null) {
      where.add('m.id < ?');
      args.add(after.messageId ?? 0);
    }
    final scopeClause = _conversationScope(scope, kind: 'message');
    if (scopeClause.where.isNotEmpty) {
      where.add(scopeClause.where);
      args.addAll(scopeClause.args);
    }
    final (match, matchArgs) = literal
        ? _literalMatch(['m.content'], shape.text)
        : _likeMatch('m.content', shape.terms);
    where.add(match);
    args.addAll(matchArgs);
    final rows = await _db.rawQuery(
      'SELECT m.id, m.conversation_id, m.content, m.created_at, c.title '
      'FROM message m JOIN conversation c ON c.id = m.conversation_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY m.id DESC LIMIT ?',
      [...args, limit],
    );
    return rows
        .map((row) {
          final content = row['content']! as String;
          final offset = literal
              ? _literalOffset(content, null, shape.text)
              : _termOffset(content, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.message,
            identity: 'message:${row['id']}',
            title: (row['title'] as String?) ?? '一次讨论',
            snippet: searchSnippet(content, _termsFor(shape, literal)),
            text: content,
            matchedText: _matchedText(content, shape, literal, offset),
            literal: literal,
            score: _score(shape, literal, offset, content),
            location: EvidenceLocation(
              conversationId: row['conversation_id']! as int,
              messageId: row['id']! as int,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(content, row['created_at']),
            createdAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
          );
        })
        .toList(growable: false);
  }

  Future<List<EvidenceHit>> _questions(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    SearchCursor? after,
  }) async {
    final where = <String>[
      'EXISTS (SELECT 1 FROM attempt a WHERE a.conversation_id = c.id)',
    ];
    final args = <Object?>[];
    if (after != null) {
      where.add('c.id < ?');
      args.add(after.questionId ?? 0);
    }
    final scopeClause = _conversationScope(scope, kind: 'question');
    if (scopeClause.where.isNotEmpty) {
      where.add(scopeClause.where);
      args.addAll(scopeClause.args);
    }
    final (match, matchArgs) = literal
        ? _literalMatch([
            "COALESCE($_firstUserContent, '')",
            "COALESCE(c.source_ref, '')",
            "COALESCE(c.context_text, '')",
          ], shape.text)
        : _questionLikeMatch(shape.terms);
    where.add('($match)');
    args.addAll(matchArgs);
    final rows = await _db.rawQuery(
      'SELECT c.id AS conversation_id, '
      '$_questionMessageId AS question_message_id, '
      '$_firstUserContent AS stem, c.source_ref, c.context_text, c.title, '
      'c.page_no, c.created_at, c.updated_at '
      'FROM conversation c '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY c.id DESC LIMIT ?',
      [...args, limit],
    );
    return rows
        .map((row) {
          final sourceRef = row['source_ref'] as String?;
          final context = (row['context_text'] as String?) ?? '';
          final stem = (row['stem'] as String?) ?? '';
          final text = '$stem\n${sourceRef ?? ''}';
          final offset = literal
              ? _literalOffset(
                  '$stem\n${sourceRef ?? ''}\n$context',
                  null,
                  shape.text,
                )
              : _termOffset(text, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.question,
            identity: 'question:${row['conversation_id']}',
            title: _conversationTitle(row),
            snippet: searchSnippet(text, _termsFor(shape, literal)),
            text: text,
            matchedText: _matchedText(text, shape, literal, offset),
            literal: literal,
            score: _score(shape, literal, offset, text) + 2,
            location: EvidenceLocation(
              conversationId: row['conversation_id']! as int,
              messageId: row['question_message_id'] as int?,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(
              '$stem\n${sourceRef ?? ''}\n$context',
              row['updated_at'],
            ),
            createdAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
            sourceRef: sourceRef,
          );
        })
        .toList(growable: false);
  }

  Future<List<EvidenceHit>> _answers(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    int? excludeConversationId,
    SearchCursor? after,
  }) async {
    final where = <String>['a.submitted_at IS NOT NULL'];
    final args = <Object?>[];
    if (excludeConversationId != null) {
      where.add('a.conversation_id != ?');
      args.add(excludeConversationId);
    }
    final submittedAfter = after?.answerSubmittedAt;
    if (submittedAfter != null) {
      final answerId = after!.answerId ?? 0;
      where.add('(a.submitted_at < ? OR (a.submitted_at = ? AND a.id < ?))');
      args.addAll([submittedAfter, submittedAfter, answerId]);
    }
    final scopeClause = _conversationScope(scope, kind: 'answer');
    if (scopeClause.where.isNotEmpty) {
      where.add(scopeClause.where);
      args.addAll(scopeClause.args);
    }
    final (match, matchArgs) = literal
        ? _literalMatch([
            "COALESCE(a.user_answer, '')",
            "COALESCE(a.solution, '')",
            "COALESCE(a.feedback, '')",
          ], shape.text)
        : _answerLikeMatch(shape.terms);
    where.add('($match)');
    args.addAll(matchArgs);
    final rows = await _db.rawQuery(
      'SELECT a.id, a.conversation_id, a.user_answer, a.solution, '
      'a.feedback, a.submitted_at, c.title, c.source_ref '
      'FROM attempt a JOIN conversation c ON c.id = a.conversation_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY a.submitted_at DESC, a.id DESC LIMIT ?',
      [...args, limit],
    );
    return rows
        .map((row) {
          final answer = (row['user_answer'] as String?) ?? '';
          final text =
              '$answer\n${row['solution'] ?? ''}\n'
              '${row['feedback'] ?? ''}';
          final offset = literal
              ? _literalOffset(text, null, shape.text)
              : _termOffset(text, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.answer,
            identity: 'attempt:${row['id']}',
            title: _answerTitle(row['id']! as int),
            snippet: searchSnippet(text, _termsFor(shape, literal)),
            text: text,
            matchedText: _matchedText(text, shape, literal, offset),
            literal: literal,
            score: _score(shape, literal, offset, text) + 1,
            location: EvidenceLocation(
              conversationId: row['conversation_id']! as int,
              attemptId: row['id']! as int,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(text, row['submitted_at']),
            createdAt: DateTime.tryParse('${row['submitted_at'] ?? ''}'),
            sourceRef: row['source_ref'] as String?,
          );
        })
        .toList(growable: false);
  }

  static String _answerTitle(int attemptId) => '一次已提交作答 · 第 $attemptId 条';

  static String _conversationTitle(Map<String, Object?> row) {
    final sourceRef = row['source_ref'] as String?;
    if (sourceRef != null && sourceRef.trim().isNotEmpty) return sourceRef;
    return (row['title'] as String?) ?? '一次讨论';
  }

  static String _matchedText(
    String content,
    QueryShape shape,
    bool literal,
    int offset,
  ) {
    if (literal) {
      if (offset <= 0) return shape.text;
      final start = (offset - 1).clamp(0, content.length);
      final end = (start + 40).clamp(0, content.length);
      return content.substring(start, end);
    }
    for (final term in shape.terms) {
      if (content.toLowerCase().contains(term.toLowerCase())) return term;
    }
    return shape.text;
  }

  static double _score(
    QueryShape shape,
    bool literal,
    int offset,
    String text,
  ) {
    if (literal) {
      if (offset <= 0) return 0;
      final length = text.isEmpty ? 1 : text.length;
      return 100 + (1 - (offset - 1) / length) * 10;
    }
    final lower = text.toLowerCase();
    var hits = 0;
    for (final term in shape.terms) {
      if (lower.contains(term.toLowerCase())) hits++;
    }
    final denominator = shape.terms.isEmpty ? 1 : shape.terms.length;
    return 10 + hits / denominator;
  }

  static List<String> _termsFor(QueryShape shape, bool literal) =>
      literal ? [shape.text] : shape.terms;

  static int _literalOffset(String content, String? label, String text) {
    final lower = content.toLowerCase();
    final found = lower.indexOf(text.toLowerCase());
    if (found >= 0) return found + 1;
    final labelText = (label ?? '').toLowerCase();
    final labelFound = labelText.indexOf(text.toLowerCase());
    return labelFound >= 0 ? labelFound + 1 : 0;
  }

  static int _termOffset(String content, List<String> terms) {
    final lower = content.toLowerCase();
    for (final term in terms) {
      final found = lower.indexOf(term.toLowerCase());
      if (found >= 0) return found + 1;
    }
    return 0;
  }

  static (String, List<Object?>) _pageMatch(QueryShape shape, bool literal) {
    if (literal) {
      return _literalMatch([
        'mp.content',
        "COALESCE(mp.label, '')",
        'm.title',
      ], shape.text);
    }
    final match = <String>[];
    final args = <Object?>[];
    for (final term in shape.terms) {
      match.add(
        '(mp.content LIKE ? ESCAPE \'\\\' OR mp.label LIKE ? ESCAPE \'\\\' '
        'OR m.title LIKE ? ESCAPE \'\\\')',
      );
      final pattern = '%${_escapeLike(term)}%';
      args.addAll([pattern, pattern, pattern]);
    }
    return ('(${match.join(' OR ')})', args);
  }

  /// 字面匹配：命中之后不能紧接数字、字母或下划线，避免 `例 3-2` 命中
  /// `例 3-20`、`a_b` 命中 `a_bc` 这类近似写法；引号、括号等符号后面的
  /// 字符不受限制。
  static (String, List<Object?>) _literalMatch(
    List<String> columns,
    String text,
  ) {
    final parts = <String>[];
    final args = <Object?>[];
    for (final column in columns) {
      parts.add(
        'instr(lower($column), lower(?)) > 0 AND ('
        "substr($column, instr(lower($column), lower(?)) + length(?), 1) = '' "
        'OR substr($column, instr(lower($column), lower(?)) + length(?), 1) '
        "NOT GLOB '[0-9A-Za-z_]')",
      );
      args.addAll([text, text, text, text, text]);
    }
    return ('(${parts.join(' OR ')})', args);
  }

  static (String, List<Object?>) _likeMatch(String column, List<String> terms) {
    final match = terms.map((_) => '$column LIKE ? ESCAPE \'\\\'').join(' OR ');
    return ('($match)', [for (final term in terms) '%${_escapeLike(term)}%']);
  }

  static (String, List<Object?>) _questionLikeMatch(List<String> terms) {
    final match = <String>[];
    final args = <Object?>[];
    for (final term in terms) {
      match.add(
        '$_firstUserContent LIKE ? ESCAPE \'\\\' '
        'OR c.source_ref LIKE ? ESCAPE \'\\\' '
        'OR c.context_text LIKE ? ESCAPE \'\\\'',
      );
      final pattern = '%${_escapeLike(term)}%';
      args.addAll([pattern, pattern, pattern]);
    }
    return ('(${match.join(' OR ')})', args);
  }

  static (String, List<Object?>) _answerLikeMatch(List<String> terms) {
    final match = <String>[];
    final args = <Object?>[];
    for (final term in terms) {
      match.add(
        'a.user_answer LIKE ? ESCAPE \'\\\' '
        'OR a.solution LIKE ? ESCAPE \'\\\' '
        'OR a.feedback LIKE ? ESCAPE \'\\\'',
      );
      final pattern = '%${_escapeLike(term)}%';
      args.addAll([pattern, pattern, pattern]);
    }
    return ('(${match.join(' OR ')})', args);
  }

  static String _escapeLike(String term) => term
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  static ({String where, List<Object?> args}) _conversationScope(
    EvidenceScope scope, {
    required String kind,
  }) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => (where: '', args: const []),
          EvidenceScopeKind.goal => (
            where: 'c.goal_id = ?',
            args: [scope.goalId],
          ),
          EvidenceScopeKind.material => (
            where: 'c.material_id = ?',
            args: [scope.materialId],
          ),
        };
      case EvidenceOrigin.answer:
        final clauses = <String>[];
        final args = <Object?>[];
        if (scope.goalId == null) {
          // 没有目标归属时只读当前这条讨论；其他无归属讨论不进入候选。
          if (scope.conversationId != null) {
            clauses.add('c.id = ?');
            args.add(scope.conversationId);
          }
        } else {
          clauses.add('(c.goal_id = ? OR c.goal_id IS NULL)');
          args.add(scope.goalId);
        }
        final brought = _broughtClause(scope.broughtIdentities, kind);
        if (brought != null) {
          clauses.add(brought.where);
          args.addAll(brought.args);
        }
        return clauses.isEmpty
            ? (where: 'c.id = -1', args: const [])
            : (where: '(${clauses.join(' OR ')})', args: args);
    }
  }

  /// 本轮带入的来源只放行对应的那一条记录，不因此读取整条讨论。
  static ({String where, List<Object?> args})? _broughtClause(
    Set<String> identities,
    String kind,
  ) {
    final clauses = <String>[];
    final args = <Object?>[];
    for (final identity in identities) {
      final parts = identity.trim().split(':');
      if (parts.length < 2) continue;
      final id = int.tryParse(parts[1]);
      switch (parts.first) {
        case 'message':
          if (kind == 'message' && id != null) {
            clauses.add('m.id = ?');
            args.add(id);
          }
        case 'question':
          if (kind == 'question' && id != null) {
            clauses.add('c.id = ?');
            args.add(id);
          }
        case 'attempt':
          if (kind == 'answer' && id != null) {
            clauses.add('a.id = ?');
            args.add(id);
          }
      }
    }
    return clauses.isEmpty
        ? null
        : (where: '(${clauses.join(' OR ')})', args: args);
  }

  static ({String where, List<Object?> args}) _materialScope(
    EvidenceScope scope,
  ) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => (where: '', args: const []),
          EvidenceScopeKind.goal => (
            where: 'm.goal_id = ?',
            args: [scope.goalId],
          ),
          EvidenceScopeKind.material => (
            where: 'mp.material_id = ?',
            args: [scope.materialId],
          ),
        };
      case EvidenceOrigin.answer:
        if (scope.goalId == null) {
          // 没有目标归属时只放行本轮带入的材料页；当前页由回答直接给出。
          final pages = <String>[];
          final args = <Object?>[];
          for (final identity in scope.broughtIdentities) {
            final parts = identity.trim().split(':');
            if (parts.length < 3 || parts.first != 'material_page') continue;
            final materialId = int.tryParse(parts[1]);
            final pageNo = int.tryParse(parts[2]);
            if (materialId == null || pageNo == null) continue;
            pages.add('(mp.material_id = ? AND mp.page_no = ?)');
            args.addAll([materialId, pageNo]);
          }
          return pages.isEmpty
              ? (where: 'mp.material_id = -1', args: const [])
              : (where: '(${pages.join(' OR ')})', args: args);
        }
        final clauses = <String>['(m.goal_id = ? OR m.goal_id IS NULL)'];
        final args = <Object?>[scope.goalId];
        final pages = <String>[];
        for (final identity in scope.broughtIdentities) {
          final parts = identity.trim().split(':');
          if (parts.length < 3 || parts.first != 'material_page') continue;
          final materialId = int.tryParse(parts[1]);
          final pageNo = int.tryParse(parts[2]);
          if (materialId == null || pageNo == null) continue;
          pages.add('(mp.material_id = ? AND mp.page_no = ?)');
          args.addAll([materialId, pageNo]);
        }
        if (pages.isNotEmpty) clauses.add('(${pages.join(' OR ')})');
        return (where: '(${clauses.join(' OR ')})', args: args);
    }
  }

  static bool _conversationInScope(
    int? conversationId,
    int? goalId,
    int? materialId,
    EvidenceScope scope, {
    required String identity,
  }) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => true,
          EvidenceScopeKind.goal => goalId == scope.goalId,
          EvidenceScopeKind.material => materialId == scope.materialId,
        };
      case EvidenceOrigin.answer:
        if (scope.broughtIdentities.contains(identity)) return true;
        final wanted = scope.goalId;
        if (wanted == null) {
          return scope.conversationId != null &&
              conversationId == scope.conversationId;
        }
        return goalId == wanted || goalId == null;
    }
  }

  static bool _materialInScope(
    int materialId,
    int? goalId,
    EvidenceScope scope, {
    required String identity,
  }) {
    switch (scope.origin) {
      case EvidenceOrigin.user:
        return switch (scope.kind) {
          EvidenceScopeKind.all => true,
          EvidenceScopeKind.goal => goalId == scope.goalId,
          // 材料范围只放行这份材料的页；比较材料标识，不能按“材料范围一律
          // 放行”处理，否则语义候选会带出其他材料的页。
          EvidenceScopeKind.material => materialId == scope.materialId,
        };
      case EvidenceOrigin.answer:
        if (scope.broughtIdentities.contains(identity)) return true;
        final wanted = scope.goalId;
        if (wanted == null) return false;
        return goalId == wanted || goalId == null;
    }
  }
}
