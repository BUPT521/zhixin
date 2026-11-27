import 'dart:async';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/db/drift/queries/evidence_scope.dart';
import '../data/revisions/revision_cursor.dart';
import '../data/revisions/semantic_change.dart';
import '../data/repository/evidence_repository.dart';
import '../data/vector/embedding_codec.dart';
import '../data/vector/vector_index.dart';
import '../data/vector/vector_store.dart';
import '../data/vector/vector_store_isolate.dart';
import '../domain/models/evidence.dart';
import '../domain/models/memory.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/search_terms.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'embedding_client.dart';
import 'memory_recall.dart';
import 'search_index_fusion.dart';

import 'service_runtime.dart';

part 'search_index_memory.dart';
part 'search_index_refresh.dart';

/// 索引检索不可用的原因；失败时调用方继续使用字面命中。
enum IndexFailure { none, notConfigured, timeout, cancelled, error }

/// 一次索引检索的结果；[hits] 已经按业务记录核对过版本与范围。
class IndexResult {
  const IndexResult({
    this.hits = const [],
    this.failure = IndexFailure.none,
    this.timings = const EvidenceTimings(),
    this.entries = 0,
  });

  final List<EvidenceHit> hits;
  final IndexFailure failure;
  final EvidenceTimings timings;

  /// 索引里现有的片段条数（取文本集合）；界面据此区分“没有找到”和“索引还
  /// 没有内容”。没有配置、超时或取消时不知道索引规模，保持为零。
  final int entries;

  bool get usable => failure == IndexFailure.none;
}

/// 索引更新一次的结果，后台更新与界面提示共用。
class IndexRefreshResult {
  const IndexRefreshResult({
    this.embedded = 0,
    this.textWritten = 0,
    this.skipped = 0,
    this.lateSkipped = 0,
    this.failed = 0,
    this.removed = 0,
    this.total = 0,
    this.cached = 0,
    this.failure = IndexFailure.none,
    this.embedMs = 0,
    this.writeMs = 0,
    this.sourceProblem,
  });

  /// 这一次重新计算并向向量集合写入的来源数；没有配置嵌入来源时，是写入
  /// 文本集合的来源数。
  final int embedded;

  /// 写入文本集合的来源数；换模型之后正文没有变化的来源也计入，但它们不重新
  /// 嵌入，因此不计入 [embedded]。
  final int textWritten;
  final int skipped;

  /// 等待嵌入期间来源被更正、删除或撤销，写回前放弃的条数。
  final int lateSkipped;
  final int failed;

  /// 向量集合清理时删除的向量条数。
  final int removed;
  final int total;

  /// 直接取回服务端缓存、没有重新嵌入的片段数；命中时省掉的是嵌入与计费。
  final int cached;
  final IndexFailure failure;
  final int embedMs;
  final int writeMs;

  /// 嵌入来源整个用不了时的说明（没有登录、凭据被拒、额度用完）；这时本次
  /// 剩余的来源不再请求，全部记为失败，下一次更新再补。
  final String? sourceProblem;
}

