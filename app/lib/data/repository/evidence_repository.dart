import 'package:drift/drift.dart' show Variable;

import '../db/fts.dart';
import '../db/raw_executor.dart';
import '../db/drift/queries/evidence_scope.dart';
import '../../domain/rules/search_terms.dart';

import '../../domain/models/evidence.dart';
import '../../domain/models/evidence_id.dart';
import '../../domain/models/material.dart';
import '../../domain/models/question.dart';
import '../../domain/rules/embedding.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/query_shape.dart';
import '../../domain/rules/score_weights.dart';

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
  final String conversationId;
  final String stem;
  final String? sourceRef;
  final String? materialId;
  final int? pageNo;
  final String? goalId;
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
  final (String, int)? materialPage;

  /// 消息与题目按主键倒序读出。
  final String? messageId;
  final String? questionId;

  /// 已提交作答按 `(submitted_at DESC, id DESC)` 读出。
  final String? answerSubmittedAt;
  final String? answerId;
}

/// 一批用户查找候选；[cursor] 为空表示四类来源都已经读完。
class EvidenceSearchPage {
  const EvidenceSearchPage({required this.hits, this.cursor});

  final List<EvidenceHit> hits;
  final SearchCursor? cursor;

  bool get hasMore => cursor != null;
}

/// 字面查找用带绑定参数的 `instr`，关键词检索用 FTS5，范围条件在 SQL 中执行。
///
/// 字面查找覆盖材料页、讨论消息、题目与已提交作答；`instr` 不对通配符做特殊
/// 处理，因此 `a_b`、`f(x)` 只会命中同样的字符序列。读取命中之后还可以按记录
/// 标识重新读一次当前记录，核对范围、版本与删除状态，供语义索引的迟到结果
/// 使用。
///
/// 按记录编号读回的查询与语义索引的候选读取走 `queries/` 下的生成查询；四类
/// 命中查询还要写 FTS5 的 `MATCH`、`bm25()` 与关键字排名，生成查询表达不了，
/// 保留手写 SQL，但范围条件由 [EvidenceScopeRule] 这一份规则渲染进来。
class EvidenceRepository {
  EvidenceRepository(this._db);

