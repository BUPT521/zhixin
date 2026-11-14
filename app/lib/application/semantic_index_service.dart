import 'dart:async';
import 'dart:math' as math;

import '../data/repository/evidence_repository.dart';
import '../data/vector/vector_index.dart';
import '../data/vector/vector_store.dart';
import '../data/vector/vector_store_isolate.dart';
import '../domain/models/evidence.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/search_terms.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'embedding_client.dart';

/// 语义检索不可用的原因；失败时调用方继续使用原文与关键词。
enum SemanticFailure { none, notConfigured, timeout, cancelled, error }

/// 一次语义检索的结果；[hits] 已经按业务记录核对过版本与范围。
class SemanticResult {
  const SemanticResult({
    this.hits = const [],
    this.failure = SemanticFailure.none,
    this.timings = const EvidenceTimings(),
    this.entries = 0,
  });

  final List<EvidenceHit> hits;
  final SemanticFailure failure;
  final EvidenceTimings timings;

  /// 索引里现有的向量条数；界面据此区分“没有找到”和“索引还没有内容”。
  /// 没有配置、超时或取消时不知道索引规模，保持为零。
  final int entries;

  bool get usable => failure == SemanticFailure.none;
}

/// 索引更新一次的结果，后台更新与界面提示共用。
class IndexRefreshResult {
  const IndexRefreshResult({
    this.embedded = 0,
    this.skipped = 0,
    this.lateSkipped = 0,
    this.failed = 0,
    this.removed = 0,
    this.total = 0,
    this.failure = SemanticFailure.none,
    this.embedMs = 0,
    this.writeMs = 0,
  });

  final int embedded;
  final int skipped;

  /// 等待嵌入期间来源被更正、删除或撤销，写回前放弃的条数。
  final int lateSkipped;
  final int failed;
  final int removed;
  final int total;
  final SemanticFailure failure;
  final int embedMs;
  final int writeMs;
}

/// 取消标记：查询开始后界面关闭或用户离开，不再等待嵌入结果。
class SemanticCancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 语义索引服务：后台按来源版本补建索引，查询时先取候选再核对业务记录。
///
/// 索引按模型、维度与文本处理版本区分；数据代次变化（恢复、导入、清空）时
/// 整份索引重建。写入前重新读取来源版本，等待嵌入期间被更正或删除的内容不会
/// 进入索引。查询有独立的超时与取消，失败时返回空结果，调用方继续使用原文
/// 与关键词。
class SemanticIndexService {
  SemanticIndexService({
    required this.repository,
    EmbeddingClient? initialClient,
    required this.indexPath,
    this.epoch,
    this.clock = systemClock,
    bool Function(SemanticSource source)? initialShareFilter,
    this.queryTimeout = const Duration(seconds: 4),
    Future<VectorStore> Function()? vectorStoreOpener,
  }) : _client = initialClient,
       _canSend = initialShareFilter,
       _openStore = vectorStoreOpener;

  final EvidenceRepository repository;

  EmbeddingClient? _client;
  bool Function(SemanticSource source)? _canSend;
  final String indexPath;

  /// 当前嵌入来源；为空表示没有配置，语义检索与索引都不可用。
  EmbeddingClient? get client => _client;

  /// 是否允许把这条来源的原文发送给远程嵌入服务；本地来源不需要判断。
  bool Function(SemanticSource source)? get canSend => _canSend;

  /// 当前数据代次（例如版本提交的 HEAD）；变化时索引按当前数据重建。
  final Future<String> Function()? epoch;
  final Clock clock;
  final Duration queryTimeout;
  final Future<VectorStore> Function()? _openStore;

  /// 换一套嵌入来源；模型或维度改变时旧索引关闭，下一次更新按新模型重建。
  void configure({
    EmbeddingClient? client,
    bool Function(SemanticSource source)? canSend,
  }) {
    final current = _client;
    if (current != null && !identical(current, client)) current.dispose();
    _client = client;
    _canSend = canSend;
    final store = _store;
    if (store != null && store.spec.indexKey != client?.spec.indexKey) {
      _store = null;
      unawaited(store.close());
    }
  }

