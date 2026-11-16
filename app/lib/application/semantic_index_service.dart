import 'dart:async';
import 'dart:math' as math;

import '../data/db/drift/queries/evidence_scope.dart';
import '../data/repository/evidence_repository.dart';
import '../data/vector/vector_index.dart';
import '../data/vector/vector_store.dart';
import '../data/vector/vector_store_isolate.dart';
import '../domain/models/evidence.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/score_weights.dart';
import '../domain/rules/search_terms.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'embedding_client.dart';
import 'service_runtime.dart';

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

  /// 清理时删除的向量条数。
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
    this.indexLogPath,
    this.epoch,
    this.clock = systemClock,
    bool Function(SemanticSource source)? initialShareFilter,
    this.queryTimeout = const Duration(seconds: 4),
    Future<VectorStore> Function()? vectorStoreOpener,
    this.recordFailure,
  }) : _client = initialClient,
       _canSend = initialShareFilter,
       _openStore = vectorStoreOpener;

  final EvidenceRepository repository;

  EmbeddingClient? _client;
  bool Function(SemanticSource source)? _canSend;
  final String indexPath;

  /// zvec 引擎的警告日志目录；为空时不写文件日志。
  final String? indexLogPath;

  /// 索引结构损坏被重建时写本机诊断记录；界面不弹窗。
  final ModelFailureRecorder? recordFailure;

  /// 当前嵌入来源；为空表示没有配置，语义检索与索引都不可用。
  EmbeddingClient? get client => _client;

  /// 是否允许把这条来源的原文发送给远程嵌入服务；本地来源不需要判断。
  bool Function(SemanticSource source)? get canSend => _canSend;

  /// 当前数据代次：`HEAD` 所在提交的 `generation`，整版恢复、导入与清理历史
  /// 时变化；变化时索引按当前数据重建，普通写入不会改变它。
  final Future<String> Function()? epoch;
  final Clock clock;
  final Duration queryTimeout;
  final Future<VectorStore> Function()? _openStore;

  /// 换一套嵌入来源；模型或维度改变时旧索引关闭，下一次更新按新模型重建。
  void configure({
    EmbeddingClient? client,
    bool Function(SemanticSource source)? canSend,
  }) {
    if (_closed) {
      client?.dispose();
      return;
    }
    final current = _client;
    final previousModel = current?.spec.indexKey;
    final nextModel = client?.spec.indexKey;
    if (!identical(current, client) || !identical(_canSend, canSend)) {
      _invalidateOperations();
    }
    if (current != null && !identical(current, client)) current.dispose();
    _client = client;
    _canSend = canSend;
    final store = _store;
    if (store != null && store.spec.indexKey != nextModel) {
      _store = null;
      unawaited(_queueStoreOperation(store.close));
    }
    if (previousModel != nextModel) _lastRefresh = null;
  }

  VectorStore? _store;
  Future<VectorStore>? _opening;
  Future<void> _storeOperations = Future<void>.value();
  Future<void>? _closing;
  int _generation = 0;
  bool _closed = false;
  IndexRefreshResult? _lastRefresh;
  Future<IndexRefreshResult>? _refreshing;

  IndexRefreshResult? get lastRefresh => _lastRefresh;

  bool get configured => client != null;

  void _invalidateOperations() {
    _generation++;
    _opening = null;
    _refreshing = null;
  }

  void _requireCurrent(int generation) {
    if (_closed) throw const VectorStoreClosedException();
    if (generation != _generation) {
      throw const EmbeddingUnavailable('语义索引的配置或内容已经变更');
    }
  }

  Future<T> _queueStoreOperation<T>(Future<T> Function() operation) {
    final next = _storeOperations.then((_) => operation());
    // 每个请求处理自己的失败，后续操作仍可关闭或重新打开索引。
    _storeOperations = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<T> _useCurrentStore<T>(int generation, Future<T> Function() use) =>
      _queueStoreOperation(() {
        _requireCurrent(generation);
        return use();
      });

  /// 取当前索引句柄；第一次用时才打开，打开与建表都在后台 isolate 里完成。
  Future<VectorStore> _requireStore(int generation) async {
    _requireCurrent(generation);
    final clientSpec = client?.spec;
    if (clientSpec == null) {
      throw const EmbeddingUnavailable('没有配置嵌入来源');
    }
    final opening = _opening;
    if (opening != null) {
      final store = await opening;
      _requireCurrent(generation);
      return store;
    }
    final future = _queueStoreOperation(() => _open(clientSpec, generation));
    _opening = future;
    try {
      final store = await future;
      _requireCurrent(generation);
      return store;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<VectorStore> _open(EmbeddingModelSpec spec, int generation) async {
    _requireCurrent(generation);
    final existing = _store;
    if (existing != null) return existing;
    final opener = _openStore;
    final store = opener != null
        ? await opener()
        : await IsolateVectorStore.open(
            path: indexPath,
            spec: spec,
            logDirectory: indexLogPath,
            onRebuild: _recordRebuild,
          );
    if (generation != _generation) {
      await store.close();
      _requireCurrent(generation);
    }
    _store = store;
    return store;
  }

  /// 结构损坏时重建空索引只记本机诊断，不弹窗、不打断检索。
  void _recordRebuild(String reason) {
    final record = recordFailure;
    if (record == null) return;
    record(_SemanticIndexRebuilt(reason), null, kind: 'semantic_index');
  }

  /// 按当前数据补建索引；可以重复执行，已经是最新版本的来源会跳过。
  ///
  /// 刷新单飞：界面触发与数据代次变化撞在一起时共用同一个进行中的 Future，
  /// 后到的一次不再重复读库与嵌入。扫描是幂等的，下一次触发会补齐期间新增的
  /// 来源。
  Future<IndexRefreshResult> refresh({int? maxSources, bool force = false}) {
    final running = _refreshing;
    if (running != null) return running;
    final future = _refresh(_generation, maxSources: maxSources, force: force);
    _refreshing = future;
    return future;
  }

  Future<IndexRefreshResult> _refresh(
    int generation, {
    int? maxSources,
    bool force = false,
  }) async {
    try {
      return await _runRefresh(
        generation,
        maxSources: maxSources,
        force: force,
      );
    } finally {
      if (generation == _generation) _refreshing = null;
    }
  }

  Future<IndexRefreshResult> _runRefresh(
    int generation, {
    int? maxSources,
    bool force = false,
  }) async {
    final embedding = client;
    if (embedding == null) {
      return const IndexRefreshResult(failure: SemanticFailure.notConfigured);
    }
    final now = clock();
    try {
      // 先读数据代次再打开索引：打开、初始化 zvec 引擎与建表都由后台 isolate
      // 承接，界面线程在这里只等一个 Future，启动首帧不再执行这些同步调用。
      final currentEpoch = await epoch?.call() ?? '0';
      final store = await _requireStore(generation);
      if (await store.meta('epoch') != currentEpoch) {
        await _useCurrentStore(generation, () async {
          await store.clear();
          await store.setMeta('epoch', currentEpoch);
        });
      }
      final sources = await repository.semanticSources();
      _requireCurrent(generation);

      // 嵌入数量可以分批限制，清理与统计仍以全部允许进入索引的来源为准。
      final sendAllowed = canSend;
      final keep = {
        for (final source in sources)
          if (sendAllowed?.call(source) ?? true) source.locator.sourceKey,
      };
      final indexed = await store.indexedSources(keep.toList(growable: false));
      final committed = indexed.keys.toSet();
      final batch = maxSources == null
          ? sources
          : sources.take(maxSources).toList(growable: false);
      var embedded = 0;
      var writtenEntries = 0;
      var skipped = 0;
      var lateSkipped = 0;
      var failed = 0;
      var embedMs = 0;
      var writeMs = 0;

      for (final source in batch) {
        _requireCurrent(generation);
        final sourceKey = source.locator.sourceKey;
        if (!keep.contains(sourceKey)) {
          // 用户缩小了可发送范围：这条来源不再进入 keep，索引里的旧向量在最后
          // 统一删除，避免继续参与检索。
          skipped++;
          continue;
        }
        final chunks = semanticChunks(source.content);
        final existing = indexed[sourceKey];
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
          _requireCurrent(generation);
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
        _requireCurrent(generation);
        final fresh = await repository.semanticSource(source.locator);
        if (fresh == null || fresh.sourceVersion != source.sourceVersion) {
          lateSkipped++;
          continue;
        }
        final writeStarted = DateTime.now();
        try {
          await _useCurrentStore(
            generation,
            () => store.replaceSource(
              locator: source.locator,
              sourceVersion: source.sourceVersion,
              chunks: [for (final chunk in chunks) chunk.text],
              vectors: vectors,
              createdAt: formatDateTime(now),
            ),
          );
          embedded++;
          writtenEntries += chunks.length;
          if (chunks.isEmpty) {
            committed.remove(sourceKey);
          } else {
            committed.add(sourceKey);
          }
        } catch (_) {
          failed++;
        } finally {
          writeMs += DateTime.now().difference(writeStarted).inMilliseconds;
        }
      }

      final removed = await _useCurrentStore(generation, () async {
        final removed = await store.pruneSources(keep);
        await store.finishRefresh(
          builtAt: formatDateTime(now),
          sourceCount: committed.length,
          writtenEntries: writtenEntries,
        );
        return removed;
      });
      _requireCurrent(generation);
      final result = IndexRefreshResult(
        embedded: embedded,
        skipped: skipped,
        lateSkipped: lateSkipped,
        failed: failed,
        removed: removed,
        total: batch.length,
        failure: failed == 0 ? SemanticFailure.none : SemanticFailure.error,
        embedMs: embedMs,
        writeMs: writeMs,
      );
      _lastRefresh = result;
      return result;
    } on Object {
      // 退出、切换配置和清空都会让原来的刷新结束。
      if (_closed || generation != _generation) {
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
    final generation = _generation;
    final effectiveTimeout = timeout ?? queryTimeout;
    final total = Stopwatch()..start();
    if (cancelToken?.cancelled == true) {
      return const SemanticResult(failure: SemanticFailure.cancelled);
    }
    // 回答前检索没有目标归属、也没有当前讨论与带入来源时，业务规则一条也
    // 不放行，这里直接返回空结果，不再嵌入与检索。
    if (scope.isAnswerContext &&
        scope.goalId == null &&
        scope.conversationId == null &&
        scope.broughtIdentities.isEmpty) {
      return const SemanticResult();
    }
    final embedStarted = Stopwatch()..start();
    List<double> vector;
    try {
      vector = await embedding.embed(query).timeout(effectiveTimeout);
    } catch (error) {
      final failure = switch (error) {
        _ when generation != _generation || cancelToken?.cancelled == true =>
          SemanticFailure.cancelled,
        TimeoutException() => SemanticFailure.timeout,
        _ => SemanticFailure.error,
      };
      return SemanticResult(
        failure: failure,
        timings: EvidenceTimings(
          embedMs: embedStarted.elapsedMilliseconds,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    }
    final embedMs = embedStarted.elapsedMilliseconds;
    if (cancelToken?.cancelled == true || generation != _generation) {
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
      final store = await _requireStore(generation);
      final entries = await store.entryCount();
      _requireCurrent(generation);
      // 范围能下推时引擎在索引内部先过滤，候选不再被范围外的向量占满，
      // 保留四倍；不能下推的目标范围仍取二十倍并封顶 400，避免漏召回。
      final prefilter = vectorPrefilterFor(scope);
      final candidateLimit = prefilter == null
          ? (scope.limitsToAll ? limit * 4 : limit * 20)
          : limit * 4;
      final candidates = await store.search(
        vector,
        k: math.min(400, math.max(limit, candidateLimit)),
        prefilter: prefilter,
      );
      _requireCurrent(generation);
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
      _requireCurrent(generation);
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
        failure: generation == _generation
            ? SemanticFailure.error
            : SemanticFailure.cancelled,
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
        EvidenceKind.unknown => '来源未知',
      },
      snippet: searchSnippet(candidate.content, terms, limit: 100),
      text: candidate.content,
      matchedText: candidate.content,
      literal: false,
      semantic: true,
      score: semanticMatchScore(candidate.distance),
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
    final generation = _generation;
    final store = await _requireStore(generation);
    final stats = await _useCurrentStore(
      generation,
      () async => SemanticIndexStats(
        configured: true,
        entries: await store.entryCount(),
        sources: await store.sourceCount(),
        modelKey: store.spec.indexKey,
        builtAt: await store.meta('built_at'),
        lastRefresh: _lastRefresh,
      ),
    );
    _requireCurrent(generation);
    return stats;
  }

  Future<void> clear() async {
    final spec = client?.spec;
    if (_closed || spec == null) return;
    _invalidateOperations();
    final generation = _generation;
    await _queueStoreOperation(() async {
      final store = await _open(spec, generation);
      _requireCurrent(generation);
      await store.clear();
      if (generation == _generation) _lastRefresh = null;
    });
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    _invalidateOperations();
    final store = _store;
    _store = null;
    final next = _closing = _queueStoreOperation(() async {
      await store?.close();
    });
    _client?.dispose();
    _client = null;
    return next;
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

/// 索引结构损坏被重建时交给本机诊断记录的说明；原文与调用栈不进入界面。
class _SemanticIndexRebuilt implements Exception {
  const _SemanticIndexRebuilt(this.reason);

  final String reason;

  @override
  String toString() => '语义索引结构损坏，已重建空索引：$reason';
}
