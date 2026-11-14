import '../data/repository/evidence_repository.dart';
import '../domain/models/evidence.dart';
import '../domain/rules/query_shape.dart';
import 'cross_session_service.dart';
import 'semantic_index_service.dart';

/// 用户查找读到的一段候选；[more] 为真表示还有更早的命中没有读进来。
class SearchWindow {
  const SearchWindow({
    required this.query,
    required this.scope,
    this.hits = const [],
    this.more = false,
  });

  final String query;
  final EvidenceScope scope;
  final List<EvidenceHit> hits;
  final bool more;
}

/// 检索入口：字面命中、关键词命中与语义候选在这里合并，交给上层按来源标识去重。
///
/// 两条路径的服务范围不同。用户查找默认覆盖本机全部记录，也可以只在选定的
/// 目标或材料里找；回答前检索由调用方传入当前目标、材料与讨论，不会读到范围
/// 之外的记录。字面与关键词命中来自当前业务库，SQL 已按范围过滤；语义候选由
/// 索引提供，读取时另行核对版本与范围。关键词候选交给 BM25 排序，字面命中
/// 固定在前面，题号、页码与原句不会因为排序被挤掉。
class EvidenceService {
  EvidenceService({required this.repository, this.semantic, this.crossSession});

  final EvidenceRepository repository;

  /// 语义检索；没有配置或暂不可用时只使用原文与关键词。
  final SemanticIndexService? semantic;

  /// 跨次综合；查询带有显式时间或回看意图时补齐同题的各次作答。
  final CrossSessionService? crossSession;

  /// 用户主动查找：普通问句同时走关键词，题号、公式与原句只按原样匹配。
  ///
  /// [perKindLimit] 为空时读出全部命中再排序，查找结果不再按类别预先截断；
  /// 调用方需要分批读取时用 [userSearchWindow]。
  Future<EvidenceBundle> userSearch(
    String query, {
    EvidenceScope scope = const EvidenceScope.userAll(),
    int? perKindLimit,
    int? limit,
  }) {
    return _lookup(
      query,
      scope: scope,
      perKindLimit: perKindLimit,
      limit: limit,
      includeKeyword: true,
    );
  }

  /// 分批读取的候选窗口：最多读到 [maxHits] 条，超出时 [SearchWindow.more]
  /// 为真，调用方据此扩大窗口或停止翻页。
  ///
  /// 关键词得分来自 FTS5，同一命中的得分与读取窗口的大小无关。
  Future<SearchWindow> userSearchWindow(
    String query, {
    EvidenceScope scope = const EvidenceScope.userAll(),
    int maxHits = 800,
    int batchSize = 100,
  }) async {
    final shape = shapeQuery(query);
    if (shape.isEmpty) {
      return SearchWindow(query: shape.text, scope: scope);
    }
    final loaded = await _loadWindow(
      shape,
      scope: scope,
      maxHits: maxHits,
      batchSize: batchSize,
    );
    return SearchWindow(
      query: shape.text,
      scope: scope,
      hits: EvidenceBundle.merge(shape.text, scope, loaded.hits).hits,
      more: loaded.more,
    );
  }

  /// 回答前检索：候选限制在本次范围里，并排除当前材料页。
  Future<EvidenceBundle> forAnswer({
    required String query,
    required EvidenceScope scope,
    int perKindLimit = 6,
    int? limit,
    (int, int)? excludePage,
    DateTime? now,
    String? stem,
    int? excludeAttemptId,
  }) {
    return _lookup(
      query,
      scope: scope,
      perKindLimit: perKindLimit,
      limit: limit,
      includeKeyword: true,
      excludeConversationId: scope.conversationId,
      excludePage: excludePage,
      now: now,
      stem: stem,
      excludeAttemptId: excludeAttemptId,
    );
  }

