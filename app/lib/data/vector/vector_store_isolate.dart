import 'dart:async';
import 'dart:isolate';

import '../../domain/rules/embedding.dart';
import 'vector_index.dart';
import 'vector_protocol.dart';
import 'vector_store.dart';
import 'zvec_vector_index.dart';

/// 后台 isolate 里的索引句柄。
///
/// zvec 的句柄与原生内存只存在于后台线程，界面线程发送写入与查询请求、等待
/// 结果，因此打开索引、建表与检索都不会占用界面帧。所有请求按发送顺序执行，
/// 同一时刻只有一个线程碰这份索引。文本 collection 与向量 collection 各用
/// 一个句柄，各自一个后台线程与一个目录。
///
/// 跨线程的请求与回包格式见 [VectorRequest] 与 [VectorResponse]：一条语句一个
/// 类，参数有名字，编解码只在那一个文件里；认不出的回包按失败交回等待方。
class IsolateVectorStore implements VectorStore {
  IsolateVectorStore._(this.spec, this._responses);

  @override
  final EmbeddingModelSpec spec;

  final ReceivePort _responses;
  ReceivePort? _control;
  StreamSubscription<Object?>? _controlSubscription;
  late final SendPort _commands;
  late final Isolate _isolate;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _closing;

  /// 打开索引；引擎初始化、打开 collection 与建表都在后台线程完成。
  ///
  /// [path] 是这一份 collection 的根目录：文本 collection 用
  /// `filesDir/vector_index/text`，向量 collection 用
  /// `filesDir/vector_index/vector`。[logDirectory] 给出时把 zvec 的警告日志写进
  /// 缓存目录。索引结构损坏被重建时，[onRebuild] 在界面线程收到一次说明，用于
  /// 写本机诊断记录。
  static Future<IsolateVectorStore> open({
    required String path,
    required EmbeddingModelSpec spec,
    String? logDirectory,
    void Function(String reason)? onRebuild,
  }) async {
    final responses = ReceivePort();
    final control = ReceivePort();
    final store = IsolateVectorStore._(spec, responses);
    final ready = Completer<void>();
    String? rebuiltReason;

    final responsesSubscription = responses.listen((message) {
      if (!ready.isCompleted) {
        if (message is Map && message['ready'] == true) {
          final commands = message['commands'];
          if (commands is SendPort) {
            store._commands = commands;
            rebuiltReason = message['rebuilt'] as String?;
            ready.complete();
            return;
          }
        }
        ready.completeError(
          VectorStoreFailure(_describeSpawnMessage(message, '没有返回就绪消息')),
        );
        return;
      }
      store._onResponse(message);
    });

    final controlSubscription = control.listen((message) {
      if (!ready.isCompleted) {
        ready.completeError(
          VectorStoreFailure(_describeSpawnMessage(message, '打开之前退出')),
        );
        return;
      }
      store._failPending(const VectorStoreFailure('后台索引线程已经退出'));
      store._closed = true;
      control.close();
      responses.close();
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_SpawnRequest>(
        _vectorStoreMain,
        _SpawnRequest(
          responses: responses.sendPort,
          path: path,
          spec: spec.toJson(),
          logDirectory: logDirectory,
        ),
        onError: control.sendPort,
        onExit: control.sendPort,
        debugName: 'zhixin-vector-index',
      );
      store._isolate = isolate;
      store._control = control;
      store._controlSubscription = controlSubscription;
      await ready.future;
      final rebuilt = rebuiltReason;
      if (rebuilt != null && rebuilt.isNotEmpty) onRebuild?.call(rebuilt);
      return store;
    } catch (_) {
      await responsesSubscription.cancel();
      await controlSubscription.cancel();
      control.close();
      responses.close();
      isolate?.kill(priority: Isolate.beforeNextEvent);
      rethrow;
    }
  }

  @override
  Future<int> entryCount() async => await _send(EntryCountRequest.new) as int;

  @override
  Future<int> sourceCount() async => await _send(SourceCountRequest.new) as int;

  @override
  Future<Map<String, IndexedSource>> indexedSources(List<String> keys) async {
    final value = await _send((id) => IndexedSourcesRequest(id, keys)) as Map;
    return {
      for (final entry in value.entries)
        entry.key as String: IndexedSource(
          sourceVersion: (entry.value as Map)['sourceVersion'] as String,
          chunks: (entry.value as Map)['chunks'] as int,
        ),
    };
  }

  @override
  Future<String?> meta(String key) async {
    VectorIndex.validateMetaKey(key);
    return await _send((id) => MetaRequest(id, key)) as String?;
  }

  @override
  Future<void> setMeta(String key, String value) async {
    VectorIndex.validateMetaKey(key);
    await _send((id) => SetMetaRequest(id, key, value));
  }

  @override
  Future<void> finishRefresh({
    required String builtAt,
    required int sourceCount,
    required int writtenEntries,
  }) async {
    await _send(
      (id) => FinishRefreshRequest(id, builtAt, sourceCount, writtenEntries),
    );
  }

  @override
  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    List<String> chunks = const [],
    List<String> hashes = const [],
    List<List<double>> vectors = const [],
    required String createdAt,
  }) async {
    await _send(
      (id) => ReplaceSourceRequest(
        id,
        VectorIndex.jsonOf(locator),
        sourceVersion,
        chunks,
        hashes,
        vectors,
        createdAt,
      ),
    );
  }

  @override
  Future<int> pruneSources(Set<String> keep) async =>
      await _send((id) => PruneSourcesRequest(id, keep.toList(growable: false)))
          as int;

  @override
  Future<List<StoredVector>> search(
    List<double> query, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) async {
    final value =
        await _send((id) => SearchRequest(id, query, k, prefilter)) as List;
    return [
      for (final row in value.cast<Map>())
        StoredVector(
          sourceKey: row['sourceKey'] as String,
          chunk: row['chunk'] as int,
          content: row['content'] as String,
          sourceVersion: row['sourceVersion'] as String,
          locatorJson: row['locatorJson'] as String,
          distance: (row['distance'] as num).toDouble(),
        ),
    ];
  }

  @override
  Future<List<StoredVector>> searchText(
    String text, {
    int k = 20,
    VectorPrefilter? prefilter,
  }) async {
    final value =
        await _send((id) => SearchTextRequest(id, text, k, prefilter)) as List;
    return [
      for (final row in value.cast<Map>())
        StoredVector(
          sourceKey: row['sourceKey'] as String,
          chunk: row['chunk'] as int,
          content: row['content'] as String,
          sourceVersion: row['sourceVersion'] as String,
          locatorJson: row['locatorJson'] as String,
          distance: 0,
          score: (row['score'] as num).toDouble(),
        ),
    ];
  }

  @override
  Future<void> clear() async {
    await _send(ClearRequest.new);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    final completer = Completer<Object?>();
    final id = _nextId++;
    _pending[id] = completer;
    _commands.send(CloseRequest(id).encode());
    try {
      // 等后台线程关闭数据库再释放端口；不设超时，避免在测试的假时钟里留下
      // 悬空的 Timer。后台线程意外退出时由控制端口的退出消息结束等待。
      await completer.future;
    } catch (_) {
      // 后台线程已经退出时不必再报一次。
    }
    await _controlSubscription?.cancel();
    _control?.close();
    _responses.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _failPending(const VectorStoreClosedException());
  }

  /// 发一条请求并等它对应的回包；请求编号在这里分配。
  Future<Object?> _send(VectorRequest Function(int id) build) {
    if (_closed) return Future.error(const VectorStoreClosedException());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send(build(id).encode());
    return completer.future;
  }

  /// 回包按编号交回等待方；认不出的回包让所有等待中的请求失败。
  ///
  /// 认不出的形状说明后台线程复述的协议与这里不一致，它不会再来第二次；这时
  /// 若继续等下去，等待方会永久挂起，因此直接按失败处理。
  void _onResponse(Object? message) {
    final response = VectorResponse.decode(message);
    if (response == null) {
      _failPending(const VectorStoreFailure('后台索引线程返回了无法识别的结果'));
      return;
    }
    final completer = _pending.remove(response.id);
    if (completer == null || completer.isCompleted) return;
    switch (response) {
      case VectorSuccess(:final value):
        completer.complete(value);
      case VectorFailure(:final message, :final stack):
        completer.completeError(
          VectorStoreFailure(message),
          StackTrace.fromString(stack),
        );
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

/// 发给后台线程的启动参数；只含可跨 isolate 传递的值。
class _SpawnRequest {
  const _SpawnRequest({
    required this.responses,
    required this.path,
    required this.spec,
    required this.logDirectory,
  });

  final SendPort responses;
  final String path;
  final Map<String, Object?> spec;
  final String? logDirectory;
}

/// 后台线程入口：打开索引，然后按顺序执行界面发来的请求。
void _vectorStoreMain(_SpawnRequest request) {
  final commands = ReceivePort();
  VectorIndex index;
  String? rebuiltReason;
  try {
    final spec = EmbeddingModelSpec.fromJson(request.spec);
    if (spec == null) throw const FormatException('嵌入模型信息不完整');
    index = ZvecVectorIndex.open(
      rootPath: request.path,
      spec: spec,
      logDirectory: request.logDirectory,
      onRebuild: (reason) => rebuiltReason = reason,
    );
  } catch (error, stack) {
    request.responses.send({
      'ready': false,
      'error': '$error',
      'stack': '$stack',
    });
    commands.close();
    return;
  }
  request.responses.send({
    'ready': true,
    'commands': commands.sendPort,
    'rebuilt': rebuiltReason,
  });

  commands.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final VectorRequest decoded;
    try {
      decoded = VectorRequest.decode(message);
    } catch (error, stack) {
      // 解不出的请求按同一个编号回一条失败：等待方拿到的是错误，不是永久挂起。
      request.responses.send(VectorFailure(id, '$error', '$stack').encode());
      return;
    }
    if (decoded is CloseRequest) {
      // 先关库再回执：界面收到结果后会结束后台线程，顺序反过来会留下未关闭的
      // 数据库句柄，测试里紧接着删除临时目录就会失败。
      index.close();
      request.responses.send(VectorSuccess(id, null).encode());
      commands.close();
      return;
    }
    try {
      final value = _runOperation(index, decoded);
      request.responses.send(VectorSuccess(id, value).encode());
    } catch (error, stack) {
      request.responses.send(VectorFailure(id, '$error', '$stack').encode());
    }
  });
}

