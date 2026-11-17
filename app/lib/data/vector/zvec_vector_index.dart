import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:zvec/zvec.dart';

import '../../domain/rules/embedding.dart';
import 'vector_index.dart';
import 'vector_store.dart';

/// zvec 语义索引：一个嵌入模型键对应一个 collection 目录与一个状态文件。
///
/// 磁盘布局是 `<rootPath>/<模型键短哈希>/` 与 `<rootPath>/<模型键短哈希>.json`，
/// 模型、维度或文本处理版本改变时换目录。状态文件只在打开、清空与一次刷新结束
/// 时写入，先写临时文件再改名；collection 的写入顺序与失败处理见 ADR-0022。
///
/// zvec 的引擎按进程只初始化一次，这里不调用 `Zvec.shutdown`；同一个 collection
/// 同一时刻只允许一个句柄，打开时遇到占用按退避重试，仍失败就报“索引正被占用”
/// 且不删除目录。索引结构损坏时改名重建，并交给 [onRebuild] 记一条诊断。
class ZvecVectorIndex implements VectorIndex {
  ZvecVectorIndex._(
    this.rootPath,
    this.collectionPath,
    this.statePath,
    this._collection,
    this.spec,
    this._state,
  );

  static const String _embeddingField = 'embedding';
  static const String _contentField = 'content';

  /// 融合检索的名次平滑常数，与应用层融合的取值一致。
  static const int _rrfRankConstant = 60;

  /// 状态文件与 collection 目录共用的短哈希长度。
  static const int _hashLength = 16;

  /// 同一 collection 被占用时的退避间隔；合计约 3.1 秒。
  static const List<int> _lockRetryDelaysMs = [100, 200, 400, 800, 1600];

  /// 一次写入的向量条数超过这个值时，刷新结束执行一次 `optimize` 合并段。
  static const int _optimizeThreshold = 200;

  /// 来源键允许的字符；来源键会直接拼进过滤表达式。
  static final RegExp _safeKey = RegExp(r'^[A-Za-z0-9:_-]+$');

  final String rootPath;
  final String collectionPath;
  final String statePath;

  @override
  final EmbeddingModelSpec spec;

  Collection _collection;
  _IndexState _state;
  bool _closed = false;

  /// 打开索引；目录不存在时新建，打不开时按占用或损坏分别处理。
  ///
  /// [rootPath] 是 `filesDir/vector_index/` 这一层目录，不是 collection 本身。
  /// [logDirectory] 给出时把引擎警告写进这个目录，不传则沿用上一次的日志配置。
  /// [onRebuild] 只在索引结构损坏、改名重建之后调用一次。
  static ZvecVectorIndex open({
    required String rootPath,
    required EmbeddingModelSpec spec,
    String? logDirectory,
    void Function(String reason)? onRebuild,
  }) {
    _ensureEngine(logDirectory);
    try {
      Directory(rootPath).createSync(recursive: true);
    } on FileSystemException catch (error) {
      throw VectorStoreFailure('无法创建向量索引目录：${error.message}');
    }

    final shortHash = _shortHash(spec.indexKey);
    final collectionPath = p.join(rootPath, shortHash);
    final statePath = p.join(rootPath, '$shortHash.json');
    final stateFile = File(statePath);
    final collectionDir = Directory(collectionPath);

    var rebuiltReason = '';
    var state = _readState(stateFile, spec);
    if (collectionDir.existsSync() && state == null) {
      // 状态文件缺失或无法解析时无法确认模型与维度，按结构损坏处理。
      rebuiltReason = '状态文件缺失或无法解析';
      _quarantine(collectionPath, statePath);
    }
    Collection? collection;
    if (collectionDir.existsSync()) {
      try {
        collection = _openWithRetry(collectionPath);
      } on VectorStoreFailure {
        rethrow;
      } on Object catch (error) {
        rebuiltReason = '索引结构损坏：$error';
        _quarantine(collectionPath, statePath);
        state = null;
      }
    }
    if (collection == null) {
      if (stateFile.existsSync()) {
        try {
          stateFile.deleteSync();
        } on FileSystemException {
          // 删不掉时下面写状态会覆盖它。
        }
      }
      collection = _createCollection(collectionPath, spec);
      state = _IndexState.fresh(spec);
    }
    final index = ZvecVectorIndex._(
      rootPath,
      collectionPath,
      statePath,
      collection,
      spec,
      state!,
    );
    if (!stateFile.existsSync()) index._writeState();
    index._cleanupSiblings(shortHash);
    index._deleteLegacyDatabase();
    if (rebuiltReason.isNotEmpty) onRebuild?.call(rebuiltReason);
    return index;
  }

