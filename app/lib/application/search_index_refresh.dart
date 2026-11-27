part of 'search_index_service.dart';

/// 刷新流水线与嵌入调度：按来源版本补建文本与向量两份索引。
///
/// 这里是检索索引服务的 part：刷新、增量窗口、嵌入批次、读取位置与向量集合
/// 准备共用同一个实例的私有状态（代次、句柄、队列与读取位置）。拆成独立类要
/// 先把这些状态抽成一个对象，行为才保持逐字一致；本轮先把这段代码从主文件分
/// 出来，接口、调用点与检索结果都不变。
extension _SearchIndexRefresh on SearchIndexService {
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
            if (end > start &&
                windowChunks + size > SearchIndexService._refreshWindowChunks) {
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
              for (
                var attempt = 0;
                attempt < SearchIndexService._embedBatchAttempts;
                attempt++
              ) {
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
              index <
                  math.min(
                    SearchIndexService._embedConcurrency,
                    batches.length,
                  );
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
          (current.length >= SearchIndexService._embedBatchMaxItems ||
              chars + length > SearchIndexService._embedBatchMaxChars)) {
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
