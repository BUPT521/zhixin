import 'dart:async';
import 'dart:isolate';

import '../../domain/rules/embedding.dart';
import 'vector_index.dart';
import 'vector_store.dart';

/// 后台 isolate 里的向量索引句柄。
///
/// SQLite 的连接与 sqlite-vec 扩展只存在于后台线程，界面线程发送写入与查询
/// 请求、等待结果，因此打开索引、建表与检索都不会占用界面帧。所有请求按发送
/// 顺序执行，同一时刻只有一个线程碰这份库。
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

  /// 打开索引库；sqlite-vec 的加载与建表都在后台线程完成。
  static Future<IsolateVectorStore> open({
    required String path,
    required EmbeddingModelSpec spec,
    bool inMemory = false,
  }) async {
    final responses = ReceivePort();
    final control = ReceivePort();
    final store = IsolateVectorStore._(spec, responses);
    final ready = Completer<void>();

    final responsesSubscription = responses.listen((message) {
      if (!ready.isCompleted) {
        if (message is Map && message['ready'] == true) {
          final commands = message['commands'];
          if (commands is SendPort) {
            store._commands = commands;
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
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_SpawnRequest>(
        _vectorStoreMain,
        _SpawnRequest(
          responses: responses.sendPort,
          path: path,
          spec: spec.toJson(),
          inMemory: inMemory,
        ),
        onError: control.sendPort,
        onExit: control.sendPort,
        debugName: 'zhixin-vector-index',
      );
      store._isolate = isolate;
      store._control = control;
      store._controlSubscription = controlSubscription;
      await ready.future;
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
  Future<int> entryCount() async => await _send('entryCount') as int;

  @override
  Future<Map<String, IndexedSource>> indexedSources() async {
    final value = await _send('indexedSources') as Map;
    return {
      for (final entry in value.entries)
        entry.key as String: IndexedSource(
          sourceVersion: (entry.value as Map)['sourceVersion'] as String,
          chunks: (entry.value as Map)['chunks'] as int,
        ),
    };
  }

  @override
  Future<String?> meta(String key) async =>
      await _send('meta', [key]) as String?;

  @override
  Future<void> setMeta(String key, String value) async {
    await _send('setMeta', [key, value]);
  }

  @override
  Future<void> replaceSource({
    required SemanticLocator locator,
    required String sourceVersion,
    required List<String> chunks,
    required List<List<double>> vectors,
    required String createdAt,
  }) async {
    await _send('replaceSource', [
      VectorIndex.jsonOf(locator),
      sourceVersion,
      chunks,
      vectors,
      createdAt,
    ]);
  }

  @override
  Future<int> pruneSources(Set<String> keep) async =>
      await _send('pruneSources', [keep.toList(growable: false)]) as int;

  @override
  Future<List<StoredVector>> search(List<double> query, {int k = 20}) async {
    final value = await _send('search', [query, k]) as List;
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
  Future<void> clear() async {
    await _send('clear');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final completer = Completer<Object?>();
    final id = _nextId++;
    _pending[id] = completer;
    _commands.send({'id': id, 'op': 'close', 'args': const []});
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

  Future<Object?> _send(String op, [List<Object?> args = const []]) {
    if (_closed) return Future.error(const VectorStoreClosedException());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send({'id': id, 'op': op, 'args': args});
    return completer.future;
  }

  void _onResponse(Object? message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      completer.complete(message['value']);
      return;
    }
    completer.completeError(
      VectorStoreFailure('${message['error'] ?? '未知错误'}'),
      StackTrace.fromString('${message['stack'] ?? ''}'),
    );
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
    required this.inMemory,
  });

  final SendPort responses;
  final String path;
  final Map<String, Object?> spec;
  final bool inMemory;
}

/// 后台线程入口：打开索引库，然后按顺序执行界面发来的请求。
void _vectorStoreMain(_SpawnRequest request) {
  final commands = ReceivePort();
  VectorIndex index;
  try {
    final spec = EmbeddingModelSpec.fromJson(request.spec);
    if (spec == null) throw const FormatException('嵌入模型信息不完整');
    index = VectorIndex.open(
      path: request.path,
      spec: spec,
      inMemory: request.inMemory,
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
  request.responses.send({'ready': true, 'commands': commands.sendPort});

  commands.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final op = message['op'] as String;
    final args = (message['args'] as List).cast<Object?>();
    try {
      if (op == 'close') {
        // 先关库再回执：界面收到结果后会结束后台线程，顺序反过来会留下
        // 未关闭的数据库句柄，测试里紧接着删除临时目录就会失败。
        index.close();
        request.responses.send({'id': id, 'ok': true, 'value': null});
        commands.close();
        return;
      }
      final value = _runOperation(index, op, args);
      request.responses.send({'id': id, 'ok': true, 'value': value});
    } catch (error, stack) {
      request.responses.send({
        'id': id,
        'ok': false,
        'error': '$error',
        'stack': '$stack',
      });
    }
  });
}

Object? _runOperation(VectorIndex index, String op, List<Object?> args) {
  switch (op) {
    case 'entryCount':
      return index.entryCount;
    case 'indexedSources':
      return {
        for (final entry in index.indexedSources().entries)
          entry.key: {
            'sourceVersion': entry.value.sourceVersion,
            'chunks': entry.value.chunks,
          },
      };
    case 'meta':
      return index.meta(args[0] as String);
    case 'setMeta':
      index.setMeta(args[0] as String, args[1] as String);
      return null;
    case 'replaceSource':
      final locator = SemanticLocator.fromJson(args[0] as String);
      if (locator == null) {
        throw const FormatException('来源定位信息无法解析');
      }
      index.replaceSource(
        locator: locator,
        sourceVersion: args[1] as String,
        chunks: (args[2] as List).cast<String>(),
        vectors: [
          for (final vector in args[3] as List) (vector as List).cast<double>(),
        ],
        createdAt: args[4] as String,
      );
      return null;
    case 'pruneSources':
      return index.pruneSources((args[0] as List).cast<String>().toSet());
    case 'search':
      return [
        for (final row in index.search(
          (args[0] as List).cast<double>(),
          k: args[1] as int,
        ))
          {
            'sourceKey': row.sourceKey,
            'chunk': row.chunk,
            'content': row.content,
            'sourceVersion': row.sourceVersion,
            'locatorJson': row.locatorJson,
            'distance': row.distance,
          },
      ];
    case 'clear':
      index.clear();
      return null;
    case 'close':
      return null;
    default:
      throw ArgumentError('未知的向量索引操作：$op');
  }
}

String _describeSpawnMessage(Object? message, String fallback) {
  if (message is Map && message['error'] != null) return '${message['error']}';
  if (message is List && message.isNotEmpty) return '${message.first}';
  return fallback;
}