  /// 引擎按进程只初始化一次；多个 isolate 同时初始化时让后到的一方继续。
  static void _ensureEngine(String? logDirectory) {
    try {
      if (Zvec.isInitialized) return;
    } on Object catch (error) {
      throw VectorStoreFailure('向量引擎加载失败：$error');
    }
    // 两万条 1024 维向量的本体约 78 MiB，256 MB 只合六万条；20 万条光本体
    // 就要 781 MiB，加上索引结构、写入缓冲与查询的余量会超。调到 2 GB，约合
    // 五十万条向量的本体。引擎文档要求上限大于 100 MB，这是上限而不是常驻
    // 占用，索引类型与上限的结论见 ADR-0022 决定第 3 条。
    final config = ConfigData()
      ..setMemoryLimit(2 * 1024 * 1024 * 1024)
      ..setQueryThreadCount(1)
      ..setOptimizeThreadCount(1);
    if (logDirectory != null && logDirectory.isNotEmpty) {
      try {
        Directory(logDirectory).createSync(recursive: true);
      } on FileSystemException {
        // 日志目录建不出来时引擎仍可启动，只是没有文件日志。
      }
      config.setLogConfig(
        LogConfig.file(
          level: LogLevel.warn,
          directory: logDirectory,
          // zvec 0.8.0 对单个日志文件有 129 MB 的最小值校验。
          fileSizeMb: 129,
          overdueDays: 7,
        ),
      );
    }
    try {
      Zvec.initialize(config);
    } on ZvecException catch (error) {
      if (error.code != ZvecErrorCode.alreadyExists) {
        throw VectorStoreFailure('向量引擎初始化失败：$error');
      }
    } on Object catch (error) {
      throw VectorStoreFailure('向量引擎初始化失败：$error');
    }
  }

  /// 纯文本索引：没有配置嵌入模型时只建全文与标量字段。
  static bool _isTextOnly(EmbeddingModelSpec spec) =>
      spec.id == textOnlyModelSpec.id;

  static Collection _createCollection(String path, EmbeddingModelSpec spec) {
    final fields = <FieldSchema>[
      if (!_isTextOnly(spec))
        VectorSchema(
          _embeddingField,
          spec.dim,
          indexParams: FlatIndexParams(metricType: MetricType.cosine),
        ),
      FieldSchema(name: 'source_key', dataType: DataType.string)
        ..setIndexParams(InvertIndexParams()),
      FieldSchema(name: 'kind', dataType: DataType.string)
        ..setIndexParams(InvertIndexParams()),
      FieldSchema(name: 'material_id', dataType: DataType.string)
        ..setIndexParams(InvertIndexParams()),
      FieldSchema(name: 'conversation_id', dataType: DataType.string)
        ..setIndexParams(InvertIndexParams()),
      FieldSchema(name: 'content', dataType: DataType.string)
        ..setIndexParams(FtsIndexParams(tokenizerName: 'jieba')),
      FieldSchema(name: 'source_version', dataType: DataType.string),
      FieldSchema(name: 'locator_json', dataType: DataType.string),
      FieldSchema(name: 'created_at', dataType: DataType.string),
      FieldSchema(name: 'chunk', dataType: DataType.int64),
      FieldSchema(name: 'chunk_count', dataType: DataType.int64),
    ];
    final schema = CollectionSchema(
      name: 'zhixin_vector_index',
      fields: fields,
    );
    try {
      schema.validate();
      return Collection.createAndOpen(path, schema);
    } catch (error) {
      throw VectorStoreFailure('无法创建向量索引：$error');
    } finally {
      schema.destroy();
      for (final field in fields) {
        field.destroy();
      }
    }
  }