/// 取消标记：查询开始后界面关闭或用户离开，不再等待嵌入结果。
class IndexCancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 检索索引服务：后台按来源版本补建索引，查询时先取候选再核对业务记录。
///
/// 索引拆成两个 collection（ADR-0030 决定第 4 条）：文本 collection 的 schema
/// 固定，只存正文与全文索引，不随嵌入配置变化；向量 collection 按嵌入模型键
/// 与文本处理版本分目录，只存向量、来源键与文本哈希。文本 collection 总是
/// 使用，向量 collection 只在配置了嵌入来源时打开。关键词与向量两路各取候选，
/// 由应用层按名次倒数相加融合，再逐条回读业务记录核对版本与范围；向量集合
/// 打不开时关键词一路仍然可用。
///
/// 数据代次变化（恢复、导入、清空）时两份集合都按当前数据重建。写入前重新
/// 读取来源版本，等待嵌入期间被更正或删除的内容不会进入索引。查询有独立的
/// 超时与取消，文本集合失败时返回空结果，调用方继续使用字面命中。
///
/// “已处理到的提交编号”记在库里的 `revision_cursor` 非阻塞位置（[IndexCursorNames]），
/// 两份状态文件只留模型键、维度、数据代次与可发送范围签名；位置落后只会退回
/// 全量重建，不阻止历史裁剪与清理（方案 3.12）。
///
/// 同一个后台 isolate 里还有一套记忆索引（[rankMemories]）：材料页、消息与作答
/// 的 collection 要按证据记录逐条核对范围与版本，记忆按记忆表的有效性判断，
/// 两者核对规则不同，所以分成两个 collection，记忆的候选不会占掉记录的候选位。
class SearchIndexService implements MemoryRelevanceRanker {
  SearchIndexService({
    required this.repository,
    EmbeddingClient? initialClient,
    required this.indexPath,
    this.indexLogPath,
    this.memoryIndexPath,
    this.epoch,
    this.clock = systemClock,
    bool Function(SemanticSource source)? initialShareFilter,
    this.queryTimeout = const Duration(seconds: 4),
    Future<VectorStore> Function()? vectorStoreOpener,
    Future<VectorStore> Function()? textStoreOpener,
    Future<VectorStore> Function()? memoryStoreOpener,
    this.recordFailure,
    this.cacheWrites,
    this.headCommit,
    this.semanticChanges,
    this.shareSignature,
    this.indexCursors,
  }) : _client = initialClient,
       _canSend = initialShareFilter,
       _openVectorStore = vectorStoreOpener,
       _openTextStore = textStoreOpener,
       _openMemoryStore = memoryStoreOpener;

  /// 一次刷新在内存里保留的片段上限；一个窗口写完再取下一批，内存不随来源
  /// 总数增长。
  static const int _refreshWindowChunks = 96;

  /// 一次嵌入请求的条数与字符上限；向量维度不变，批次按正文长度切分。
  /// 条数按常见 OpenAI 兼容接口的下限取 10，整批被拒时还有逐条重发兜底。
  static const int _embedBatchMaxItems = 10;
  static const int _embedBatchMaxChars = 4000;

  /// 同时在途的嵌入请求数；手机网络下再高容易触发服务商限流。
  static const int _embedConcurrency = 4;

  /// 整批失败后的重试次数，仍失败时逐条重发以定位坏文本。
  static const int _embedBatchAttempts = 2;

  final EvidenceRepository repository;

  EmbeddingClient? _client;
  bool Function(SemanticSource source)? _canSend;
  final String indexPath;

  /// zvec 引擎的警告日志目录；为空时不写文件日志。
  final String? indexLogPath;

  /// 索引结构损坏被重建时写本机诊断记录；界面不弹窗。
  final ModelFailureRecorder? recordFailure;

  /// 当前嵌入来源；为空表示没有配置，关键词仍按文本集合检索。
  EmbeddingClient? get client => _client;

  /// 是否允许把这条来源的原文发送给知新服务；本地来源不需要判断。
  bool Function(SemanticSource source)? get canSend => _canSend;

  /// 当前数据代次：`HEAD` 所在提交的 `generation`，整版恢复、导入与清理历史
  /// 时变化；变化时索引按当前数据重建，普通写入不会改变它。
  final Future<String> Function()? epoch;
  final Clock clock;
  final Duration queryTimeout;
  final Future<VectorStore> Function()? _openVectorStore;

  /// 文本集合的注入入口；测试用它换成内存实现。没有注入时用后台 isolate。
  final Future<VectorStore> Function()? _openTextStore;

  /// 这一次刷新该不该把嵌入写进服务端缓存：登录且自动同步开启时返回真。
  ///
  /// 由应用根提供，每次刷新读一次；没有提供时按不写处理。缓存属于派生数据，
  /// 未登录与同步关闭的用户不留下它（ADR-0030 决定第 3 条）。
  final Future<bool> Function()? cacheWrites;

  /// 当前 `HEAD` 的提交编号；没有提供时每次刷新都做全量扫描，也不推进已处理
  /// 提交。读取失败按不知道处理，本次退回全量。
  final Future<int> Function()? headCommit;