Object? _runOperation(VectorIndex index, VectorRequest request) =>
    switch (request) {
      EntryCountRequest() => index.entryCount,
      SourceCountRequest() => index.sourceCount,
      IndexedSourcesRequest(:final keys) => {
        for (final entry in index.indexedSources(keys).entries)
          entry.key: {
            'sourceVersion': entry.value.sourceVersion,
            'chunks': entry.value.chunks,
          },
      },
      MetaRequest(:final key) => index.meta(key),
      SetMetaRequest(:final key, :final value) => () {
        index.setMeta(key, value);
        return null;
      }(),
      FinishRefreshRequest(
        :final builtAt,
        :final sourceCount,
        :final writtenEntries,
      ) =>
        () {
          index.finishRefresh(
            builtAt: builtAt,
            sourceCount: sourceCount,
            writtenEntries: writtenEntries,
          );
          return null;
        }(),
      ReplaceSourceRequest(
        :final locatorJson,
        :final sourceVersion,
        :final chunks,
        :final hashes,
        :final vectors,
        :final createdAt,
      ) =>
        () {
          final locator = SemanticLocator.fromJson(locatorJson);
          if (locator == null) {
            throw const FormatException('来源定位信息无法解析');
          }
          index.replaceSource(
            locator: locator,
            sourceVersion: sourceVersion,
            chunks: chunks,
            hashes: hashes,
            vectors: vectors,
            createdAt: createdAt,
          );
          return null;
        }(),
      PruneSourcesRequest(:final keep) => index.pruneSources(keep.toSet()),
      SearchRequest(:final query, :final k, :final prefilter) => [
        for (final row in index.search(query, k: k, prefilter: prefilter))
          {
            'sourceKey': row.sourceKey,
            'chunk': row.chunk,
            'content': row.content,
            'sourceVersion': row.sourceVersion,
            'locatorJson': row.locatorJson,
            'distance': row.distance,
          },
      ],
      SearchTextRequest(:final text, :final k, :final prefilter) => [
        for (final row in index.searchText(text, k: k, prefilter: prefilter))
          {
            'sourceKey': row.sourceKey,
            'chunk': row.chunk,
            'content': row.content,
            'sourceVersion': row.sourceVersion,
            'locatorJson': row.locatorJson,
            'score': row.score,
          },
      ],
      ClearRequest() => () {
        index.clear();
        return null;
      }(),
      // 关闭在监听里单独处理：先关库再回执，回执之后线程退出。
      CloseRequest() => null,
    };

String _describeSpawnMessage(Object? message, String fallback) {
  if (message is Map && message['error'] != null) return '${message['error']}';
  if (message is List && message.isNotEmpty) return '${message.first}';
  return fallback;
}