  static Collection _openWithRetry(String path) {
    for (var attempt = 0; ; attempt++) {
      try {
        return Collection.open(path);
      } on ZvecException catch (error) {
        if (!_isLocked(error)) rethrow;
        if (attempt >= _lockRetryDelaysMs.length) {
          throw const VectorStoreFailure('索引正被占用');
        }
        sleep(Duration(milliseconds: _lockRetryDelaysMs[attempt]));
      }
    }
  }

  static bool _isLocked(ZvecException error) =>
      (error.message ?? '').toLowerCase().contains('lock');

  /// 把打不开的 collection 移到旁边，交给下一次打开清理。
  static void _quarantine(String collectionPath, String statePath) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    try {
      Directory(collectionPath).renameSync('$collectionPath.broken-$stamp');
    } on FileSystemException {
      try {
        Directory(collectionPath).deleteSync(recursive: true);
      } on FileSystemException {
        // 下次打开再删。
      }
    }
    try {
      File(statePath).deleteSync();
    } on FileSystemException {
      // 状态文件删不掉时，写新的状态会覆盖它。
    }
  }

  static String _shortHash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, _hashLength);

  /// 删除其他模型键的目录与状态文件，以及上次留下的临时目录。
  ///
  /// 另一个 isolate 还开着的 collection 不删除：先试着打开一次，遇到占用就跳过。
  /// 只在表单上换个模型又换回来时，这样不会把对方正在用的索引删掉；删不掉的
  /// 留给下一次打开。
  void _cleanupSiblings(String shortHash) {
    const hashPattern = r'^[0-9a-f]{16}$';
    final hashRegExp = RegExp(hashPattern);
    final removed = <String>{};
    try {
      for (final entity in Directory(rootPath).listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == shortHash || name == '$shortHash.json') continue;
        if (entity is! Directory) continue;
        final temporary = name.contains('.trash-') || name.contains('.broken-');
        if (!temporary &&
            hashRegExp.hasMatch(name) &&
            _isCollectionInUse(name)) {
          continue;
        }
        try {
          entity.deleteSync(recursive: true);
          if (!temporary) removed.add(name);
        } on FileSystemException {
          // 删不掉的留到下一次打开。
        }
      }
      // 状态文件只在对应 collection 已经不在了才删除。
      for (final entity in Directory(rootPath).listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.json')) continue;
        final hash = name.substring(0, name.length - '.json'.length);
        if (hash == shortHash) continue;
        if (removed.contains(hash) ||
            !Directory(p.join(rootPath, hash)).existsSync()) {
          try {
            entity.deleteSync();
          } on FileSystemException {
            // 下一次打开再删。
          }
        }
      }
    } on FileSystemException {
      // 目录列不出来时不影响本次使用。
    }
  }

  /// 另一个句柄是否还开着这个 collection；能打开说明没有，由调用方删除。
  bool _isCollectionInUse(String hash) {
    try {
      final other = Collection.open(p.join(rootPath, hash));
      other.close();
      return false;
    } on ZvecException catch (error) {
      return _isLocked(error);
    } on Object {
      // 打不开的目录按损坏处理，可以删除。
      return false;
    }
  }

  /// 过渡期的旧 SQLite 索引文件不再使用，打开新引擎时删除。
  void _deleteLegacyDatabase() {
    final parent = p.dirname(rootPath);
    for (final name in const [
      'vector_index.db',
      'vector_index.db-wal',
      'vector_index.db-shm',
    ]) {
      try {
        final file = File(p.join(parent, name));
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // 删不掉的留着，不影响当前索引。
      }
    }
  }

  static _IndexState? _readState(File file, EmbeddingModelSpec spec) {
    if (!file.existsSync()) return null;
    try {
      final state = _IndexState.parse(file.readAsStringSync());
      if (state == null) return null;
      if (state.modelKey != spec.indexKey ||
          state.dim != spec.dim ||
          state.textVersion != spec.textVersion) {
        return null;
      }
      return state;
    } on FileSystemException {
      return null;
    }
  }

  void _writeState() {
    final temp = File('$statePath.tmp');
    try {
      Directory(rootPath).createSync(recursive: true);
      temp.writeAsStringSync(jsonEncode(_state.toJson()), flush: true);
      try {
        temp.renameSync(statePath);
      } on FileSystemException {
        try {
          File(statePath).deleteSync();
        } on FileSystemException {
          // 目标不存在或删不掉，下面的改名再试一次。
        }
        temp.renameSync(statePath);
      }
    } on FileSystemException catch (error) {
      throw VectorStoreFailure('无法写入向量索引状态：${error.message}');
    }
  }

  void _ensureOpen() {
    if (_closed) throw const VectorStoreFailure('向量索引已经关闭');
  }

  @override
  int get entryCount {
    final stats = _collection.stats;
    try {
      return stats.docCount;
    } finally {
      stats.destroy();
    }
  }

  @override
  int get sourceCount => int.tryParse(_state.sourceCount) ?? 0;

  @override
  Map<String, IndexedSource> indexedSources(List<String> keys) {
    _ensureOpen();
    const batchSize = 500;
    final result = <String, IndexedSource>{};
    for (var start = 0; start < keys.length; start += batchSize) {
      final end = (start + batchSize).clamp(start, keys.length);
      final batch = [for (final key in keys.sublist(start, end)) '$key#0'];
      final docs = _collection.fetch(
        batch,
        outputFields: const ['source_key', 'source_version', 'chunk_count'],
        includeVector: false,
      );
      try {
        for (final doc in docs) {
          final key = doc.getString('source_key');
          final version = doc.getString('source_version');
          final chunks = doc.getInt64('chunk_count');
          if (key == null || version == null || chunks == null) continue;
          result[key] = IndexedSource(sourceVersion: version, chunks: chunks);
        }
      } finally {
        for (final doc in docs) {
          doc.destroy();
        }
      }
    }
    return result;
  }

  @override
  String? meta(String key) {
    VectorIndex.validateMetaKey(key);
    return switch (key) {
      'epoch' => _state.epoch,
      'built_at' => _state.builtAt,
      'source_count' => _state.sourceCount,
      _ => null,
    };
  }

  @override
  void setMeta(String key, String value) {
    VectorIndex.validateMetaKey(key);
    switch (key) {
      case 'epoch':
        _state.epoch = value;
      case 'built_at':
        _state.builtAt = value;
      case 'source_count':
        _state.sourceCount = value;
    }
    _writeState();
  }

  @override
  void finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  }) {
    _ensureOpen();
    _state
      ..builtAt = builtAt
      ..sourceCount = '$sourceCount';
    _writeState();
    _collection.flush();
    if (writtenEntries > _optimizeThreshold) _collection.optimize();
  }

  @override
  void replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  }) {
    _ensureOpen();
    final textOnly = _isTextOnly(spec);
    if (chunks.length != vectors.length && !(textOnly && vectors.isEmpty)) {
      throw ArgumentError('片段数与向量数不一致');
    }
    final sourceKey = locator.sourceKey;
    _validateKey(sourceKey);
    final count = chunks.length;
    if (count == 0) {
      _collection.deleteByFilter("source_key = '$sourceKey'");
      return;
    }
    final tail = <Doc>[];
    Doc? head;
    try {
      for (var index = 1; index < count; index++) {
        tail.add(
          _makeDoc(
            locator: locator,
            sourceVersion: sourceVersion,
            chunk: index,
            chunkCount: count,
            content: chunks[index],
            createdAt: createdAt,
            vector: vectors.isEmpty ? null : vectors[index],
          ),
        );
      }
      _writeBatch(tail);
      // 旧版本多出来的片段先删除，再写 0 号片段作为这个来源的提交记录。
      _collection.deleteByFilter(
        "source_key = '$sourceKey' and chunk >= $count",
      );
      head = _makeDoc(
        locator: locator,
        sourceVersion: sourceVersion,
        chunk: 0,
        chunkCount: count,
        content: chunks[0],
        createdAt: createdAt,
        vector: vectors.isEmpty ? null : vectors[0],
      );
      _writeBatch([head]);
    } finally {
      head?.destroy();
      for (final doc in tail) {
        doc.destroy();
      }
    }
  }

  Doc _makeDoc({
    required SemanticLocator locator,
    required String sourceVersion,
    required int chunk,
    required int chunkCount,
    required String content,
    required String createdAt,
    required List<double>? vector,
  }) {
    final doc = Doc(id: '${locator.sourceKey}#$chunk');
    try {
      if (vector != null) {
        doc.setVector(
          _embeddingField,
          Float32List.fromList(normalizeVector(vector)),
        );
      }
      doc.setField('source_key', locator.sourceKey);
      doc.setField('kind', locator.kind);
      final materialId = locator.materialId;
      if (materialId == null) {
        doc.setFieldNull('material_id');
      } else {
        doc.setField('material_id', materialId);
      }
      final conversationId = locator.conversationId;
      if (conversationId == null) {
        doc.setFieldNull('conversation_id');
      } else {
        doc.setField('conversation_id', conversationId);
      }
      doc.setField('content', content);
      doc.setField('source_version', sourceVersion);
      doc.setField('locator_json', VectorIndex.jsonOf(locator));
      doc.setField('created_at', createdAt);
      doc.setField('chunk', chunk);
      doc.setField('chunk_count', chunkCount);
      return doc;
    } catch (_) {
      doc.destroy();
      rethrow;
    }
  }

  void _writeBatch(List<Doc> docs) {
    if (docs.isEmpty) return;
    final result = _collection.upsert(docs);
    if (result.errorCount > 0) {
      final detail = result.errorMessages.isEmpty
          ? '${result.errorCount} 条'
          : result.errorMessages.join('；');
      throw VectorStoreFailure('写入向量索引失败：$detail');
    }
  }

  @override
  int pruneSources(Set<String> keep) {
    _ensureOpen();
    if (keep.isEmpty) return _clear();
    final before = entryCount;
    final expression = StringBuffer("source_key not in (");
    var first = true;
    for (final key in keep) {
      _validateKey(key);
      if (!first) expression.write(', ');
      expression
        ..write("'")
        ..write(key)
        ..write("'");
      first = false;
    }
    expression.write(')');
    _collection.deleteByFilter(expression.toString());
    return before - entryCount;
  }

  @override
  List<StoredVector> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) {
    _ensureOpen();
    if (_isTextOnly(spec)) return const [];
    if (k <= 0 || query.isEmpty) return const [];
    final request = VectorQuery(
      fieldName: _embeddingField,
      vector: Float32List.fromList(normalizeVector(query)),
      topk: k,
      filter: _filterFor(prefilter),
      includeVector: false,
      outputFields: const [
        'source_key',
        'chunk',
        'content',
        'source_version',
        'locator_json',
      ],
    );
    final docs = <Doc>[];
    try {
      docs.addAll(_collection.query(request));
      final result = <StoredVector>[];
      for (final doc in docs) {
        final sourceKey = doc.getString('source_key');
        final chunk = doc.getInt64('chunk');
        final content = doc.getString('content');
        final sourceVersion = doc.getString('source_version');
        final locatorJson = doc.getString('locator_json');
        if (sourceKey == null ||
            chunk == null ||
            content == null ||
            sourceVersion == null ||
            locatorJson == null) {
          continue;
        }
        result.add(
          StoredVector(
            sourceKey: sourceKey,
            chunk: chunk,
            content: content,
            sourceVersion: sourceVersion,
            locatorJson: locatorJson,
            distance: doc.score,
          ),
        );
      }
      return result;
    } finally {
      request.destroy();
      for (final doc in docs) {
        doc.destroy();
      }
    }
  }

  /// 关键词与语义两路候选在同一次查询里融合，融合方式为名次倒数相加。
  ///
  /// [vector] 为空时只做关键词一路；zvec 的 MultiQuery 至少要有两路子查询，
  /// 这时把同一条关键词查询发两次，融合后的先后与单路的 BM25 顺序一致。
  @override
  List<StoredVector> searchHybrid(
    String text, {
    List<double>? vector,
    int k = 20,
    VectorPrefilter? prefilter,
  }) {
    _ensureOpen();
    if (k <= 0) return const [];
    final queryText = text.trim();
    final hasVector = vector != null && vector.isNotEmpty;
    if (queryText.isEmpty && !hasVector) return const [];
    final candidates = math.min(400, math.max(k, k * 4));
    final subQueries = <SubQuery>[
      if (queryText.isNotEmpty)
        SubQuery(
          fieldName: _contentField,
          fts: FtsQuery(matchString: queryText),
          numCandidates: candidates,
        ),
      if (hasVector)
        SubQuery(
          fieldName: _embeddingField,
          vector: Float32List.fromList(normalizeVector(vector)),
          numCandidates: candidates,
        ),
    ];
    if (subQueries.length == 1) {
      subQueries.add(
        SubQuery(
          fieldName: _contentField,
          fts: FtsQuery(matchString: queryText),
          numCandidates: candidates,
        ),
      );
    }
    final request = MultiQuery(
      subQueries: subQueries,
      topk: k,
      filter: _filterFor(prefilter),
      includeVector: false,
      outputFields: const [
        'source_key',
        'chunk',
        'content',
        'source_version',
        'locator_json',
      ],
      rerank: const RrfRerank(rankConstant: _rrfRankConstant),
    );
    final docs = <Doc>[];
    try {
      docs.addAll(_collection.multiQuery(request));
      final result = <StoredVector>[];
      for (final doc in docs) {
        final sourceKey = doc.getString('source_key');
        final chunk = doc.getInt64('chunk');
        final content = doc.getString('content');
        final sourceVersion = doc.getString('source_version');
        final locatorJson = doc.getString('locator_json');
        if (sourceKey == null ||
            chunk == null ||
            content == null ||
            sourceVersion == null ||
            locatorJson == null) {
          continue;
        }
        result.add(
          StoredVector(
            sourceKey: sourceKey,
            chunk: chunk,
            content: content,
            sourceVersion: sourceVersion,
            locatorJson: locatorJson,
            distance: 0,
            score: doc.score,
          ),
        );
      }
      return result;
    } finally {
      request.destroy();
      for (final doc in docs) {
        doc.destroy();
      }
    }
  }

  /// 把值类型预过滤渲染成 zvec 的过滤表达式；只使用写入后不变的属性。
  String? _filterFor(VectorPrefilter? prefilter) {
    if (prefilter == null) return null;
    return switch (prefilter) {
      MaterialVectorPrefilter(:final materialId) =>
        "(kind = 'material_page' and material_id = '${_escape(materialId)}')"
            " or kind != 'material_page'",
      ConversationVectorPrefilter(:final conversationId, :final sourceKeys) =>
        _conversationFilter(conversationId, sourceKeys),
      SourceKeysVectorPrefilter(:final sourceKeys) => _sourceKeysFilter(
        sourceKeys,
      ),
    };
  }

  /// 只按来源键放行；空的键集合用不可能命中的等值表达式表示。
  String _sourceKeysFilter(Set<String> sourceKeys) {
    if (sourceKeys.isEmpty) return "source_key = ''";
    final values = [for (final key in sourceKeys) "'${_escape(key)}'"];
    return 'source_key in (${values.join(', ')})';
  }

  String _conversationFilter(String? conversationId, Set<String> sourceKeys) {
    final clauses = <String>[];
    if (conversationId != null && conversationId.isNotEmpty) {
      clauses.add("conversation_id = '${_escape(conversationId)}'");
    }
    if (sourceKeys.isNotEmpty) {
      final values = [for (final key in sourceKeys) "'${_escape(key)}'"];
      clauses.add('source_key in (${values.join(', ')})');
    }
    // 两个条件都为空时业务规则一条也不放行；用不可能命中的等值表达式表示。
    return clauses.isEmpty ? "source_key = ''" : clauses.join(' or ');
  }

  static String _escape(String value) {
    _validateKey(value);
    return value;
  }

  static void _validateKey(String value) {
    if (value.isEmpty || !_safeKey.hasMatch(value)) {
      throw ArgumentError.value(value, 'key', '来源键只能包含字母、数字、冒号、下划线与连字符');
    }
  }

  @override
  void clear() => _clear();

  int _clear() {
    _ensureOpen();
    final before = entryCount;
    _collection.close();
    final trash =
        '$collectionPath.trash-${DateTime.now().millisecondsSinceEpoch}';
    var renamed = false;
    try {
      Directory(collectionPath).renameSync(trash);
      renamed = true;
    } on FileSystemException {
      // 改名失败时退回直接删除；下次打开仍按损坏处理。
      try {
        Directory(collectionPath).deleteSync(recursive: true);
      } on FileSystemException {
        // 目录删不掉时创建会失败，由调用方按刷新失败处理。
      }
    }
    _collection = _createCollection(collectionPath, spec);
    _state = _IndexState(
      modelKey: _state.modelKey,
      dim: _state.dim,
      textVersion: _state.textVersion,
      epoch: _state.epoch,
      sourceCount: '0',
    );
    _writeState();
    if (renamed) {
      try {
        Directory(trash).deleteSync(recursive: true);
      } on FileSystemException {
        // 下一次打开会再删。
      }
    }
    return before;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _collection.flush();
    } on Object {
      // 关闭阶段不再因为刷盘失败抛错，句柄仍要释放。
    }
    _collection.close();
  }
}

