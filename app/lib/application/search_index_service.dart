import 'dart:async';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/db/drift/queries/evidence_scope.dart';
import '../data/repository/evidence_repository.dart';
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

  /// 索引里现有的向量条数；界面据此区分“没有找到”和“索引还没有内容”。
  /// 没有配置、超时或取消时不知道索引规模，保持为零。
  final int entries;

  bool get usable => failure == IndexFailure.none;
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
    this.failure = IndexFailure.none,
    this.embedMs = 0,
    this.writeMs = 0,
    this.sourceProblem,
  });

  final int embedded;
  final int skipped;

  /// 等待嵌入期间来源被更正、删除或撤销，写回前放弃的条数。
  final int lateSkipped;
  final int failed;

  /// 清理时删除的向量条数。
  final int removed;
  final int total;
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
/// 索引同时服务关键词与语义：没有配置嵌入模型时只建全文索引，关键词检索照常
/// 可用；配置之后加上向量字段，两路在引擎内一次融合。索引按模型、维度与文本
/// 处理版本区分；数据代次变化（恢复、导入、清空）时整份索引重建。写入前重新
/// 读取来源版本，等待嵌入期间被更正或删除的内容不会进入索引。查询有独立的
/// 超时与取消，失败时返回空结果，调用方继续使用字面命中。
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
    Future<VectorStore> Function()? memoryStoreOpener,
    this.recordFailure,
  }) : _client = initialClient,
       _canSend = initialShareFilter,
       _openStore = vectorStoreOpener,
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

  /// 当前嵌入来源；为空表示没有配置，关键词仍按全文索引检索。
  EmbeddingClient? get client => _client;

  /// 是否允许把这条来源的原文发送给远程嵌入服务；本地来源不需要判断。
  bool Function(SemanticSource source)? get canSend => _canSend;

  /// 当前数据代次：`HEAD` 所在提交的 `generation`，整版恢复、导入与清理历史
  /// 时变化；变化时索引按当前数据重建，普通写入不会改变它。
  final Future<String> Function()? epoch;
  final Clock clock;
  final Duration queryTimeout;
  final Future<VectorStore> Function()? _openStore;

  /// 记忆索引目录；为空时放在语义索引目录的同级，随本机数据一起删除。
  final String? memoryIndexPath;
  final Future<VectorStore> Function()? _openMemoryStore;

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

  /// 配了嵌入模型时用它的 spec，没配时用纯文本索引的 spec。
  EmbeddingModelSpec get _indexSpec => client?.spec ?? textOnlyModelSpec;

  /// 取当前索引句柄；第一次用时才打开，打开与建表都在后台 isolate 里完成。
  Future<VectorStore> _requireStore(int generation) async {
    _requireCurrent(generation);
    final spec = _indexSpec;
    final opening = _opening;
    if (opening != null) {
      final store = await opening;
      _requireCurrent(generation);
      return store;
    }
    final future = _queueStoreOperation(() => _open(spec, generation));
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
      final storedEpoch = await _useCurrentStore(
        generation,
        () => store.meta('epoch'),
      );
      if (storedEpoch != currentEpoch) {
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
            vectors: const [],
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
      final candidates = {for (final id in candidateIds) memorySourceKey(id)};
      final hits = await _useCurrentStore(
        generation,
        () => store.searchHybrid(
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
      if (generation == _generation) _refreshing = null;
    }
  }

  Future<IndexRefreshResult> _runRefresh(
    int generation, {
    int? maxSources,
    bool force = false,
  }) async {
    final embedding = client;
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
      // 没有配置嵌入来源时只建全文索引，正文不出本机，分享范围不参与筛选。
      final sendAllowed = embedding == null ? null : canSend;
      final keep = {
        for (final source in sources)
          if (sendAllowed?.call(source) ?? true) source.locator.sourceKey,
      };
      final indexed = await store.indexedSources(keep.toList(growable: false));
      final committed = indexed.keys.toSet();
      final targets = maxSources == null
          ? sources
          : sources.take(maxSources).toList(growable: false);
      var embedded = 0;
      var writtenEntries = 0;
      var skipped = 0;
      var lateSkipped = 0;
      var failed = 0;
      var embedMs = 0;
      var writeMs = 0;
      EmbeddingSourceUnavailable? sourceDown;

      // 先把本次要重写的来源挑出来；等待嵌入期间来源被更正、删除或撤销时，
      // 写回之前还会再核对一次版本。
      final pending = <_PendingSource>[];
      for (final source in targets) {
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
        pending.add(_PendingSource(source, chunks));
      }

      Future<void> writeSource(
        _PendingSource item,
        List<List<double>> vectors,
      ) async {
        _requireCurrent(generation);
        final sourceKey = item.source.locator.sourceKey;
        final writeStarted = DateTime.now();
        try {
          await _useCurrentStore(
            generation,
            () => store.replaceSource(
              locator: item.source.locator,
              sourceVersion: item.source.sourceVersion,
              chunks: [for (final chunk in item.chunks) chunk.text],
              vectors: vectors,
              createdAt: formatDateTime(now),
            ),
          );
          embedded++;
          writtenEntries += item.chunks.length;
          if (item.chunks.isEmpty) {
            committed.remove(sourceKey);
          } else {
            committed.add(sourceKey);
          }
        } catch (_) {
          if (_closed || generation != _generation) rethrow;
          failed++;
        } finally {
          writeMs += DateTime.now().difference(writeStarted).inMilliseconds;
        }
      }

      Future<bool> sourceCurrent(_PendingSource item) async {
        final fresh = await repository.semanticSource(item.source.locator);
        return fresh != null &&
            fresh.sourceVersion == item.source.sourceVersion;
      }

      if (embedding == null) {
        // 纯文本索引不调用嵌入来源，直接写正文。
        for (final item in pending) {
          _requireCurrent(generation);
          if (!await sourceCurrent(item)) {
            lateSkipped++;
            continue;
          }
          await writeSource(item, const <List<double>>[]);
        }
      } else {
        final embedder = embedding;
        // 按块数与字符数切批，跨来源合并请求；一个窗口内的来源全部写完再进入
        // 下一个窗口，向量只在窗口内保留，内存不随来源总数增长。
        var start = 0;
        while (start < pending.length && sourceDown == null) {
          _requireCurrent(generation);
          var end = start;
          var windowChunks = 0;
          while (end < pending.length) {
            final size = pending[end].chunks.length;
            if (end > start && windowChunks + size > _refreshWindowChunks) {
              break;
            }
            windowChunks += size;
            end++;
          }
          final window = pending.sublist(start, end);
          final jobs = <_ChunkJob>[
            for (var index = 0; index < window.length; index++)
              for (var chunk = 0; chunk < window[index].chunks.length; chunk++)
                _ChunkJob(index, chunk, window[index].chunks[chunk].text),
          ];
          final batches = _embedBatches(jobs);
          final embedStarted = Stopwatch()..start();
          var nextBatch = 0;
          Future<void> worker() async {
            while (sourceDown == null) {
              final index = nextBatch++;
              if (index >= batches.length) return;
              _requireCurrent(generation);
              final batch = batches[index];
              final texts = [for (final job in batch) job.text];
              var vectors = const <List<double>>[];
              var ok = false;
              for (var attempt = 0; attempt < _embedBatchAttempts; attempt++) {
                try {
                  vectors = await embedder.embedBatch(texts);
                  ok = vectors.length == texts.length;
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
                  window[batch[index].source].vectors[batch[index].chunk] =
                      vectors[index];
                }
                continue;
              }
              // 整批失败时逐条重发，定位真正失败的那一条，避免一条坏文本
              // 让同批的其他来源一起记为失败。
              for (final job in batch) {
                _requireCurrent(generation);
                try {
                  final vector = await embedder.embed(job.text);
                  window[job.source].vectors[job.chunk] = vector;
                } on EmbeddingSourceUnavailable catch (error) {
                  if (_closed || generation != _generation) rethrow;
                  sourceDown ??= error;
                  return;
                } catch (_) {
                  if (_closed || generation != _generation) rethrow;
                  window[job.source].failed = true;
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

          for (final item in window) {
            if (item.failed || !item.complete) {
              failed++;
              continue;
            }
            _requireCurrent(generation);
            // 迟到结果写回之前重新检查来源：等待嵌入期间内容被更正、删除或撤销，
            // 就放弃这一条，等下一次更新再处理。
            if (!await sourceCurrent(item)) {
              lateSkipped++;
              continue;
            }
            await writeSource(item, [
              for (final vector in item.vectors) vector!,
            ]);
          }
          start = end;
        }
        // 来源停用之后没有请求的那些来源同样记为失败，下一次更新再补。
        failed += pending.length - start;
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
        total: targets.length,
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

  /// 把一段窗口里的文本按条数与字符数切成若干批，供一次请求发送。
  List<List<_ChunkJob>> _embedBatches(List<_ChunkJob> jobs) {
    final batches = <List<_ChunkJob>>[];
    var current = <_ChunkJob>[];
    var chars = 0;
    for (final job in jobs) {
      if (current.isNotEmpty &&
          (current.length >= _embedBatchMaxItems ||
              chars + job.text.length > _embedBatchMaxChars)) {
        batches.add(current);
        current = <_ChunkJob>[];
        chars = 0;
      }
      current.add(job);
      chars += job.text.length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// 按查询向量取候选，并逐条读取当前记录核对范围与版本。
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
      final store = await _requireStore(generation);
      final entries = await store.entryCount();
      _requireCurrent(generation);
      // 范围能下推时引擎在索引内部先过滤，候选保留四倍；不能下推的目标范围
      // 仍取二十倍并封顶 400，避免收窄范围后漏召回。
      final prefilter = vectorPrefilterFor(scope);
      final candidateLimit = prefilter == null
          ? (scope.limitsToAll ? limit * 4 : limit * 20)
          : limit * 4;
      final k = math.min(400, math.max(limit, candidateLimit));
      final candidates = await store.searchHybrid(
        query,
        vector: vector,
        k: k,
        prefilter: prefilter,
      );
      _requireCurrent(generation);
      // 只由语义命中的来源：与关键词一路的来源键比较，用来决定“按意思”标签。
      final keywordKeys = <String>{};
      if (vector != null) {
        final keywordOnly = await store.searchHybrid(
          query,
          k: k,
          prefilter: prefilter,
        );
        for (final match in keywordOnly) {
          keywordKeys.add(match.sourceKey);
        }
        _requireCurrent(generation);
      }
      final indexMs = indexStarted.elapsedMilliseconds;
      final hits = <EvidenceHit>[];
      var verifiedOut = 0;
      for (final candidate in candidates) {
        final locator = SemanticLocator.fromJson(candidate.locatorJson);
        if (locator == null) {
          verifiedOut++;
          continue;
        }
        final semanticOnly =
            vector != null && !keywordKeys.contains(candidate.sourceKey);
        final hit = _hitFor(locator, candidate, query, semantic: semanticOnly);
        final fresh = await repository.current(hit);
        if (fresh == null ||
            fresh.sourceVersion != candidate.sourceVersion ||
            !await repository.inScope(fresh, scope)) {
          verifiedOut++;
          continue;
        }
        hits.add(
          fresh.copyWith(
            literal: false,
            semantic: semanticOnly,
            score: hit.score,
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
      // 索引打不开或读取失败时退回原文与关键词；调用方只看 usable。
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

  EvidenceHit _hitFor(
    SemanticLocator locator,
    StoredVector candidate,
    String query, {
    required bool semantic,
  }) {
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
  /// 读取状态会打开索引库；打不开时异常交给调用方，设置页据此显示失败说明，
  /// 不停在“还没有读取索引状态”。
  Future<IndexStats> stats() async {
    if (client == null) {
      return const IndexStats(
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
      () async => IndexStats(
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

  /// 清空全部记录之前释放索引句柄：关闭 collection 但不关闭服务。
  ///
  /// 索引目录由删除本机数据的流程删除；嵌入来源保持配置，下一次刷新会在同一
  /// 路径重新建立 collection。已经发出的索引请求按取消处理，不会写回旧句柄。
  Future<void> release() async {
    if (_closed) return;
    _invalidateOperations();
    final store = _store;
    final memory = _memoryStore;
    _store = null;
    _memoryStore = null;
    _lastRefresh = null;
    await _queueStoreOperation(() async {
      await store?.close();
      await memory?.close();
    });
  }

  /// 清空两份索引的条目；记忆索引与嵌入配置无关，已经在用时一并清空。
  Future<void> clear() async {
    if (_closed) return;
    _invalidateOperations();
    final generation = _generation;
    final spec = client?.spec;
    await _queueStoreOperation(() async {
      // 没有打开过的记忆索引不在这里新建：它只保存记忆正文，下一次召回会按
      // 记忆表重新同步。
      await _memoryStore?.clear();
      if (spec == null) return;
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
    final memory = _memoryStore;
    _store = null;
    _memoryStore = null;
    final next = _closing = _queueStoreOperation(() async {
      await store?.close();
      await memory?.close();
    });
    _client?.dispose();
    _client = null;
    return next;
  }
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

/// 一次刷新里等待嵌入的一条来源；向量按片段序号回填。
class _PendingSource {
  _PendingSource(this.source, this.chunks)
    : vectors = List<List<double>?>.filled(chunks.length, null);

  final SemanticSource source;
  final List<({int index, String text})> chunks;
  final List<List<double>?> vectors;
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