  final RawDatabase _db;

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  ///
  /// 按原样查找字面文本；`limitPerKind` 限制每类来源的条数，结果合并后再排序。
  Future<List<EvidenceHit>> literal(
    String query, {
    required EvidenceScope scope,
    int limitPerKind = 20,
    String? excludeConversationId,
    (String, int)? excludePage,
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

  /// 按关键词查找，各类候选由 FTS5 按相关性选出。
  Future<List<EvidenceHit>> keyword(
    String query, {
    required EvidenceScope scope,
    int limitPerKind = 20,
    String? excludeConversationId,
    (String, int)? excludePage,
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
    String? excludeConversationId,
    (String, int)? excludePage,
  }) async {
    final hits = <EvidenceHit>[
      ...await _pages(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        rankBeforeLimit: !literal,
        excludePage: excludePage,
      ),
      ...await _messages(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        rankBeforeLimit: !literal,
        excludeConversationId: excludeConversationId,
      ),
      ...await _questions(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        rankBeforeLimit: !literal,
      ),
      ...await _answers(
        shape,
        scope,
        limit: limitPerKind,
        literal: literal,
        rankBeforeLimit: !literal,
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
    String? excludeConversationId,
    (String, int)? excludePage,
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
            ? const ('', 0)
            : (
                pagedPages.last.location.materialId!,
                pagedPages.last.location.pageNo!,
              ),
        messageId: pagedMessages.isEmpty
            ? ''
            : pagedMessages.last.location.messageId,
        questionId: pagedQuestions.isEmpty
            ? ''
            : pagedQuestions.last.location.conversationId,
        answerSubmittedAt: pagedAnswers.isEmpty
            ? '0000'
            : formatDateTime(pagedAnswers.last.createdAt!),
        answerId: pagedAnswers.isEmpty
            ? ''
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
    String? excludeConversationId,
    (String, int)? excludePage,
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
    String? excludeConversationId,
    (String, int)? excludePage,
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
    String? excludeConversationId,
    (String, int)? excludePage,
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
        final row = await _db.selectGenerated(
          (db) => db
              .evidenceMaterialPageCurrent(materialId, pageNo)
              .getSingleOrNull(),
        );
        if (row == null) return null;
        final content = row.content;
        return EvidenceHit(
          kind: EvidenceKind.materialPage,
          identity: hit.identity,
          title:
              '《${row.title}》${materialPosition(pageNo, isDocx: isDocxFile(row.sourceFileName))}',
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
          sourceVersion: evidenceSourceVersion(content, row.updatedAt),
          createdAt: hit.createdAt,
          text: content,
        );
      case EvidenceKind.message:
        final messageId = scope.messageId;
        if (messageId == null) return null;
        final row = await _db.selectGenerated(
          (db) => db.evidenceMessageCurrent(messageId).getSingleOrNull(),
        );
        if (row == null) return null;
        final content = row.content;
        return EvidenceHit(
          kind: EvidenceKind.message,
          identity: hit.identity,
          title: row.title ?? '一次讨论',
          snippet: hit.snippet,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: row.conversationId,
            messageId: messageId,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(content, row.createdAt),
          createdAt: requiredDateTime(row.createdAt),
          text: content,
        );
      case EvidenceKind.question:
        final conversationId = scope.conversationId;
        if (conversationId == null) return null;
        final row = await _db.selectGenerated(
          (db) => db.evidenceQuestionCurrent(conversationId).getSingleOrNull(),
        );
        if (row == null) return null;
        final content = row.stem ?? '';
        return EvidenceHit(
          kind: EvidenceKind.question,
          identity: hit.identity,
          title: _conversationTitle(row.sourceRef, row.title),
          snippet: hit.snippet,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: conversationId,
            messageId: row.questionMessageId,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(
            '$content\n${row.sourceRef ?? ''}\n${row.contextText ?? ''}',
            row.updatedAt,
          ),
          createdAt: optionalDateTime(row.createdAt),
          sourceRef: row.sourceRef,
          text: content,
        );
      case EvidenceKind.answer:
        final attemptId = scope.attemptId;
        if (attemptId == null) return null;
        final row = await _db.selectGenerated(
          (db) => db.evidenceAnswerCurrent(attemptId).getSingleOrNull(),
        );
        if (row == null) return null;
        final answer = row.userAnswer ?? '';
        final text = '$answer\n${row.solution ?? ''}\n${row.feedback ?? ''}';
        return EvidenceHit(
          kind: EvidenceKind.answer,
          identity: hit.identity,
          title: _answerTitle(attemptId),
          snippet: hit.snippet,
          text: text,
          matchedText: hit.matchedText,
          literal: hit.literal,
          semantic: hit.semantic,
          score: hit.score,
          location: EvidenceLocation(
            conversationId: row.conversationId,
            attemptId: attemptId,
            offset: hit.location.offset,
          ),
          sourceVersion: evidenceSourceVersion(text, row.submittedAt),
          createdAt: optionalDateTime(row.submittedAt),
          sourceRef: row.sourceRef,
        );
      case EvidenceKind.unknown:
        return null;
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
    String? conversationId,
    String? stem,
    String? goalId,
    bool includeUnassigned = false,
    String? materialId,
    int? pageNo,
    DateTime? from,
    DateTime? to,
    int limit = 8,
  }) async {
    final trimmed = stem?.trim();
    final rows = await _db.selectGenerated(
      (db) => db
          .evidenceThreadAttempts(
            conversationId,
            trimmed == null || trimmed.isEmpty ? null : trimmed,
            materialId,
            pageNo,
            goalId,
            includeUnassigned ? 1 : 0,
            from == null ? null : formatDateTime(from),
            to == null ? null : formatDateTime(to),
            limit,
          )
          .get(),
    );
    // 查询按提交时间倒序取最近的若干次，这里反转成时间正序；截断仍发生在
    // 时间正序之前，调用方拿到的“上次”是本次之前最近的一次。
    return rows.reversed
        .map(
          (row) => ThreadAttempt(
            attempt: Attempt(
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
            ),
            conversationId: row.conversationId,
            stem: row.threadStem,
            sourceRef: row.threadSourceRef,
            materialId: row.threadMaterialId,
            pageNo: row.threadPageNo,
            goalId: row.threadGoalId,
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
    final pages = await _db.selectGenerated(
      (db) => db.evidenceMaterialPageSources().get(),
    );
    for (final row in pages) {
      final content = row.content;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.materialPage.value,
            sourceKey: EvidenceId.materialPage(
              row.materialId,
              row.pageNo,
            ).value,
            materialId: row.materialId,
            pageNo: row.pageNo,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row.updatedAt),
          updatedAt: optionalDateTime(row.updatedAt),
        ),
      );
    }
    final messages = await _db.selectGenerated(
      (db) => db.evidenceMessageSources().get(),
    );
    for (final row in messages) {
      final content = row.content;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.message.value,
            sourceKey: EvidenceId.message(row.id).value,
            conversationId: row.conversationId,
            materialId: row.materialId,
            messageId: row.id,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row.createdAt),
          updatedAt: optionalDateTime(row.createdAt),
        ),
      );
    }
    final answers = await _db.selectGenerated(
      (db) => db.evidenceAnswerSources().get(),
    );
    for (final row in answers) {
      final parts = [
        row.userAnswer,
        row.solution,
        row.feedback,
      ].whereType<String>().where((part) => part.trim().isNotEmpty);
      final content = parts.join('\n');
      if (content.trim().isEmpty) continue;
      result.add(
        SemanticSource(
          locator: SemanticLocator(
            kind: EvidenceKind.answer.value,
            sourceKey: EvidenceId.attempt(row.id).value,
            conversationId: row.conversationId,
            materialId: row.materialId,
            attemptId: row.id,
          ),
          content: content,
          sourceVersion: evidenceSourceVersion(content, row.submittedAt),
          updatedAt: optionalDateTime(row.submittedAt),
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
        final row = await _db.selectGenerated(
          (db) => db
              .evidenceMaterialPageSource(materialId, pageNo)
              .getSingleOrNull(),
        );
        if (row == null) return null;
        return SemanticSource(
          locator: locator,
          content: row.content,
          sourceVersion: evidenceSourceVersion(row.content, row.updatedAt),
          updatedAt: optionalDateTime(row.updatedAt),
        );
      case 'message':
        final messageId = locator.messageId;
        if (messageId == null) return null;
        final row = await _db.selectGenerated(
          (db) => db.evidenceMessageSource(messageId).getSingleOrNull(),
        );
        if (row == null) return null;
        return SemanticSource(
          locator: locator,
          content: row.content,
          sourceVersion: evidenceSourceVersion(row.content, row.createdAt),
          updatedAt: optionalDateTime(row.createdAt),
        );
      case 'answer':
        final attemptId = locator.attemptId;
        if (attemptId == null) return null;
        final row = await _db.selectGenerated(
          (db) => db.evidenceAnswerSource(attemptId).getSingleOrNull(),
        );
        if (row == null) return null;
        final parts = [
          row.userAnswer,
          row.solution,
          row.feedback,
        ].whereType<String>().where((part) => part.trim().isNotEmpty);
        final content = parts.join('\n');
        return SemanticSource(
          locator: locator,
          content: content,
          sourceVersion: evidenceSourceVersion(content, row.submittedAt),
          updatedAt: optionalDateTime(row.submittedAt),
        );
      default:
        return null;
    }
  }

  /// 这条命中是否仍在给定范围内；范围变化（改归属、换材料）之后不再使用。
  ///
  /// 判断与命中查询共用 [EvidenceScopeRule] 这一份规则：这里把表达式放进生成
  /// 查询的 `where`，四类命中查询把同一个表达式渲染成 SQL 片段。
  Future<bool> inScope(EvidenceHit hit, EvidenceScope scope) =>
      _db.selectGenerated((db) => hitInScope(db, hit, scope));

  Future<List<EvidenceHit>> _pages(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    (String, int)? excludePage,
    SearchCursor? after,
    bool rankBeforeLimit = false,
  }) async {
    final before = <String>[];
    final beforeArgs = <Object>[];
    if (excludePage != null) {
      before.add('NOT (mp.material_id = ? AND mp.page_no = ?)');
      beforeArgs.addAll([excludePage.$1, excludePage.$2]);
    }
    final pageAfter = after?.materialPage;
    if (pageAfter != null) {
      before.add(
        '(mp.material_id < ? OR (mp.material_id = ? AND mp.page_no > ?))',
      );
      beforeArgs.addAll([pageAfter.$1, pageAfter.$1, pageAfter.$2]);
    }
    final fts = literal
        ? null
        : _ftsSearch('material_page_fts', shape.terms, 'mp.rowid');
    final (match, matchArgs) = fts == null
        ? _literalMatch([
            'mp.content',
            "COALESCE(mp.label, '')",
            'm.title',
          ], shape.text)
        : (fts.match, [fts.query]);
    final rows = await _db.selectGenerated((db) async {
      final materials = db.alias(db.materials, 'm');
      final pages = db.alias(db.materialPages, 'mp');
      final scopeSql = renderInSql(
        db,
        EvidenceScopeRule(scope).material(materials, pages),
      );
      final where = [
        ...before,
        if (scopeSql != null) '(${scopeSql.sql})',
        match,
      ];
      final args = [
        ...beforeArgs,
        if (scopeSql != null) ...scopeSql.values,
        ...matchArgs,
      ];
      return db
          .customSelect(
            'SELECT ${fts?.rank ?? 'NULL'} AS keyword_rank, mp.material_id, mp.page_no, mp.label, mp.content, '
            'mp.updated_at, m.title AS material_title, m.source_file_name '
            'FROM material_page mp JOIN material m ON m.id = mp.material_id '
            'WHERE ${where.join(' AND ')} '
            'ORDER BY ${rankBeforeLimit ? 'keyword_rank, ' : ''}mp.material_id DESC, mp.page_no '
            'LIMIT ?',
            variables: [
              if (fts != null) Variable<String>(fts.query),
              for (final value in args) Variable(value),
              Variable<int>(limit),
            ],
          )
          .get();
    });
    return rows
        .map((row) {
          final data = row.data;
          final content = data['content']! as String;
          final label = data['label'] as String?;
          final pageNo = data['page_no']! as int;
          final materialId = data['material_id']! as String;
          final offset = literal
              ? _literalOffset(content, label, shape.text)
              : _termOffset(content, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.materialPage,
            identity: EvidenceId.materialPage(materialId, pageNo).value,
            title:
                '《${data['material_title']}》${materialPosition(pageNo, isDocx: isDocxFile(data['source_file_name'] as String?))}',
            snippet: searchSnippet(content, _termsFor(shape, literal)),
            text: content,
            matchedText: _matchedText(content, shape, literal, offset),
            literal: literal,
            score: fts == null
                ? literalMatchScore(offset: offset, textLength: content.length)
                : keywordMatchScore(data['keyword_rank'] as num?),
            location: EvidenceLocation(
              materialId: materialId,
              pageNo: pageNo,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(content, data['updated_at']),
            createdAt: optionalDateTime('${data['updated_at'] ?? ''}'),
          );
        })
        .toList(growable: false);
  }

  Future<List<EvidenceHit>> _messages(
    QueryShape shape,
    EvidenceScope scope, {
    required int limit,
    required bool literal,
    String? excludeConversationId,
    SearchCursor? after,
    bool rankBeforeLimit = false,
  }) async {
    final before = <String>[
      "m.role IN ('user', 'assistant')",
      "m.content != ''",
    ];
    final beforeArgs = <Object>[];
    if (excludeConversationId != null) {
      before.add('m.conversation_id != ?');
      beforeArgs.add(excludeConversationId);
    }
    if (after != null) {
      before.add('m.id < ?');
      beforeArgs.add(after.messageId ?? '');
    }
    final fts = literal
        ? null
        : _ftsSearch('message_fts', shape.terms, 'm.rowid');
    final (match, matchArgs) = fts == null
        ? _literalMatch(['m.content'], shape.text)
        : (fts.match, [fts.query]);
    final rows = await _db.selectGenerated((db) async {
      final conversations = db.alias(db.conversations, 'c');
      final messages = db.alias(db.messages, 'm');
      final scopeSql = renderInSql(
        db,
        EvidenceScopeRule(scope)
            .conversation(conversations, kind: 'message', messages: messages),
      );
      final where = [
        ...before,
        if (scopeSql != null) '(${scopeSql.sql})',
        match,
      ];
      final args = [
        ...beforeArgs,
        if (scopeSql != null) ...scopeSql.values,
        ...matchArgs,
      ];
      return db
          .customSelect(
            'SELECT ${fts?.rank ?? 'NULL'} AS keyword_rank, m.id, m.conversation_id, m.content, m.created_at, c.title '
            'FROM message m JOIN conversation c ON c.id = m.conversation_id '
            'WHERE ${where.join(' AND ')} '
            'ORDER BY ${rankBeforeLimit ? 'keyword_rank, ' : ''}m.id DESC LIMIT ?',
            variables: [
              if (fts != null) Variable<String>(fts.query),
              for (final value in args) Variable(value),
              Variable<int>(limit),
            ],
          )
          .get();
    });
    return rows
        .map((row) {
          final data = row.data;
          final content = data['content']! as String;
          final messageId = data['id']! as String;
          final conversationId = data['conversation_id']! as String;
          final offset = literal
              ? _literalOffset(content, null, shape.text)
              : _termOffset(content, shape.terms);
          return EvidenceHit(
            kind: EvidenceKind.message,
            identity: EvidenceId.message(messageId).value,
            title: (data['title'] as String?) ?? '一次讨论',
            snippet: searchSnippet(content, _termsFor(shape, literal)),
            text: content,
            matchedText: _matchedText(content, shape, literal, offset),
            literal: literal,
            score: fts == null
                ? literalMatchScore(offset: offset, textLength: content.length)
                : keywordMatchScore(data['keyword_rank'] as num?),
            location: EvidenceLocation(
              conversationId: conversationId,
              messageId: messageId,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(content, data['created_at']),
            createdAt: optionalDateTime('${data['created_at'] ?? ''}'),
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
    bool rankBeforeLimit = false,
  }) async {
    final before = <String>[
      'EXISTS (SELECT 1 FROM attempt a WHERE a.conversation_id = c.id)',
    ];
    final beforeArgs = <Object>[];
    if (after != null) {
      before.add('c.id < ?');
      beforeArgs.add(after.questionId ?? '');
    }
    final fts = literal
        ? null
        : _ftsSearch('message_fts', shape.terms, _questionMessageRowId);
    final (match, matchArgs) = fts == null
        ? _literalMatch([
            "COALESCE($_firstUserContent, '')",
            "COALESCE(c.source_ref, '')",
            "COALESCE(c.context_text, '')",
          ], shape.text)
        : (fts.match, [fts.query]);
    final rows = await _db.selectGenerated((db) async {
      final conversations = db.alias(db.conversations, 'c');
      final scopeSql = renderInSql(
        db,
        EvidenceScopeRule(scope).conversation(conversations, kind: 'question'),
      );
      final where = [
        ...before,
        if (scopeSql != null) '(${scopeSql.sql})',
        '($match)',
      ];
      final args = [
        ...beforeArgs,
        if (scopeSql != null) ...scopeSql.values,
        ...matchArgs,
      ];
      return db
          .customSelect(
            'SELECT ${fts?.rank ?? 'NULL'} AS keyword_rank, c.id AS conversation_id, '
            '$_questionMessageId AS question_message_id, '
            '$_firstUserContent AS stem, c.source_ref, c.context_text, c.title, '
            'c.page_no, c.created_at, c.updated_at '
            'FROM conversation c '
            'WHERE ${where.join(' AND ')} '
            'ORDER BY ${rankBeforeLimit ? 'keyword_rank, ' : ''}c.id DESC LIMIT ?',
            variables: [
              if (fts != null) Variable<String>(fts.query),
              for (final value in args) Variable(value),
              Variable<int>(limit),
            ],
          )
          .get();
    });
    return rows
        .map((row) {
          final data = row.data;
          final sourceRef = data['source_ref'] as String?;
          final context = (data['context_text'] as String?) ?? '';
          final stem = (data['stem'] as String?) ?? '';
          final text = '$stem\n${sourceRef ?? ''}';
          final offset = literal
              ? _literalOffset(
                  '$stem\n${sourceRef ?? ''}\n$context',
                  null,
                  shape.text,
                )
              : _termOffset(text, shape.terms);
          final conversationId = data['conversation_id']! as String;
          return EvidenceHit(
            kind: EvidenceKind.question,
            identity: EvidenceId.question(conversationId).value,
            title: _conversationTitle(sourceRef, data['title'] as String?),
            snippet: searchSnippet(text, _termsFor(shape, literal)),
            text: text,
            matchedText: _matchedText(text, shape, literal, offset),
            literal: literal,
            score: fts == null
                ? literalMatchScore(
                    offset: offset,
                    textLength: text.length,
                    kindPriority: 2,
                  )
                : keywordMatchScore(data['keyword_rank'] as num?),
            location: EvidenceLocation(
              conversationId: conversationId,
              messageId: data['question_message_id'] as String?,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(
              '$stem\n${sourceRef ?? ''}\n$context',
              data['updated_at'],
            ),
            createdAt: optionalDateTime('${data['created_at'] ?? ''}'),
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
    String? excludeConversationId,
    SearchCursor? after,
    bool rankBeforeLimit = false,
  }) async {
    final before = <String>['a.submitted_at IS NOT NULL'];
    final beforeArgs = <Object>[];
    if (excludeConversationId != null) {
      before.add('a.conversation_id != ?');
      beforeArgs.add(excludeConversationId);
    }
    final submittedAfter = after?.answerSubmittedAt;
    if (submittedAfter != null) {
      final answerId = after!.answerId ?? '';
      before.add('(a.submitted_at < ? OR (a.submitted_at = ? AND a.id < ?))');
      beforeArgs.addAll([submittedAfter, submittedAfter, answerId]);
    }
    final fts = literal
        ? null
        : _ftsSearch('attempt_fts', shape.terms, 'a.rowid');
    final (match, matchArgs) = fts == null
        ? _literalMatch([
            "COALESCE(a.user_answer, '')",
            "COALESCE(a.solution, '')",
            "COALESCE(a.feedback, '')",
          ], shape.text)
        : (fts.match, [fts.query]);
    final rows = await _db.selectGenerated((db) async {
      final conversations = db.alias(db.conversations, 'c');
      final attempts = db.alias(db.attempts, 'a');
      final scopeSql = renderInSql(
        db,
        EvidenceScopeRule(scope)
            .conversation(conversations, kind: 'answer', attempts: attempts),
      );
      final where = [
        ...before,
        if (scopeSql != null) '(${scopeSql.sql})',
        '($match)',
      ];
      final args = [
        ...beforeArgs,
        if (scopeSql != null) ...scopeSql.values,
        ...matchArgs,
      ];
      return db
          .customSelect(
            'SELECT ${fts?.rank ?? 'NULL'} AS keyword_rank, a.id, a.conversation_id, a.user_answer, a.solution, '
            'a.feedback, a.submitted_at, c.title, c.source_ref '
            'FROM attempt a JOIN conversation c ON c.id = a.conversation_id '
            'WHERE ${where.join(' AND ')} '
            'ORDER BY ${rankBeforeLimit ? 'keyword_rank, ' : ''}a.submitted_at DESC, a.id DESC LIMIT ?',
            variables: [
              if (fts != null) Variable<String>(fts.query),
              for (final value in args) Variable(value),
              Variable<int>(limit),
            ],
          )
          .get();
    });
    return rows
        .map((row) {
          final data = row.data;
          final answer = (data['user_answer'] as String?) ?? '';
          final text =
              '$answer\n${data['solution'] ?? ''}\n'
              '${data['feedback'] ?? ''}';
          final offset = literal
              ? _literalOffset(text, null, shape.text)
              : _termOffset(text, shape.terms);
          final attemptId = data['id']! as String;
          return EvidenceHit(
            kind: EvidenceKind.answer,
            identity: EvidenceId.attempt(attemptId).value,
            title: _answerTitle(attemptId),
            snippet: searchSnippet(text, _termsFor(shape, literal)),
            text: text,
            matchedText: _matchedText(text, shape, literal, offset),
            literal: literal,
            score: fts == null
                ? literalMatchScore(
                    offset: offset,
                    textLength: text.length,
                    kindPriority: 1,
                  )
                : keywordMatchScore(data['keyword_rank'] as num?),
            location: EvidenceLocation(
              conversationId: data['conversation_id']! as String,
              attemptId: attemptId,
              offset: offset,
            ),
            sourceVersion: evidenceSourceVersion(text, data['submitted_at']),
            createdAt: optionalDateTime('${data['submitted_at'] ?? ''}'),
            sourceRef: data['source_ref'] as String?,
          );
        })
        .toList(growable: false);
  }

  static String _answerTitle(String attemptId) => '一次已提交作答 · 第 $attemptId 条';

  static String _conversationTitle(String? sourceRef, String? title) {
    if (sourceRef != null && sourceRef.trim().isNotEmpty) return sourceRef;
    return title ?? '一次讨论';
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

  /// 字面匹配：命中之后不能紧接数字、字母或下划线，避免 `例 3-2` 命中
  /// `例 3-20`、`a_b` 命中 `a_bc` 这类近似写法；引号、括号等符号后面的
  /// 字符不受限制。
  static (String, List<Object>) _literalMatch(
    List<String> columns,
    String text,
  ) {
    final parts = <String>[];
    final args = <Object>[];
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

  static ({String match, String rank, String query}) _ftsSearch(
    String table,
    List<String> terms,
    String keyColumn,
  ) {
    final query = ftsQuery({for (final term in terms) ...bigrams(term)});
    return (
      match:
          '$keyColumn IN (SELECT rowid FROM "$table" WHERE "$table" MATCH ?)',
      rank:
          '(SELECT bm25("$table") FROM "$table" '
          'WHERE "$table" MATCH ? AND rowid = $keyColumn)',
      query: query.isEmpty ? '""' : query,
    );
  }

  /// 题目视图的题目消息：优先取记录上记下的编号，没有时取第一条用户消息。
  static const String _questionMessageId =
      'COALESCE(c.question_message_id, (SELECT m.id FROM message m '
      "WHERE m.conversation_id = c.id AND m.role = 'user' "
      'ORDER BY m.id LIMIT 1))';

  /// 题目消息在 FTS 索引里的行号：索引按业务表的隐式 rowid 关联，而这里只有
  /// 消息主键，先按主键查出那一行的 rowid 再跟索引比对。
  static const String _questionMessageRowId =
      '(SELECT mm.rowid FROM message mm WHERE mm.id = $_questionMessageId)';

  /// 题干：取题目消息的正文；没有题目消息时为空。
  static const String _firstUserContent =
      '(SELECT m.content FROM message m WHERE m.conversation_id = c.id '
      "AND m.role = 'user' AND m.id = $_questionMessageId LIMIT 1)";
}