/// 状态文件的内容：模型键、维度、文本处理版本与刷新统计。
class _IndexState {
  _IndexState({
    required this.modelKey,
    required this.dim,
    required this.textVersion,
    required this.epoch,
    this.builtAt,
    required this.sourceCount,
  });

  factory _IndexState.fresh(EmbeddingModelSpec spec) => _IndexState(
    modelKey: spec.indexKey,
    dim: spec.dim,
    textVersion: spec.textVersion,
    epoch: '0',
    sourceCount: '0',
  );

  static _IndexState? parse(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final modelKey = value['model_key'];
      final dim = value['dim'];
      final textVersion = value['text_version'];
      if (modelKey is! String || dim is! int || textVersion is! String) {
        return null;
      }
      final builtAt = value['built_at'];
      return _IndexState(
        modelKey: modelKey,
        dim: dim,
        textVersion: textVersion,
        epoch: '${value['epoch'] ?? '0'}',
        builtAt: builtAt is String ? builtAt : null,
        sourceCount: '${value['source_count'] ?? '0'}',
      );
    } catch (_) {
      return null;
    }
  }

  final String modelKey;
  final int dim;
  final String textVersion;
  String epoch;
  String? builtAt;
  String sourceCount;

  Map<String, Object?> toJson() => {
    'model_key': modelKey,
    'dim': dim,
    'text_version': textVersion,
    'epoch': epoch,
    'built_at': builtAt,
    'source_count': sourceCount,
  };
}