  Future<EvidenceBundle> _lookup(
    String query, {
    required EvidenceScope scope,
    required int? perKindLimit,
    required bool includeKeyword,
    int? limit,
    int? excludeConversationId,
    (int, int)? excludePage,
    DateTime? now,
    String? stem,
    int? excludeAttemptId,
  }) async {
    final shape = shapeQuery(query);
    if (shape.isEmpty) {
      return EvidenceBundle(query: shape.text, scope: scope);
    }
    final literalHits = perKindLimit == null
        ? await repository.allLiteral(
            shape.text,
            scope: scope,
            excludeConversationId: excludeConversationId,
            excludePage: excludePage,
          )
        : await repository.literal(
            shape.text,
            scope: scope,
            limitPerKind: perKindLimit,
            excludeConversationId: excludeConversationId,
            excludePage: excludePage,
          );
    var keywordHits = includeKeyword && !shape.literal
        ? perKindLimit == null
              ? await repository.allKeyword(
                  shape.text,
                  scope: scope,
                  excludeConversationId: excludeConversationId,
                  excludePage: excludePage,
                )
              : await repository.keyword(
                  shape.text,
                  scope: scope,
                  limitPerKind: perKindLimit,
                  excludeConversationId: excludeConversationId,
                  excludePage: excludePage,
                )
        : <EvidenceHit>[];
    // 语义候选只在回答前检索时加入；失败或超时只记为不可用，不阻断本次回答。
    var semanticFailed = false;
    EvidenceTimings? timings;
    final semanticService = semantic;
    if (semanticService != null &&
        scope.isAnswerContext &&
        semanticService.configured) {
      final result = await semanticService.search(
        shape.text,
        scope: scope,
        limit: limit ?? perKindLimit ?? 40,
      );
      final semanticTimings = result.timings;
      timings = EvidenceTimings(
        embedMs: semanticTimings.embedMs,
        indexMs: semanticTimings.indexMs,
        totalMs: semanticTimings.totalMs,
        verifiedOut: semanticTimings.verifiedOut,
        candidates: semanticTimings.candidates,
      );
      if (result.usable) {
        keywordHits = [...keywordHits, ...result.hits];
      } else {
        semanticFailed = true;
      }
    }

    // 跨次综合：只在查询带有显式时间或回看意图时沿同题补齐各次作答；缺少的
    // 证据写成待确认说明，不替用户补造独立性。
    var crossNotes = const <String>[];
    final crossService = crossSession;
    var crossHits = const <EvidenceHit>[];
    if (crossService != null && scope.isAnswerContext) {
      final summary = await crossService.resolve(
        query: shape.text,
        scope: scope,
        now: now ?? DateTime.now(),
        stem: stem,
        excludeAttemptId: excludeAttemptId,
      );
      crossHits = summary.evidence;
      crossNotes = summary.pendingNotes;
    }

    return EvidenceBundle.merge(
      shape.text,
      scope,
      [...literalHits, ...keywordHits, ...crossHits],
      limit: limit,
      semanticFailed: semanticFailed,
      timings: timings,
      crossSessionNotes: crossNotes,
    );
  }

  /// 按批读取字面与关键词候选；每条路径最多读 [maxHits] 条，任一路径还有
  /// 更早的命中时记为 [SearchWindow.more]。
  Future<({List<EvidenceHit> hits, bool more})> _loadWindow(
    QueryShape shape, {
    required EvidenceScope scope,
    required int maxHits,
    required int batchSize,
  }) async {
    final hits = <EvidenceHit>[];
    var more = false;
    Future<void> load(bool literal) async {
      SearchCursor? cursor;
      var loaded = 0;
      do {
        final page = await repository.searchBatch(
          shape.text,
          scope: scope,
          literal: literal,
          batchSize: batchSize,
          after: cursor,
        );
        hits.addAll(page.hits);
        loaded += page.hits.length;
        cursor = page.hasMore ? page.cursor : null;
        if (cursor != null && loaded >= maxHits) {
          more = true;
          break;
        }
      } while (cursor != null);
    }

    await load(true);
    if (!shape.literal) await load(false);
    return (hits: hits, more: more);
  }
}
