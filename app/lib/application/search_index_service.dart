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
import '../domain/models/score.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/search_terms.dart';
import '../domain/rules/time_format.dart';
import '../domain/rules/time_policy.dart';
import 'embedding_client.dart';
import 'memory_recall.dart';
import 'service_runtime.dart';

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

  /// 取记忆索引句柄；第一次排序时才在后台 isolate 里打开并建表。
  Future<VectorStore> _requireMemoryStore(int generation) async {
    _requireCurrent(generation);
    final opening = _memoryOpening;
    if (opening != null) {
      final store = await opening;
      _requireCurrent(generation);
      return store;
    }
    final future = _queueStoreOperation(() => _openMemory(generation));
    _memoryOpening = future;
    try {
      final store = await future;
      _requireCurrent(generation);
      return store;
    } finally {
      if (identical(_memoryOpening, future)) _memoryOpening = null;
    }
  }

  Future<VectorStore> _openMemory(int generation) async {
    _requireCurrent(generation);
    final existing = _memoryStore;
    if (existing != null) return existing;
    final opener = _openMemoryStore;
    final store = opener != null
        ? await opener()
        : await IsolateVectorStore.open(
            path: memoryIndexDirectory,
            // 记忆只做全文索引：正文多是个人说明，共享范围按材料定义，没有覆盖
            // 记忆；而且一次回答最多带入四十条，正文本来就会整段进提示词。
            spec: textOnlyModelSpec,
            logDirectory: indexLogPath,
            onRebuild: _recordRebuild,
          );
    if (generation != _generation) {
      await store.close();
      _requireCurrent(generation);
    }
    _memoryStore = store;
    return store;
  }

  /// 记忆召回的排序：先按当前记忆表同步索引，再在候选里按查询相关度给出先后。
  ///
  /// 只维护记忆正文的全文索引，不调用嵌入来源：记忆正文是个人说明，嵌入来源
  /// 的共享范围按材料定义，没有覆盖记忆，联网发送需要单独的决定；而且一次回答
  /// 最多带入四十条记忆，正文本来就会整段进提示词，向量排序的收益有限。索引
  /// 不可用或同步失败时返回空值，调用方退回本机的二元组排序。
  ///
  /// [memories] 是当前有效且未过期的全部记忆，[candidateIds] 是本次范围内由
  /// 仓库筛出的候选；同步以 [memories] 为准，删除不在其中的来源。
  @override
  Future<List<String>?> rankMemories({
    required String query,
    required List<Memory> memories,
    required List<String> candidateIds,
  }) async {
    final text = query.trim();
    if (_closed || text.isEmpty || candidateIds.isEmpty) return null;
    final generation = _generation;
    final now = clock();
    try {
      final store = await _requireMemoryStore(generation);
      final currentEpoch = await epoch?.call() ?? '0';
      // 读取位置在同步之前读：这一轮同步之后再推进，期间到达的提交留给下一轮。
      final memoryHead = await _readHeadCommit();
      final storedEpoch = await _useCurrentStore(
        generation,
        () => store.meta('epoch'),
      );
      if (storedEpoch != currentEpoch) {
        // 与检索索引同一处理：先归零再清空，下一次按当前记忆表整份同步。
        await _resetIndexPosition(IndexCursorNames.memory);
        await _useCurrentStore(generation, () async {
          await store.clear();
          await store.setMeta('epoch', currentEpoch);
        });
      }
      final keys = <String>[];
      final byId = <String, Memory>{};
      for (final memory in memories) {
        keys.add(memorySourceKey(memory.id));
        byId[memory.id] = memory;
      }
      final indexed = keys.isEmpty
          ? const <String, IndexedSource>{}
          : await _useCurrentStore(
              generation,
              () => store.indexedSources(keys),
            );
      var written = 0;
      for (final memory in memories) {
        _requireCurrent(generation);
        final chunks = semanticChunks(memory.content);
        if (chunks.isEmpty) continue;
        final key = memorySourceKey(memory.id);
        final version = memorySourceVersion(memory);
        final existing = indexed[key];
        if (existing != null &&
            existing.sourceVersion == version &&
            existing.chunks == chunks.length) {
          continue;
        }
        final texts = [for (final chunk in chunks) chunk.text];
        await _useCurrentStore(
          generation,
          () => store.replaceSource(
            locator: memoryLocator(memory.id),
            sourceVersion: version,
            chunks: texts,
            createdAt: formatDateTime(now),
          ),
        );
        written += texts.length;
      }
      await _useCurrentStore(generation, () async {
        final removed = await store.pruneSources(keys.toSet());
        if (written > 0 || removed > 0) {
          await store.finishRefresh(
            builtAt: formatDateTime(now),
            sourceCount: keys.length,
            writtenEntries: written,
          );
        }
      });
      // 记忆索引的读取位置只登记进度，不阻止裁剪；召回本身每次按记忆表的版本
      // 判断要不要重写，所以位置落后不会漏掉内容（方案 3.12）。
      await _advanceIndexPosition(IndexCursorNames.memory, memoryHead);
      final candidates = {for (final id in candidateIds) memorySourceKey(id)};
      final hits = await _useCurrentStore(
        generation,
        () => store.searchText(
          text,
          k: candidateIds.length,
          prefilter: SourceKeysVectorPrefilter(candidates),
        ),
      );
      _requireCurrent(generation);
      final order = <String>[];
      final seen = <String>{};
      for (final hit in hits) {
        final id = memoryIdOf(hit.sourceKey);
        if (id == null || !seen.add(id)) continue;
        final memory = byId[id];
        // 只认可与当前正文一致的结果：同步期间被编辑或删除的条目不参与排序。
        if (memory == null ||
            memorySourceVersion(memory) != hit.sourceVersion) {
          continue;
        }
        order.add(id);
      }
      return order;
    } on Object {
      return null;
    }
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
      if (generation == _generation) {
        _refreshing = null;
        if (_catchUpPending) {
          _catchUpPending = false;
          // 单飞已经结束，排一次新的刷新补齐期间到达的提交；用微任务而不是
          // 真实计时，测试与界面都不必额外等待。失败只留待下一次写入触发。
          scheduleMicrotask(() {
            if (_closed || generation != _generation) return;
            unawaited(
              refresh().then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              ),
            );
          });
        }
      }
    }
  }

  Future<IndexRefreshResult> _runRefresh(
    int generation, {
    int? maxSources,
    bool force = false,
  }) async {
    final embedding = client;
    final now = clock();
    _catchUpPending = false;
    try {
      // 先读数据代次再打开索引：打开、初始化 zvec 引擎与建表都由后台 isolate
      // 承接，界面线程在这里只等一个 Future，启动首帧不再执行这些同步调用。
      final currentEpoch = await epoch?.call() ?? '0';
      final textStore = await _requireTextStore(generation);
      final textEpoch = await textStore.meta('epoch');
      final textFinished = await textStore.meta('built_at');
      if (textEpoch != currentEpoch) {
        // 先把读取位置归零再清空：清空成功而位置没归零时，下一次增量刷新会
        // 跳过已经不在索引里的提交（方案 3.12）。
        await _resetIndexPosition(IndexCursorNames.search);
        await _useCurrentStore(generation, () async {
          await textStore.clear();
          await textStore.setMeta('epoch', currentEpoch);
        });
      } else if (textFinished == null) {
        // 结构损坏被重建之后状态文件里还没有一次刷新记录，内容是空的而读取
        // 位置可能停在旧提交；按全量重建，不能从 `HEAD` 附近接着读。
        await _resetIndexPosition(IndexCursorNames.search);
      }

      // 增量刷新要先知道两份集合各自读到了哪里，向量集合因此提前打开；打开
      // 失败时先把错误记下，正文照旧写完再报出来。没有提供增量回调时保持原来
      // 的顺序：先写正文，再打开向量集合。
      final wantsIncrement =
          !force &&
          maxSources == null &&
          headCommit != null &&
          semanticChanges != null;
      VectorStore? vectorStore;
      Object? vectorOpenFailure;
      if (embedding != null && wantsIncrement) {
        try {
          vectorStore = await _requireVectorStore(generation);
          await _prepareVectorStore(generation, vectorStore, currentEpoch);
        } on Object catch (error) {
          if (_closed || generation != _generation) rethrow;
          vectorOpenFailure = error;
        }
      }
      final head = await _readHeadCommit();
      // 正文与向量两份 collection 共用一个读取位置：两份都写成功才前进，所以
      // 这个位置就是两份都处理到的地方。向量集合被清空重建时它已经归零，这里
      // 读到零就按全量扫描重建。
      final from = await _indexPosition(IndexCursorNames.search);

      // 只有两份集合都处理过提交、并且提交日志还读得出来时才做增量。`HEAD`
      // 与起点相等时仍然走增量：窗口里没有变化，刷新因此什么都不写，也不重新
      // 读全部来源。
      var incremental = false;
      var window = const SemanticChangeWindow();
      if (wantsIncrement && head != null && from > 0 && head >= from) {
        try {
          window = await semanticChanges!(from);
        } on Object {
          // 读不到变更就按全量处理：不能把漏掉的改动当成没有变化。
          window = SemanticChangeWindow.unavailable;
        }
        incremental = window.usable;
      }

      final sources = <SemanticSource>[];
      final deletions = <SemanticLocator>[];
      final changedKeys = <String>[];
      if (incremental) {
        final resolved = await _resolveChanges(generation, window.changes);
        sources.addAll(resolved.sources);
        deletions.addAll(resolved.deletions);
        changedKeys.addAll(resolved.keys);
      } else {
        sources.addAll(await repository.semanticSources());
        _requireCurrent(generation);
      }

      // 正文不离开本机，文本集合收下全部来源；分享范围只影响向量集合，不再
      // 允许发送的来源在向量集合里删除，正文仍然保留。增量刷新时这里只有
      // 本次变化涉及到的来源，不能拿来清理整份集合。
      final textKeep = {for (final source in sources) source.locator.sourceKey};
      final sendAllowed = embedding == null ? null : canSend;
      final vectorKeep = {
        for (final source in sources)
          if (sendAllowed?.call(source) ?? true) source.locator.sourceKey,
      };
      final textIndexed = await textStore.indexedSources(
        incremental ? changedKeys : textKeep.toList(growable: false),
      );
      final textCommitted = incremental ? null : textIndexed.keys.toSet();
      var textSourceCount = incremental ? await textStore.sourceCount() : 0;
      final targets = incremental || maxSources == null
          ? sources
          : sources.take(maxSources).toList(growable: false);
      var textWritten = 0;
      var textEntries = 0;
      var lateSkipped = 0;
      var textFailures = 0;
      var cached = 0;
      var embedMs = 0;
      var writeMs = 0;
      EmbeddingSourceUnavailable? sourceDown;

      // 增量刷新不能调用 pruneSources：没有变化的来源不在本次窗口里，按窗口里
      // 的来源清理会把它们一起删掉。删除的来源用空的片段显式删除，片段数为零
      // 在实现里就是删除这一条来源。
      if (incremental) {
        for (final locator in deletions) {
          _requireCurrent(generation);
          await _useCurrentStore(
            generation,
            () => textStore.replaceSource(
              locator: locator,
              sourceVersion: '',
              createdAt: formatDateTime(now),
            ),
          );
          final previous = textIndexed[locator.sourceKey];
          if (previous != null && previous.chunks > 0) textSourceCount--;
        }
      }

      // 先把本次要写的来源挑出来；文本集合的版本或片段数不一致，或者配置了
      // 嵌入时向量集合的版本或片段数不一致，都算需要处理。换模型之后正文没变
      // 也属于后者：只重建向量，不重新写正文。
      final pending = <_PendingSource>[];
      for (final source in targets) {
        _requireCurrent(generation);
        final chunks = semanticChunks(source.content);
        final existing = textIndexed[source.locator.sourceKey];
        final textStale =
            existing == null ||
            existing.sourceVersion != source.sourceVersion ||
            existing.chunks != chunks.length;
        pending.add(
          _PendingSource(source, chunks, needsText: textStale || force),
        );
      }

      Future<bool> sourceCurrent(_PendingSource item) async {
        final fresh = await repository.semanticSource(item.source.locator);
        return fresh != null &&
            fresh.sourceVersion == item.source.sourceVersion;
      }

      // 文本集合不调用嵌入来源，先把正文写进索引：即使随后向量集合打不开或
      // 嵌入失败，关键词检索也已经是最新的。
      for (final item in pending) {
        if (!item.needsText) continue;
        _requireCurrent(generation);
        final writeStarted = DateTime.now();
        if (!await sourceCurrent(item)) {
          // 读取期间来源被更正、删除或撤销：这一条放弃，等下一次更新再处理。
          lateSkipped++;
          item.abandoned = true;
          continue;
        }
        try {
          await _useCurrentStore(
            generation,
            () => textStore.replaceSource(
              locator: item.source.locator,
              sourceVersion: item.source.sourceVersion,
              chunks: [for (final chunk in item.chunks) chunk.text],
              createdAt: formatDateTime(now),
            ),
          );
          textWritten++;
          item.textWritten = true;
          textEntries += item.chunks.length;
          final key = item.source.locator.sourceKey;
          if (incremental) {
            // 增量刷新没有读到全部来源，来源总数只能用上一次的值加上新增、
            // 减去删除；写入之前先看这一条此前在不在索引里。
            final previous = textIndexed[key];
            final was = previous != null && previous.chunks > 0;
            final present = item.chunks.isNotEmpty;
            if (present && !was) textSourceCount++;
            if (!present && was) textSourceCount--;
          } else if (item.chunks.isEmpty) {
            textCommitted!.remove(key);
          } else {
            textCommitted!.add(key);
          }
        } catch (_) {
          if (_closed || generation != _generation) rethrow;
          item.failed = true;
          textFailures++;
        } finally {
          writeMs += DateTime.now().difference(writeStarted).inMilliseconds;
        }
      }

      // 全量扫描按全部来源清理；增量只写本次变化涉及到的来源，没有变化的来源
      // 原样保留。读取位置在向量这一份也处理完之后再推进，两份共用一个位置。
      final textSourceCountForFinish = incremental
          ? math.max(0, textSourceCount)
          : textCommitted!.length;
      await _useCurrentStore(generation, () async {
        if (!incremental) await textStore.pruneSources(textKeep);
        await textStore.finishRefresh(
          builtAt: formatDateTime(now),
          sourceCount: textSourceCountForFinish,
          writtenEntries: textEntries,
        );
      });
      _requireCurrent(generation);

      // 没有配置嵌入来源时，写入正文的来源数就是这一次处理的来源数。
      var embedded = textWritten;
      var removed = 0;
      var vectorAdvance = false;
      if (embedding != null) {
        final VectorStore store;
        if (vectorStore == null) {
          final failure = vectorOpenFailure;
          if (failure != null) throw failure;
          store = await _requireVectorStore(generation);
        } else {
          store = vectorStore;
        }
        // 提前打开时已经按代次与可发送范围处理过一次；这里再核对一次，全量
        // 路径第一次打开也走同一段。
        await _prepareVectorStore(generation, store, currentEpoch);
        final vectorIndexed = await store.indexedSources(
          incremental ? changedKeys : textKeep.toList(growable: false),
        );
        final vectorCommitted = incremental
            ? null
            : {
                for (final key in vectorIndexed.keys)
                  if (vectorKeep.contains(key)) key,
              };
        var vectorSourceCount = incremental ? await store.sourceCount() : 0;
        var vectorWritten = 0;
        var vectorEntries = 0;

        // 增量刷新按提交日志里的删除显式删除向量；没有变化的来源不清理。
        if (incremental) {
          for (final locator in deletions) {
            _requireCurrent(generation);
            await _useCurrentStore(
              generation,
              () => store.replaceSource(
                locator: locator,
                sourceVersion: '',
                createdAt: formatDateTime(now),
              ),
            );
            final previous = vectorIndexed[locator.sourceKey];
            if (previous != null && previous.chunks > 0) {
              vectorSourceCount--;
              removed += previous.chunks;
            }
          }
        }

        // 向量集合按自己的版本与片段数判断：正文没有变化而模型换了，也要重建。
        final vectorPending = <_PendingSource>[];
        for (final item in pending) {
          if (item.abandoned || item.failed) continue;
          final key = item.source.locator.sourceKey;
          final existing = vectorIndexed[key];
          final stale =
              existing == null ||
              existing.sourceVersion != item.source.sourceVersion ||
              existing.chunks != item.chunks.length;
          if (incremental) {
            if (!(sendAllowed?.call(item.source) ?? true)) {
              // 可发送范围不再包含这一条：正文保留，旧向量显式删除。
              if (existing != null && existing.chunks > 0) {
                await _useCurrentStore(
                  generation,
                  () => store.replaceSource(
                    locator: item.source.locator,
                    sourceVersion: item.source.sourceVersion,
                    createdAt: formatDateTime(now),
                  ),
                );
                vectorSourceCount--;
                removed += existing.chunks;
              }
              continue;
            }
            if (!stale) continue;
          } else {
            if (!vectorKeep.contains(key)) continue;
            if (!stale && !force) continue;
          }
          vectorPending.add(item);
        }

        Future<void> writeVector(
          _PendingSource item,
          List<List<double>> vectors,
        ) async {
          _requireCurrent(generation);
          final writeStarted = DateTime.now();
          try {
            await _useCurrentStore(
              generation,
              () => store.replaceSource(
                locator: item.source.locator,
                sourceVersion: item.source.sourceVersion,
                hashes: [
                  for (final chunk in item.chunks)
                    embeddingTextHash(chunk.text),
                ],
                vectors: vectors,
                createdAt: formatDateTime(now),
              ),
            );
            vectorWritten++;
            item.vectorWritten = true;
            vectorEntries += item.chunks.length;
            final key = item.source.locator.sourceKey;
            if (incremental) {
              final previous = vectorIndexed[key];
              final was = previous != null && previous.chunks > 0;
              final present = item.chunks.isNotEmpty;
              if (present && !was) vectorSourceCount++;
              if (!present && was) vectorSourceCount--;
            } else if (item.chunks.isEmpty) {
              vectorCommitted!.remove(key);
            } else {
              vectorCommitted!.add(key);
            }
          } catch (_) {
            if (_closed || generation != _generation) rethrow;
            item.failed = true;
          } finally {
            writeMs += DateTime.now().difference(writeStarted).inMilliseconds;
          }
        }

        final embedder = embedding;
        final writeCache = await _shouldWriteCache();
        // 按块数与字符数切批，跨来源合并请求；一个窗口内的来源全部写完再进入
        // 下一个窗口，向量只在窗口内保留，内存不随来源总数增长。
        var start = 0;
        while (start < vectorPending.length && sourceDown == null) {
          _requireCurrent(generation);
          var end = start;
          var windowChunks = 0;
          while (end < vectorPending.length) {
            final size = vectorPending[end].chunks.length;
            if (end > start && windowChunks + size > _refreshWindowChunks) {
              break;
            }
            windowChunks += size;
            end++;
          }
          final window = vectorPending.sublist(start, end);
          // 同一段正文只算一次：按文本哈希归并，先查缓存，再嵌入未命中的片段。
          final byHash = <String, List<_ChunkJob>>{};
          for (var index = 0; index < window.length; index++) {
            for (var chunk = 0; chunk < window[index].chunks.length; chunk++) {
              final text = window[index].chunks[chunk].text;
              (byHash[embeddingTextHash(text)] ??= <_ChunkJob>[]).add(
                _ChunkJob(index, chunk, text),
              );
            }
          }
          final hashes = byHash.keys.toList(growable: false);
          final vectors = <String, List<double>>{};
          final embedStarted = Stopwatch()..start();
          if (hashes.isNotEmpty) {
            try {
              vectors.addAll(await embedder.lookupVectors(hashes));
            } on EmbeddingSourceUnavailable catch (error) {
              if (_closed || generation != _generation) rethrow;
              // 来源整个用不了：与嵌入请求的处理一致，停下本次剩余的请求。
              sourceDown ??= error;
            } on Object {
              if (_closed || generation != _generation) rethrow;
              // 查找失败按全部未命中处理，照常嵌入，索引更新不中断。
            }
          }
          for (final entry in byHash.entries) {
            if (vectors.containsKey(entry.key)) cached += entry.value.length;
          }
          final missing = [
            for (final hash in hashes)
              if (!vectors.containsKey(hash))
                (hash: hash, text: byHash[hash]!.first.text),
          ];
          final batches = _embedBatches(missing, (job) => job.text);
          var nextBatch = 0;
          Future<void> worker() async {
            while (sourceDown == null) {
              final index = nextBatch++;
              if (index >= batches.length) return;
              _requireCurrent(generation);
              final batch = batches[index];
              final texts = [for (final job in batch) job.text];
              var got = const <List<double>>[];
              var ok = false;
              for (var attempt = 0; attempt < _embedBatchAttempts; attempt++) {
                try {
                  got = await embedder.embedBatch(
                    texts,
                    writeCache: writeCache,
                  );
                  ok = got.length == texts.length;
                } on EmbeddingSourceUnavailable catch (error) {
                  if (_closed || generation != _generation) rethrow;
                  // 来源整个用不了：重发与逐条定位都没有意义，停下所有并发。
                  sourceDown ??= error;
                  return;
                } catch (_) {
                  if (_closed || generation != _generation) rethrow;
                  ok = false;
                }
                if (ok) break;
              }
              if (ok) {
                for (var index = 0; index < batch.length; index++) {
                  vectors[batch[index].hash] = got[index];
                }
                continue;
              }
              // 整批失败时逐条重发，定位真正失败的那一条，避免一条坏文本
              // 让同批的其他片段一起记为失败。
              for (final job in batch) {
                _requireCurrent(generation);
                try {
                  vectors[job.hash] = await embedder.embed(
                    job.text,
                    writeCache: writeCache,
                  );
                } on EmbeddingSourceUnavailable catch (error) {
                  if (_closed || generation != _generation) rethrow;
                  sourceDown ??= error;
                  return;
                } catch (_) {
                  if (_closed || generation != _generation) rethrow;
                  // 这一段没有算出来，它所属的来源按失败处理。
                }
              }
            }
          }

          await Future.wait([
            for (
              var index = 0;
              index < math.min(_embedConcurrency, batches.length);
              index++
            )
              worker(),
          ]);
          embedMs += embedStarted.elapsedMilliseconds;

          // 回填向量：相同正文的片段共用一次计算的结果；没有算出来的来源记为
          // 失败，下一次更新再补。
          for (final entry in byHash.entries) {
            final vector = vectors[entry.key];
            if (vector == null) {
              for (final job in entry.value) {
                window[job.source].failed = true;
              }
              continue;
            }
            for (final job in entry.value) {
              window[job.source].vectors[job.chunk] = vector;
            }
          }

          for (final item in window) {
            if (item.failed || !item.complete) {
              item.failed = true;
              continue;
            }
            _requireCurrent(generation);
            // 迟到结果写回之前重新检查来源：等待嵌入期间内容被更正、删除或撤销，
            // 就放弃这一条，等下一次更新再处理。
            if (!await sourceCurrent(item)) {
              lateSkipped++;
              item.abandoned = true;
              continue;
            }
            await writeVector(item, [
              for (final vector in item.vectors) vector!,
            ]);
          }
          start = end;
        }
        // 来源停用之后没有请求的那些来源同样记为失败，下一次更新再补。
        for (final item in vectorPending.skip(start)) {
          item.failed = true;
        }
        final vectorFailures = vectorPending
            .where((item) => item.failed)
            .length;

        // 向量集合只有在本次没有失败、没有迟到放弃、来源没有整体不可用时才推进
        // 提交；文本写入失败的来源没有进入向量这一路，同样不能推进。
        final vectorAdvanceNow =
            head != null &&
            textFailures == 0 &&
            vectorFailures == 0 &&
            lateSkipped == 0 &&
            sourceDown == null &&
            maxSources == null;
        final vectorSourceCountForFinish = incremental
            ? math.max(0, vectorSourceCount)
            : vectorCommitted!.length;
        final pruned = await _useCurrentStore(generation, () async {
          if (incremental) return 0;
          return store.pruneSources(vectorKeep);
        });
        await _useCurrentStore(
          generation,
          () => store.finishRefresh(
            builtAt: formatDateTime(now),
            sourceCount: vectorSourceCountForFinish,
            writtenEntries: vectorEntries,
          ),
        );
        _requireCurrent(generation);
        removed += pruned;
        vectorAdvance = vectorAdvanceNow;
        embedded = vectorWritten;
      }

      // 两份 collection 都处理完才推进读取位置：一份失败时位置停在原处，下一次
      // 从提交日志重读这一段，索引写入是幂等的。没有配置嵌入来源时只有正文
      // 这一份，正文写完并且没有失败就推进。
      if (head != null &&
          textFailures == 0 &&
          lateSkipped == 0 &&
          maxSources == null &&
          (embedding == null || vectorAdvance)) {
        await _advanceIndexPosition(IndexCursorNames.search, head);
      }

      // 两份集合都已经处理完，再按来源逐条结算：正文与向量都没有写的算跳过，
      // 文本写失败或嵌入失败的算失败。增量刷新里删除的来源已经单独处理，不计
      // 入跳过。
      var skipped = 0;
      var failed = 0;
      for (final item in pending) {
        if (item.failed) {
          failed++;
          continue;
        }
        if (item.abandoned) continue;
        if (!item.textWritten && !item.vectorWritten) skipped++;
      }

      // 刷新成功之后再看一次 HEAD：本次窗口之后又有提交进来时，等单飞结束再排
      // 一次刷新，期间到达的提交不丢（ADR-0030 决定第 5 条、客户端清单第 5 条）。
      if (head != null &&
          headCommit != null &&
          maxSources == null &&
          failed == 0 &&
          lateSkipped == 0 &&
          (embedding == null || vectorAdvance)) {
        final nextHead = await _readHeadCommit();
        _catchUpPending = nextHead != null && nextHead > head;
      }

      final result = IndexRefreshResult(
        embedded: embedded,
        textWritten: textWritten,
        skipped: skipped,
        lateSkipped: lateSkipped,
        failed: failed,
        removed: removed,
        total: targets.length + deletions.length,
        cached: cached,
        failure: failed == 0 ? IndexFailure.none : IndexFailure.error,
        embedMs: embedMs,
        writeMs: writeMs,
        sourceProblem: sourceDown?.message,
      );
      _lastRefresh = result;
      return result;
    } on Object {
      // 退出、切换配置和清空都会让原来的刷新结束。
      if (_closed || generation != _generation) {
        return const IndexRefreshResult(failure: IndexFailure.cancelled);
      }
      rethrow;
    }
  }

  /// 把提交日志里的行变化解析成来源：当前仍是来源的读回正文，已经不是来源的
  /// 按删除处理，同一来源键只保留一条。
  ///
  /// 删除行带着完整旧行，材料页要按旧行里的材料编号与页码还原来源键；其他行
  /// 只要主键。改动之后不再是来源的行（消息正文清空、作答撤回提交等）读当前
  /// 记录会得到空来源，与删除行同样显式删除索引里的旧条目。
  Future<
    ({
      List<SemanticSource> sources,
      List<SemanticLocator> deletions,
      List<String> keys,
    })
  >
  _resolveChanges(int generation, List<SemanticRowChange> changes) async {
    final additions = <String, SemanticSource>{};
    final deletions = <String, SemanticLocator>{};
    for (final change in changes) {
      _requireCurrent(generation);
      if (change.removed) {
        final locator = _locatorOfRemovedRow(change);
        if (locator == null) continue;
        // 删除优先：同一来源键在窗口里既有改动又有删除时，以删除为准。
        additions.remove(locator.sourceKey);
        deletions[locator.sourceKey] = locator;
        continue;
      }
      final source = await repository.semanticSourceOfRow(
        change.table,
        change.rowKey,
      );
      if (source == null) {
        // 行已经不存在，或者改动之后不再是来源：按删除处理。
        final locator = _locatorOfRemovedRow(change);
        if (locator == null) continue;
        additions.remove(locator.sourceKey);
        deletions[locator.sourceKey] = locator;
        continue;
      }
      if (deletions.containsKey(source.locator.sourceKey)) continue;
      additions[source.locator.sourceKey] = source;
    }
    return (
      sources: additions.values.toList(growable: false),
      deletions: deletions.values.toList(growable: false),
      keys: [...additions.keys, ...deletions.keys],
    );
  }

  /// 删除行的来源定位：有旧行时按旧行解析，没有时只按主键还原。
  SemanticLocator? _locatorOfRemovedRow(SemanticRowChange change) =>
      repository.semanticLocatorOfRemovedRow(
        change.table,
        change.removedRow ?? {'id': change.rowKey},
      );

  /// 索引读者已经处理到的提交编号；没有提供读取位置或读不出来时为零，下一次
  /// 刷新因此按全量扫描开始。
  Future<int> _indexPosition(String name) async {
    final cursors = indexCursors;
    if (cursors == null) return 0;
    try {
      return await cursors().indexPosition(name);
    } on Object {
      // 库还没打开或读取失败：不知道进度就按全量扫描，不能当成已经处理过。
      return 0;
    }
  }

  /// 清空索引时把读取位置归零，下一次按全量扫描重建。
  ///
  /// 这里让写入失败向上抛：如果索引已经清空而位置还停在旧提交，下一次增量
  /// 刷新会以为这些提交处理过了，漏掉的内容只能等再下一次全量重建才能补上。
  Future<void> _resetIndexPosition(String name) async {
    final cursors = indexCursors;
    if (cursors == null) return;
    await cursors().advanceIndex(name, 0);
  }

  /// 推进索引读者的读取位置。
  ///
  /// 位置只决定下一次从哪里接着读，写不进去最多多扫一次，所以失败只留待下次
  /// 刷新补上，不能把已经写进索引的内容报成失败。位置没变时不重写，记忆索引
  /// 每次召回都会走到这里。
  Future<void> _advanceIndexPosition(String name, int? position) async {
    if (position == null || position <= 0) return;
    final cursors = indexCursors;
    if (cursors == null) return;
    try {
      final reader = cursors();
      if (await reader.indexPosition(name) == position) return;
      await reader.advanceIndex(name, position);
    } on Object {
      // 下一次刷新按旧位置重读这一段，索引写入是幂等的。
    }
  }

  /// 读当前 `HEAD`；没有提供回调或读取失败时返回空，本次退回全量扫描。
  Future<int?> _readHeadCommit() async {
    final read = headCommit;
    if (read == null) return null;
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  /// 读当前可发送范围签名；没有提供回调或读取失败时返回空，不做这项判断。
  String? _readShareSignature() {
    final read = shareSignature;
    if (read == null) return null;
    try {
      return read();
    } on Object {
      return null;
    }
  }

  /// 按代次与可发送范围核对向量集合，返回这一次是否清空过。
  ///
  /// 代次变化、可发送范围变化都要求旧向量整份消失：代次变化是数据被整份替换，
  /// 范围变化是因为缩小的范围内不能再留下旧向量。清空之前先把读取位置归零，
  /// 下一次刷新按全量扫描重建。可发送范围签名与状态文件里记的不一致时才重建，
  /// 范围没变时不重复清空。结构损坏被重建之后状态文件里没有刷新记录（`built_at`
  /// 为空），同样把读取位置归零，否则空集合会从旧位置之后接着读而一直空着。
  Future<bool> _prepareVectorStore(
    int generation,
    VectorStore store,
    String currentEpoch,
  ) async {
    final epochMatches =
        await _useCurrentStore(generation, () => store.meta('epoch')) ==
        currentEpoch;
    final finished = await _useCurrentStore(
      generation,
      () => store.meta('built_at'),
    );
    final signature = _readShareSignature();
    final storedSignature = signature == null
        ? null
        : await _useCurrentStore(
            generation,
            () => store.meta('share_signature'),
          );
    final signatureChanged = signature != null && storedSignature != signature;
    final needsRebuild = !epochMatches || signatureChanged || finished == null;
    if (needsRebuild) {
      await _resetIndexPosition(IndexCursorNames.search);
      if (!epochMatches || signatureChanged) {
        await _useCurrentStore(generation, () async {
          await store.clear();
          if (!epochMatches) await store.setMeta('epoch', currentEpoch);
          if (signature != null) {
            await store.setMeta('share_signature', signature);
          }
        });
      }
      return true;
    }
    if (signature != null && storedSignature == null) {
      // 旧状态文件还没有这个字段：按当前范围补记，不重建。
      await _useCurrentStore(
        generation,
        () => store.setMeta('share_signature', signature),
      );
    }
    return false;
  }

  /// 这一次刷新该不该把嵌入写进服务端缓存。
  ///
  /// 读不到同步状态时按不写处理：写入属于派生数据，宁可少写一次，也不在用户
  /// 没有开启同步时留下它。
  Future<bool> _shouldWriteCache() async {
    final probe = cacheWrites;
    if (probe == null) return false;
    try {
      return await probe();
    } on Object {
      return false;
    }
  }

  /// 把待嵌入的文本按条数与字符数切成若干批，供一次请求发送。
  List<List<T>> _embedBatches<T>(List<T> jobs, String Function(T) textOf) {
    final batches = <List<T>>[];
    var current = <T>[];
    var chars = 0;
    for (final job in jobs) {
      final length = textOf(job).length;
      if (current.isNotEmpty &&
          (current.length >= _embedBatchMaxItems ||
              chars + length > _embedBatchMaxChars)) {
        batches.add(current);
        current = <T>[];
        chars = 0;
      }
      current.add(job);
      chars += length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
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
      final candidates = _fuseCandidates([textCandidates, vectorCandidates]);
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
        final hit = _hitFor(locator, candidate, semantic: semanticOnly);
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

  /// 把两路候选按名次倒数相加，返回融合后的候选。
  ///
  /// 同一片段在文本与向量两路都出现时分数相加；名次相同、分数也相同时按
  /// 来源键与片段号排序，保证结果稳定。常数与文本集合内部全文子查询的平滑
  /// 常数一致，拆分前后的差异只来自两路各自排序。
  static List<StoredVector> _fuseCandidates(List<List<StoredVector>> routes) {
    final scores = <String, double>{};
    final rows = <String, StoredVector>{};
    for (final route in routes) {
      for (var index = 0; index < route.length; index++) {
        final row = route[index];
        final key = '${row.sourceKey}#${row.chunk}';
        scores[key] =
            (scores[key] ?? 0) + 1 / (vectorFusionRankConstant + index + 1);
        rows.putIfAbsent(key, () => row);
      }
    }
    final keys = rows.keys.toList(growable: false);
    keys.sort((left, right) {
      final byScore = scores[right]!.compareTo(scores[left]!);
      if (byScore != 0) return byScore;
      return left.compareTo(right);
    });
    return [for (final key in keys) _withScore(rows[key]!, scores[key]!)];
  }

  static StoredVector _withScore(StoredVector row, double score) =>
      StoredVector(
        sourceKey: row.sourceKey,
        chunk: row.chunk,
        content: row.content,
        sourceVersion: row.sourceVersion,
        locatorJson: row.locatorJson,
        distance: row.distance,
        score: score,
      );

  EvidenceHit _hitFor(
    SemanticLocator locator,
    StoredVector candidate, {
    required bool semantic,
  }) {
    final kind = switch (locator.kind) {
      'material_page' => EvidenceKind.materialPage,
      'answer' => EvidenceKind.answer,
      'attempt' => EvidenceKind.answer,
      'message' => EvidenceKind.message,
      _ => EvidenceKind.message,
    };
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
      // 片段正文只用来占位，核对之后按当前记录重算摘要。
      snippet: candidate.content,
      text: candidate.content,
      matchedText: candidate.content,
      literal: false,
      semantic: semantic,
      score: Score.clamp(candidate.score),
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

/// 一次刷新里等待写入的一条来源；向量按片段序号回填。
class _PendingSource {
  _PendingSource(this.source, this.chunks, {required this.needsText})
    : vectors = List<List<double>?>.filled(chunks.length, null);

  final SemanticSource source;
  final List<({int index, String text})> chunks;
  final List<List<double>?> vectors;

  /// 文本集合里的版本或片段数与当前来源不一致，需要重写正文。
  final bool needsText;

  bool textWritten = false;
  bool vectorWritten = false;

  /// 来源在等待期间被更正、删除或撤销，这一条本次放弃。
  bool abandoned = false;
  bool failed = false;

  bool get complete => vectors.every((vector) => vector != null);
}

/// 一条待嵌入的片段；[source] 与 [chunk] 都是窗口内的下标。
class _ChunkJob {
  const _ChunkJob(this.source, this.chunk, this.text);

  final int source;
  final int chunk;
  final String text;
}

/// 索引结构损坏被重建时交给本机诊断记录的说明；原文与调用栈不进入界面。
class _IndexRebuilt implements Exception {
  const _IndexRebuilt(this.reason);

  final String reason;

  @override
  String toString() => '检索索引结构损坏，已重建空索引：$reason';
}