  /// 读出某个提交之后的来源行变化；没有提供时不做增量刷新。
  ///
  /// 应用根用版本引擎读取 `revision_change` 并按材料页、消息与作答三张表筛选，
  /// 起点提交已经被历史裁剪时返回 `usable: false`，刷新据此退回全量扫描。
  final Future<SemanticChangeWindow> Function(int after)? semanticChanges;

  /// 可发送范围签名：分享范围与选定的材料列表拼成，变化时向量集合整份重建。
  ///
  /// 缩小的范围内旧向量必须消失，签名与状态文件里记的不一致时清空向量集合；
  /// 没有提供时不做这项判断。
  final String Function()? shareSignature;

  /// 索引读取位置的读写入口；没有提供时每次按全量扫描，也不登记位置。
  ///
  /// 检索索引与记忆索引“已处理到的提交编号”记在 `revision_cursor` 的非阻塞
  /// 位置（[IndexCursorNames]），不再写在各自的状态文件里；状态文件只保留模型
  /// 键、维度、数据代次与可发送范围签名（方案 3.12）。位置落后只会多扫一次，
  /// 所以它不阻止裁剪与清理历史。
  final RevisionCursors Function()? indexCursors;

  /// 记忆索引目录；为空时放在语义索引目录的同级，随本机数据一起删除。
  final String? memoryIndexPath;
  final Future<VectorStore> Function()? _openMemoryStore;

