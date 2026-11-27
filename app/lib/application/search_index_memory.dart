part of 'search_index_service.dart';

/// 记忆索引：把当前记忆表同步进一份只做全文索引的 collection，再按查询排序。
///
/// 这里是检索索引服务的 part：记忆索引与检索索引共用同一个实例的代次、句柄
/// 队列与读取位置登记（[IndexCursorNames.memory]），拆成独立类要先把这些状态
/// 抽成一个对象；本轮先把这段代码从主文件分出来，`MemoryRelevanceRanker` 的
/// 接口与排序结果都不变。
extension _SearchIndexMemory on SearchIndexService {
  /// 取记忆索引句柄；第一次排序时才在后台 isolate 里打开并建表。
  Future<VectorStore> requireMemoryStore(int generation) async {
    _requireCurrent(generation);
    final opening = _memoryOpening;
    if (opening != null) {
      final store = await opening;
      _requireCurrent(generation);
      return store;
    }
    final future = _queueStoreOperation(() => openMemory(generation));
    _memoryOpening = future;
    try {
      final store = await future;
      _requireCurrent(generation);
      return store;
    } finally {
      if (identical(_memoryOpening, future)) _memoryOpening = null;
    }
  }

  Future<VectorStore> openMemory(int generation) async {
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
  Future<List<String>?> memoryRelevanceOrder({
    required String query,
    required List<Memory> memories,
    required List<String> candidateIds,
  }) async {
    final text = query.trim();
    if (_closed || text.isEmpty || candidateIds.isEmpty) return null;
    final generation = _generation;
    final now = clock();
    try {
      final store = await requireMemoryStore(generation);
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
        final chunks = memoryTexts(memory);
        if (chunks.isEmpty) continue;
        final key = memorySourceKey(memory.id);
        final version = memorySourceVersion(memory);
        final existing = indexed[key];
        if (existing != null &&
            existing.sourceVersion == version &&
            existing.chunks == chunks.length) {
          continue;
        }
        await _useCurrentStore(
          generation,
          () => store.replaceSource(
            locator: memoryLocator(memory.id),
            sourceVersion: version,
            chunks: chunks,
            createdAt: formatDateTime(now),
          ),
        );
        written += chunks.length;
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

  /// 一条记忆写进全文索引的切片：正文切成带重叠的块，检索线索单独一块。
  ///
  /// 线索是写入时顺带给出的“用户可能怎样问到它”的短语，补的是正文用词不
  /// 重合的缺口，只进索引、不在界面显示（ADR-0051 决定第 7 条）。
  List<String> memoryTexts(Memory memory) {
    final chunks = [
      for (final chunk in semanticChunks(memory.content)) chunk.text,
    ];
    final terms = memory.searchTerms.trim();
    if (terms.isNotEmpty) chunks.add(terms);
    return chunks;
  }
}