  VectorStore? _store;
  Future<VectorStore>? _opening;
  bool _closed = false;
  IndexRefreshResult? _lastRefresh;
  Future<IndexRefreshResult>? _refreshing;

  IndexRefreshResult? get lastRefresh => _lastRefresh;

  bool get configured => client != null;

  /// 取当前索引句柄；第一次用时才打开，打开与建表都在后台 isolate 里完成。
  Future<VectorStore> _requireStore() async {
    if (_closed) throw const VectorStoreClosedException();
    final existing = _store;
    if (existing != null) return existing;
    final clientSpec = client?.spec;
    if (clientSpec == null) {
      throw const EmbeddingUnavailable('没有配置嵌入来源');
    }
    final opening = _opening;
    if (opening != null) return opening;
    final future = _open(clientSpec);
    _opening = future;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<VectorStore> _open(EmbeddingModelSpec spec) async {
    final opener = _openStore;
    final store = opener != null
        ? await opener()
        : await IsolateVectorStore.open(path: indexPath, spec: spec);
    if (_closed) {
      await store.close();
      throw const VectorStoreClosedException();
    }
    if (client?.spec.indexKey != spec.indexKey) {
      await store.close();
      throw const EmbeddingUnavailable('嵌入来源已经切换');
    }
    _store = store;
    return store;
  }

  /// 按当前数据补建索引；可以重复执行，已经是最新版本的来源会跳过。
  ///
  /// 刷新单飞：界面触发与数据代次变化撞在一起时共用同一个进行中的 Future，
  /// 后到的一次不再重复读库与嵌入。扫描是幂等的，下一次触发会补齐期间新增的
  /// 来源。
  Future<IndexRefreshResult> refresh({int? maxSources, bool force = false}) {
    final running = _refreshing;
    if (running != null) return running;
    final future = _refresh(maxSources: maxSources, force: force);
    _refreshing = future;
    return future;
  }

  Future<IndexRefreshResult> _refresh({
    int? maxSources,
    bool force = false,
  }) async {
    try {
      return await _runRefresh(maxSources: maxSources, force: force);
    } finally {
      _refreshing = null;
    }
  }

  Future<IndexRefreshResult> _runRefresh({
    int? maxSources,
    bool force = false,
  }) async {
    final embedding = client;
    if (embedding == null) {
      return const IndexRefreshResult(failure: SemanticFailure.notConfigured);
    }
    final now = clock();
    try {
      // 先读数据代次再打开索引：打开、加载 sqlite-vec 与建表都由后台 isolate
      // 承接，界面线程在这里只等一个 Future，启动首帧不再执行这些同步调用。
      final currentEpoch = await epoch?.call() ?? '0';
      final store = await _requireStore();
      if (await store.meta('epoch') != currentEpoch) {
        await store.clear();
        await store.setMeta('epoch', currentEpoch);
      }
      final sources = await repository.semanticSources(limit: maxSources);

      final indexed = await store.indexedSources();
      final keep = <String>{};
      var embedded = 0;
      var skipped = 0;
      var lateSkipped = 0;
      var failed = 0;
      var embedMs = 0;
      var writeMs = 0;

      for (final source in sources) {
        final sendable = canSend?.call(source) ?? true;
        if (!sendable) {
          // 用户缩小了可发送范围：这条来源不再进入 keep，索引里的旧向量在最后
          // 统一删除，避免继续参与检索。
          skipped++;
          continue;
        }
        keep.add(source.locator.sourceKey);
        final chunks = semanticChunks(source.content);
        final existing = indexed[source.locator.sourceKey];
        final unchanged =
            existing != null &&
            existing.sourceVersion == source.sourceVersion &&
            existing.chunks == chunks.length;
        if (unchanged && !force) {
          skipped++;
          continue;
        }
        final vectors = <List<double>>[];
        var sourceFailed = false;
        for (final chunk in chunks) {
          final started = DateTime.now();
          try {
            vectors.add(await embedding.embed(chunk.text));
          } on EmbeddingUnavailable {
            sourceFailed = true;
            break;
          } catch (_) {
            sourceFailed = true;
            break;
          } finally {
            embedMs += DateTime.now().difference(started).inMilliseconds;
          }
        }
        if (sourceFailed || vectors.length != chunks.length) {
          failed++;
          continue;
        }
        // 迟到结果写回之前重新检查来源：等待嵌入期间内容被更正、删除或撤销，
        // 就放弃这一条，等下一次更新再处理。
        final fresh = await repository.semanticSource(source.locator);
        if (fresh == null || fresh.sourceVersion != source.sourceVersion) {
          lateSkipped++;
          continue;
        }
        final writeStarted = DateTime.now();
        try {
          await store.replaceSource(
            locator: source.locator,
            sourceVersion: source.sourceVersion,
            chunks: [for (final chunk in chunks) chunk.text],
            vectors: vectors,
            createdAt: formatDateTime(now),
          );
          embedded++;
        } catch (_) {
          failed++;
        } finally {
          writeMs += DateTime.now().difference(writeStarted).inMilliseconds;
        }
      }

      final removed = await store.pruneSources(keep);
      await store.setMeta('built_at', formatDateTime(now));
      final result = IndexRefreshResult(
        embedded: embedded,
        skipped: skipped,
        lateSkipped: lateSkipped,
        failed: failed,
        removed: removed,
        total: sources.length,
        failure: failed == 0 ? SemanticFailure.none : SemanticFailure.error,
        embedMs: embedMs,
        writeMs: writeMs,
      );
      _lastRefresh = result;
      return result;
    } on Object {
      // 应用退出时索引会被关闭，进行中的刷新随之结束，不必再当作失败上报。
      if (_closed) {
        return const IndexRefreshResult(failure: SemanticFailure.cancelled);
      }
      rethrow;
    }
  }

  /// 按查询向量取候选，并逐条读取当前记录核对范围与版本。
  Future<SemanticResult> search(
    String query, {
    required EvidenceScope scope,
    int limit = 6,
    Duration? timeout,
    SemanticCancelToken? cancelToken,
  }) async {
    final embedding = client;
    if (embedding == null) {
      return const SemanticResult(failure: SemanticFailure.notConfigured);
    }
    final effectiveTimeout = timeout ?? queryTimeout;
    final total = Stopwatch()..start();
    if (cancelToken?.cancelled == true) {
      return const SemanticResult(failure: SemanticFailure.cancelled);
    }
    final embedStarted = Stopwatch()..start();
    List<double> vector;
    try {
      vector = await embedding.embed(query).timeout(effectiveTimeout);
    } on TimeoutException {
      return SemanticResult(
        failure: SemanticFailure.timeout,
        timings: EvidenceTimings(
          embedMs: embedStarted.elapsedMilliseconds,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    } on EmbeddingUnavailable {
      return SemanticResult(
        failure: SemanticFailure.error,
        timings: EvidenceTimings(
          embedMs: embedStarted.elapsedMilliseconds,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    } catch (_) {
      return SemanticResult(
        failure: SemanticFailure.error,
        timings: EvidenceTimings(
          embedMs: embedStarted.elapsedMilliseconds,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    }
    final embedMs = embedStarted.elapsedMilliseconds;
    if (cancelToken?.cancelled == true) {
      return SemanticResult(
        failure: SemanticFailure.cancelled,
        timings: EvidenceTimings(
          embedMs: embedMs,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    }
    final indexStarted = Stopwatch()..start();
    try {
      final store = await _requireStore();
      final entries = await store.entryCount();
      // 全部记录的范围里，四倍候选一般够用；限定目标或材料时，范围外的向量
      // 更容易占满候选，取二十倍并封顶 400，避免收窄范围后漏召回。
      final candidateLimit = scope.limitsToAll ? limit * 4 : limit * 20;
      final candidates = await store.search(
        vector,
        k: math.min(400, math.max(limit, candidateLimit)),
      );
      final indexMs = indexStarted.elapsedMilliseconds;
      final hits = <EvidenceHit>[];
      var verifiedOut = 0;
      for (final candidate in candidates) {
        final locator = SemanticLocator.fromJson(candidate.locatorJson);
        if (locator == null) {
          verifiedOut++;
          continue;
        }
        final hit = _hitFor(locator, candidate, query);
        final fresh = await repository.current(hit);
        if (fresh == null ||
            fresh.sourceVersion != candidate.sourceVersion ||
            !await repository.inScope(fresh, scope)) {
          verifiedOut++;
          continue;
        }
        hits.add(fresh.copyWith(literal: false, score: hit.score));
        if (hits.length >= limit) break;
      }
      return SemanticResult(
        hits: hits,
        entries: entries,
        timings: EvidenceTimings(
          embedMs: embedMs,
          indexMs: indexMs,
          totalMs: total.elapsedMilliseconds,
          verifiedOut: verifiedOut,
          candidates: candidates.length,
        ),
      );
    } catch (_) {
      // 索引打不开或读取失败时退回原文与关键词；调用方只看 usable。
      return SemanticResult(
        failure: SemanticFailure.error,
        timings: EvidenceTimings(
          embedMs: embedMs,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    }
  }

  EvidenceHit _hitFor(
    SemanticLocator locator,
    StoredVector candidate,
    String query,
  ) {
    final kind = switch (locator.kind) {
      'material_page' => EvidenceKind.materialPage,
      'answer' => EvidenceKind.answer,
      'attempt' => EvidenceKind.answer,
      'message' => EvidenceKind.message,
      _ => EvidenceKind.message,
    };
    final terms = searchTerms(query);
    return EvidenceHit(
      kind: kind,
      identity: locator.sourceKey,
      title: switch (kind) {
        EvidenceKind.materialPage => '第 ${locator.pageNo} 页',
        EvidenceKind.answer => '一次已提交作答',
        EvidenceKind.question => '题目',
        EvidenceKind.message => '一次讨论',
      },
      snippet: searchSnippet(candidate.content, terms, limit: 100),
      text: candidate.content,
      matchedText: candidate.content,
      literal: false,
      semantic: true,
      score: 10 + (1 - candidate.distance).clamp(0, 1) * 3,
      location: EvidenceLocation(
        conversationId: locator.conversationId,
        messageId: locator.messageId,
        materialId: locator.materialId,
        pageNo: locator.pageNo,
        attemptId: locator.attemptId,
      ),
      sourceVersion: candidate.sourceVersion,
    );
  }

  /// 索引规模与最近一次更新的结果，给设置页显示。
  ///
  /// 读取状态会打开索引库；打不开时异常交给调用方，设置页据此显示失败说明，
  /// 不停在“还没有读取索引状态”。
  Future<SemanticIndexStats> stats() async {
    if (client == null) {
      return const SemanticIndexStats(
        configured: false,
        entries: 0,
        sources: 0,
        modelKey: '',
      );
    }
    final store = await _requireStore();
    final indexed = await store.indexedSources();
    return SemanticIndexStats(
      configured: true,
      entries: await store.entryCount(),
      sources: indexed.length,
      modelKey: await store.meta('model_key') ?? '',
      builtAt: await store.meta('built_at'),
      lastRefresh: _lastRefresh,
    );
  }

  Future<void> clear() async {
    final store = _store;
    if (store != null) await store.clear();
  }

  Future<void> close() async {
    _closed = true;
    final store = _store;
    _store = null;
    final opening = _opening;
    if (opening != null) {
      try {
        final opened = await opening;
        if (!identical(opened, store)) await opened.close();
      } catch (_) {
        // 打开失败时的索引本来就没有建立，不必再关一次。
      }
    }
    _store = null;
    try {
      await store?.close();
    } finally {
      client?.dispose();
    }
  }
}

/// 索引规模与状态；界面只显示这些信息，不读取向量内容。
class SemanticIndexStats {
  const SemanticIndexStats({
    required this.configured,
    required this.entries,
    required this.sources,
    required this.modelKey,
    this.builtAt,
    this.lastRefresh,
  });

  final bool configured;
  final int entries;
  final int sources;
  final String modelKey;
  final String? builtAt;
  final IndexRefreshResult? lastRefresh;
}