  /// 换一套嵌入来源；模型或维度改变时只关闭向量集合，文本集合保持打开。
  ///
  /// 下一次刷新按新模型重建向量 collection；已经写好的正文不必重新写，缓存
  /// 查找逻辑照旧跳过没有变化的片段。
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
    final vector = _vectorHandle.store;
    if (vector != null && vector.spec.indexKey != nextModel) {
      _vectorHandle.store = null;
      _vectorHandle.opening = null;
      unawaited(_queueStoreOperation(vector.close));
    }
    if (previousModel != nextModel) _lastRefresh = null;
  }

  /// 一份 collection 的句柄与正在进行的打开；文本与向量各一份。
  final _StoreHandle _textHandle = _StoreHandle();
  final _StoreHandle _vectorHandle = _StoreHandle();
  Future<void> _storeOperations = Future<void>.value();
  Future<void>? _closing;
  int _generation = 0;
  bool _closed = false;
  IndexRefreshResult? _lastRefresh;
  Future<IndexRefreshResult>? _refreshing;

  /// 本次刷新处理完之后又出现了更大的 `HEAD`：在单飞清理之后补排一次刷新。
  ///
  /// 不能在刷新内部直接调用 [refresh]，那时 `_refreshing` 还指着本次的 Future，
  /// 调用只会拿回同一个 Future；所以这里只记一个标记，由 [_refresh] 的清尾在
  /// 清空 `_refreshing` 之后再排一次。
  bool _catchUpPending = false;

  IndexRefreshResult? get lastRefresh => _lastRefresh;

  bool get configured => client != null;

  void _invalidateOperations() {
    _generation++;
    // 进行中的打开会因为代次变化自行关闭，这里的句柄留空，等下一次重新打开。
    _textHandle.opening = null;
    _vectorHandle.opening = null;
    _refreshing = null;
  }

  void _requireCurrent(int generation) {
    if (_closed) throw const VectorStoreClosedException();
    if (generation != _generation) {
      throw const EmbeddingUnavailable('检索索引的配置或内容已经变更');
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

  /// 文本 collection 的根目录；固定 schema，不随嵌入配置变化。
  String get textIndexDirectory =>
      p.join(indexPath, textCollectionDirectoryName);

  /// 向量 collection 的根目录；按当前嵌入来源的 spec 分 collection 目录。
  String get vectorIndexDirectory =>
      p.join(indexPath, vectorCollectionDirectoryName);

  /// 取一份 collection 的句柄；第一次用时才打开，打开与建表都在后台 isolate
  /// 里完成。两份 collection 各自按代次检查，代次变化时旧句柄关闭、不写回。
  Future<VectorStore> _requireStoreHandle(
    _StoreHandle handle,
    int generation,
    Future<VectorStore> Function() open,
  ) async {
    _requireCurrent(generation);
    final opening = handle.opening;
    if (opening != null) {
      final store = await opening;
      _requireCurrent(generation);
      return store;
    }
    final future = _queueStoreOperation(() async {
      _requireCurrent(generation);
      final existing = handle.store;
      if (existing != null) return existing;
      final store = await open();
      if (generation != _generation) {
        await store.close();
        _requireCurrent(generation);
      }
      handle.store = store;
      return store;
    });
    handle.opening = future;
    try {
      final store = await future;
      _requireCurrent(generation);
      return store;
    } finally {
      if (identical(handle.opening, future)) handle.opening = null;
    }
  }

  Future<VectorStore> _requireTextStore(int generation) =>
      _requireStoreHandle(_textHandle, generation, () => _openText(generation));

  Future<VectorStore> _requireVectorStore(int generation) {
    final spec = client?.spec;
    if (spec == null) {
      throw const EmbeddingUnavailable('没有配置嵌入来源，不打开向量集合');
    }
    return _requireStoreHandle(
      _vectorHandle,
      generation,
      () => _openVector(spec, generation),
    );
  }

  Future<VectorStore> _openCollection({
    required String path,
    required EmbeddingModelSpec spec,
    required Future<VectorStore> Function()? opener,
    required int generation,
  }) async {
    _requireCurrent(generation);
    final store = opener != null
        ? await opener()
        : await IsolateVectorStore.open(
            path: path,
            spec: spec,
            logDirectory: indexLogPath,
            onRebuild: _recordRebuild,
          );
    if (generation != _generation) {
      await store.close();
      _requireCurrent(generation);
    }
    return store;
  }

  Future<VectorStore> _openText(int generation) => _openCollection(
    path: textIndexDirectory,
    spec: textOnlyModelSpec,
    opener: _openTextStore,
    generation: generation,
  );

  Future<VectorStore> _openVector(EmbeddingModelSpec spec, int generation) =>
      _openCollection(
        path: vectorIndexDirectory,
        spec: spec,
        opener: _openVectorStore,
        generation: generation,
      );

  /// 结构损坏时重建空索引只记本机诊断，不弹窗、不打断检索。
  void _recordRebuild(String reason) {
    final record = recordFailure;
    if (record == null) return;
    record(_IndexRebuilt(reason), null, kind: 'semantic_index');
  }

  VectorStore? _memoryStore;
  Future<VectorStore>? _memoryOpening;

  /// 记忆索引目录：与语义索引同级，清空本机数据时一起删除。
  String get memoryIndexDirectory =>
      memoryIndexPath ?? p.join(p.dirname(indexPath), memoryIndexDirectoryName);

  /// 记忆召回排序：实现与同步逻辑在 search_index_memory.dart。
  @override
  Future<List<String>?> rankMemories({
    required String query,
    required List<Memory> memories,
    required List<String> candidateIds,
  }) => memoryRelevanceOrder(
    query: query,
    memories: memories,
    candidateIds: candidateIds,
  );

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

  /// 分别取关键词与向量两路候选，按名次融合后逐条读取当前记录核对范围与版本。
  ///
  /// 查询向量只在配置了嵌入来源时计算；向量集合不可用时只用文本一路，检索
  /// 仍然可用。文本摘要按核对之后的当前记录重新计算，因此向量集合不存正文也
  /// 能显示命中片段。
  Future<IndexResult> search(
    String query, {
    required EvidenceScope scope,
    int limit = 6,
    Duration? timeout,
    IndexCancelToken? cancelToken,
  }) async {
    final embedding = client;
    final generation = _generation;
    final effectiveTimeout = timeout ?? queryTimeout;
    final total = Stopwatch()..start();
    if (cancelToken?.cancelled == true) {
      return const IndexResult(failure: IndexFailure.cancelled);
    }
    // 回答前检索没有目标归属、也没有当前讨论与带入来源时，业务规则一条也
    // 不放行，这里直接返回空结果，不再嵌入与检索。
    if (scope.isAnswerContext &&
        scope.goalId == null &&
        scope.conversationId == null &&
        scope.broughtIdentities.isEmpty) {
      return const IndexResult();
    }
    final embedStarted = Stopwatch()..start();
    List<double>? vector;
    if (embedding != null) {
      try {
        vector = await embedding.embed(query).timeout(effectiveTimeout);
      } catch (error) {
        final failure = switch (error) {
          _ when generation != _generation || cancelToken?.cancelled == true =>
            IndexFailure.cancelled,
          TimeoutException() => IndexFailure.timeout,
          _ => IndexFailure.error,
        };
        return IndexResult(
          failure: failure,
          timings: EvidenceTimings(
            embedMs: embedStarted.elapsedMilliseconds,
            totalMs: total.elapsedMilliseconds,
          ),
        );
      }
      if (cancelToken?.cancelled == true || generation != _generation) {
        return IndexResult(
          failure: IndexFailure.cancelled,
          timings: EvidenceTimings(
            embedMs: embedStarted.elapsedMilliseconds,
            totalMs: total.elapsedMilliseconds,
          ),
        );
      }
    }
    final embedMs = embedStarted.elapsedMilliseconds;
    final indexStarted = Stopwatch()..start();
    try {
      // 文本集合总是参与；它的条数就是索引里现有的片段数。
      final textStore = await _requireTextStore(generation);
      final entries = await textStore.entryCount();
      _requireCurrent(generation);
      // 范围能下推时引擎在索引内部先过滤，候选保留四倍；不能下推的目标范围
      // 仍取二十倍并封顶 400，避免收窄范围后漏召回。两路用同一个 k。
      final prefilter = vectorPrefilterFor(scope);
      final candidateLimit = prefilter == null
          ? (scope.limitsToAll ? limit * 4 : limit * 20)
          : limit * 4;
      final k = math.min(400, math.max(limit, candidateLimit));
      final textCandidates = await textStore.searchText(
        query,
        k: k,
        prefilter: prefilter,
      );
      _requireCurrent(generation);
      // 向量集合打不开或查询失败时只用关键词一路：索引坏了不该让关键词检索
      // 一起不可用，这种情况不置 failure。
      var vectorCandidates = const <StoredVector>[];
      if (vector != null) {
        try {
          final vectorStore = await _requireVectorStore(generation);
          vectorCandidates = await vectorStore.search(
            vector,
            k: k,
            prefilter: prefilter,
          );
          _requireCurrent(generation);
        } catch (_) {
          if (_closed || generation != _generation) rethrow;
          vectorCandidates = const [];
        }
      }
      // 应用层按名次倒数相加融合两路候选（ADR-0030 决定第 4 条）；同一片段
      // 在两路都出现时分数据说它更相关，只在一路出现时保留那一路的名次。
      final candidates = fuseCandidates([textCandidates, vectorCandidates]);
      // 只由向量一路命中的来源才标“按意思”；两路都命中的按下关键词处理。
      final textKeys = {for (final match in textCandidates) match.sourceKey};
      final vectorKeys = {
        for (final match in vectorCandidates) match.sourceKey,
      };
      final indexMs = indexStarted.elapsedMilliseconds;
      final terms = searchTerms(query);
      final hits = <EvidenceHit>[];
      var verifiedOut = 0;
      for (final candidate in candidates) {
        final locator = SemanticLocator.fromJson(candidate.locatorJson);
        if (locator == null) {
          verifiedOut++;
          continue;
        }
        final semanticOnly =
            vectorKeys.contains(candidate.sourceKey) &&
            !textKeys.contains(candidate.sourceKey);
        final hit = hitForCandidate(locator, candidate, semantic: semanticOnly);
        final fresh = await repository.current(hit);
        if (fresh == null ||
            fresh.sourceVersion != candidate.sourceVersion ||
            !await repository.inScope(fresh, scope)) {
          verifiedOut++;
          continue;
        }
        // 摘要按当前记录重新计算：向量集合不存正文，候选里也可能只有片段。
        hits.add(
          fresh.copyWith(
            literal: false,
            semantic: semanticOnly,
            score: hit.score,
            snippet: searchSnippet(fresh.text, terms, limit: 100),
          ),
        );
        if (hits.length >= limit) break;
      }
      _requireCurrent(generation);
      return IndexResult(
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
      // 文本集合打不开或读取失败时退回原文；调用方只看 usable。
      return IndexResult(
        failure: generation == _generation
            ? IndexFailure.error
            : IndexFailure.cancelled,
        timings: EvidenceTimings(
          embedMs: embedMs,
          totalMs: total.elapsedMilliseconds,
        ),
      );
    }
  }

  /// 索引规模与最近一次更新的结果，给设置页显示。
  ///
  /// 条数与来源数取文本集合：它总是参与检索，也是检索结果条数的来源。模型键
  /// 直接取当前嵌入来源，不由向量句柄给出，这样向量集合结构损坏时设置页仍能
  /// 读出正文索引的规模。读取状态会打开索引库；文本集合打不开时异常交给调用
  /// 方，设置页据此显示失败说明。
  Future<IndexStats> stats() async {
    final spec = client?.spec;
    if (spec == null) {
      return const IndexStats(
        configured: false,
        entries: 0,
        sources: 0,
        modelKey: '',
      );
    }
    final generation = _generation;
    final textStore = await _requireTextStore(generation);
    final stats = await _useCurrentStore(
      generation,
      () async => IndexStats(
        configured: true,
        entries: await textStore.entryCount(),
        sources: await textStore.sourceCount(),
        modelKey: spec.indexKey,
        builtAt: await textStore.meta('built_at'),
        lastRefresh: _lastRefresh,
      ),
    );
    _requireCurrent(generation);
    return stats;
  }

  /// 清空全部记录之前释放索引句柄：关闭 collection 但不关闭服务。
  ///
  /// 索引目录由删除本机数据的流程删除；嵌入来源保持配置，下一次刷新会在同一
  /// 路径重新建立 collection。已经发出的索引请求按取消处理，不会写回旧句柄。
  Future<void> release() async {
    if (_closed) return;
    _invalidateOperations();
    final text = _textHandle.store;
    final vector = _vectorHandle.store;
    final memory = _memoryStore;
    _textHandle.store = null;
    _vectorHandle.store = null;
    _memoryStore = null;
    _lastRefresh = null;
    await _queueStoreOperation(() async {
      await text?.close();
      await vector?.close();
      await memory?.close();
    });
  }

  /// 清空两份索引的条目；记忆索引与嵌入配置无关，已经在用时一并清空。
  ///
  /// 文本集合即使这次运行还没有打开过也要打开再清空，避免磁盘上留着旧索引；
  /// 向量集合只在配置了嵌入来源、知道该开哪个模型目录时清理。清空复用已经
  /// 打开的句柄，不另开一份：同一个 collection 同一时刻只允许一个句柄，另开
  /// 会撞上“索引正被占用”，也会把旧句柄留在后台线程里。
  Future<void> clear() async {
    if (_closed) return;
    _invalidateOperations();
    final generation = _generation;
    final spec = client?.spec;
    final textStore = await _requireTextStore(generation);
    await _useCurrentStore(generation, textStore.clear);
    if (spec != null) {
      final vectorStore = await _requireVectorStore(generation);
      await _useCurrentStore(generation, vectorStore.clear);
    }
    // 没有打开过的记忆索引不在这里新建：它只保存记忆正文，下一次召回会按
    // 记忆表重新同步。
    await _useCurrentStore(generation, () async => _memoryStore?.clear());
    if (generation == _generation) _lastRefresh = null;
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    _invalidateOperations();
    final text = _textHandle.store;
    final vector = _vectorHandle.store;
    final memory = _memoryStore;
    _textHandle.store = null;
    _vectorHandle.store = null;
    _memoryStore = null;
    final next = _closing = _queueStoreOperation(() async {
      await text?.close();
      await vector?.close();
      await memory?.close();
    });
    _client?.dispose();
    _client = null;
    return next;
  }
}

/// 一份 collection 的句柄与正在进行的打开。
///
/// 文本与向量各一份：换模型只把向量这一份关掉，另一份保持打开；打开期间另一
/// 个调用复用同一个 Future，不重复建表。
class _StoreHandle {
  VectorStore? store;
  Future<VectorStore>? opening;
}

/// 索引规模与状态；界面只显示这些信息，不读取向量内容。
class IndexStats {
  const IndexStats({
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
class _IndexRebuilt implements Exception {
  const _IndexRebuilt(this.reason);

  final String reason;

  @override
  String toString() => '检索索引结构损坏，已重建空索引：$reason';
}
