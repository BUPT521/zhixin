import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/domain/rules/embedding.dart';
import 'package:zvec/zvec.dart';

const _dimensions = 1024;
const _chunksPerSource = 4;
const _topK = 20;
const _querySamples = 100;
const _createdAt = '2026-11-16T00:00:00Z';
const _outputFields = [
  'source_key',
  'chunk',
  'content',
  'source_version',
  'locator_json',
];

enum _Engine { sqlite, zvec }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final route = PlatformDispatcher.instance.defaultRouteName;
  runApp(
    MaterialApp(
      initialRoute: '/',
      home: _Probe(launchRoute: route),
    ),
  );
}

class _Probe extends StatefulWidget {
  const _Probe({required this.launchRoute});

  final String launchRoute;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  _Engine _engine = _Engine.zvec;
  int _size = 20000;
  bool _busy = false;
  String _result = '先生成索引，再强行停止并重开本应用。重开后选择同一引擎和数量，测量冷打开与检索。';

  @override
  void initState() {
    super.initState();
    final match = RegExp(r'^/adr0022/(sqlite|zvec)/(2000|20000)/(seed|query)$')
        .firstMatch(widget.launchRoute);
    if (match != null) {
      _engine = _Engine.values.byName(match.group(1)!);
      _size = int.parse(match.group(2)!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(seed: match.group(3) == 'seed');
      });
    }
  }

  Future<void> _run({required bool seed}) async {
    setState(() => _busy = true);
    try {
      final support = await getApplicationSupportDirectory();
      final cache = await getApplicationCacheDirectory();
      final directory = path.join(support.path, 'adr0022_probe');
      final logs = path.join(cache.path, 'zvec_logs');
      final engine = _engine;
      final size = _size;
      final metrics = await _measureInBackground(
        directory,
        logs,
        engine,
        size,
        seed: seed,
      );
      _result = const JsonEncoder.withIndent('  ').convert(metrics);
      debugPrintSynchronously('ADR0022 ${jsonEncode(metrics)}');
    } catch (error, stack) {
      _result = '$error';
      debugPrintSynchronously('ADR0022 ERROR $error\n$stack');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ADR-0022 性能探针')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButton<_Engine>(
          value: _engine,
          items: [
            for (final engine in _Engine.values)
              DropdownMenuItem(value: engine, child: Text(engine.name)),
          ],
          onChanged: _busy
              ? null
              : (engine) => setState(() => _engine = engine!),
        ),
        DropdownButton<int>(
          value: _size,
          items: [
            for (final size in [2000, 20000])
              DropdownMenuItem(
                value: size,
                child: Text('$size × $_dimensions'),
              ),
          ],
          onChanged: _busy ? null : (size) => setState(() => _size = size!),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(seed: true),
          child: const Text('重新生成索引'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(seed: false),
          child: const Text('打开并检索'),
        ),
        if (_busy) const LinearProgressIndicator(),
        SelectableText(_result),
      ],
    ),
  );
}

Future<Map<String, Object>> _measureInBackground(
  String directory,
  String logs,
  _Engine engine,
  int size, {
  required bool seed,
}) => Isolate.run(() => _measure(directory, logs, engine, size, seed: seed));

Map<String, Object> _measure(
  String directory,
  String logs,
  _Engine engine,
  int size, {
  required bool seed,
}) {
  final dataset = Directory(path.join(directory, '${engine.name}-$size'));
  if (seed) {
    if (dataset.existsSync()) dataset.deleteSync(recursive: true);
    dataset.createSync(recursive: true);
  } else if (!dataset.existsSync()) {
    throw StateError('请先生成对应的索引');
  }

  final baselineRss = ProcessInfo.currentRss;
  final startupPeakRss = ProcessInfo.maxRss;
  final watch = Stopwatch()..start();
  final index = switch (engine) {
    _Engine.sqlite => _SqliteProbe(path.join(dataset.path, 'vector_index.db')),
    _Engine.zvec => _ZvecProbe(
      path.join(dataset.path, 'collection'),
      logs,
      seed,
    ),
  };
  watch.stop();
  final metrics = <String, Object>{
    'engine': engine.name,
    'vectors': size,
    'dimensions': _dimensions,
    'phase': seed ? 'seed' : 'open_and_query',
    'open_us': watch.elapsedMicroseconds,
    'cold_zvec_open': index.coldOpen,
    'baseline_rss_bytes': baselineRss,
    'startup_peak_rss_bytes': startupPeakRss,
  };
  try {
    if (seed) {
      metrics.addAll(_seed(index, size));
    } else {
      if (index.count != size) throw StateError('已有索引未写完');
      metrics['all_query_us'] = _query(index, scoped: false);
      metrics['material_query_us'] = _query(index, scoped: true);
    }
    if (index.count != size) {
      throw StateError('索引中应有 $size 条向量，实际有 ${index.count} 条');
    }
    final peakRss = ProcessInfo.maxRss;
    metrics['process_peak_rss_bytes'] = peakRss;
    // 进程历史峰值可能包含启动峰值，所得增量为本次操作峰值增量的上界。
    metrics['rss_delta_upper_bound_bytes'] = math.max(0, peakRss - baselineRss);
  } finally {
    index.close();
  }
  metrics['disk_bytes'] = dataset
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .fold<int>(0, (total, file) => total + file.lengthSync());
  return metrics;
}

Map<String, int> _seed(_IndexProbe index, int size) {
  final random = math.Random(22);
  final write = Stopwatch();
  final text = List.filled(40, '知新语义索引试验').join();
  for (var source = 0; source < size ~/ _chunksPerSource; source++) {
    final material = source % 5 != 0;
    final kind = material ? 'material_page' : 'message';
    final locator = SemanticLocator(
      kind: kind,
      sourceKey: '$kind:$source',
      materialId: material ? 'm${source % 8}' : null,
      conversationId: material ? null : 'c${source % 10}',
      pageNo: material ? source : null,
      messageId: material ? null : 'msg$source',
    );
    final vectors = [
      for (var chunk = 0; chunk < _chunksPerSource; chunk++) _vector(random),
    ];
    write.start();
    index.write(locator, text, vectors);
    write.stop();
  }
  final finish = index.finishWrites();
  return {
    'write_us': write.elapsedMicroseconds,
    ...finish,
    'total_write_us':
        write.elapsedMicroseconds + finish.values.fold(0, (a, b) => a + b),
  };
}

List<double> _vector(math.Random random) => List.generate(
  _dimensions,
  (_) => random.nextDouble() * 2 - 1,
  growable: false,
);

Map<String, int> _query(_IndexProbe index, {required bool scoped}) {
  final random = math.Random(23);
  final samples = <int>[];
  var minHits = _topK;
  for (var sample = -5; sample < _querySamples; sample++) {
    final vector = _vector(random);
    final watch = Stopwatch()..start();
    final hits = index.query(vector, scoped: scoped);
    watch.stop();
    if (sample >= 0) {
      samples.add(watch.elapsedMicroseconds);
      minHits = math.min(minHits, hits);
    }
  }
  samples.sort();
  return {'p50': samples[49], 'p95': samples[94], 'min_hits': minHits};
}

abstract interface class _IndexProbe {
  bool get coldOpen;
  int get count;
  void write(SemanticLocator locator, String text, List<List<double>> vectors);
  Map<String, int> finishWrites();
  int query(List<double> vector, {required bool scoped});
  void close();
}

class _SqliteProbe implements _IndexProbe {
  _SqliteProbe(String path)
    : _index = VectorIndex.open(
        path: path,
        spec: const EmbeddingModelSpec(id: 'probe', dim: _dimensions),
      );

  final VectorIndex _index;

  @override
  bool get coldOpen => false;

  @override
  int get count => _index.entryCount;

  @override
  void write(SemanticLocator locator, String text, List<List<double>> vectors) {
    _index.replaceSource(
      locator: locator,
      sourceVersion: '1',
      chunks: List.filled(_chunksPerSource, text),
      vectors: vectors,
      createdAt: _createdAt,
    );
  }

  @override
  Map<String, int> finishWrites() => const {};

  @override
  int query(List<double> vector, {required bool scoped}) {
    final hits = _index.search(vector, k: scoped ? _topK * 20 : _topK);
    if (!scoped) return hits.length;
    return hits
        .where((hit) {
          final locator = SemanticLocator.fromJson(hit.locatorJson)!;
          return locator.kind != 'material_page' || locator.materialId == 'm1';
        })
        .take(_topK)
        .length;
  }

  @override
  void close() => _index.close();
}

class _ZvecProbe implements _IndexProbe {
  _ZvecProbe(String path, String logs, bool seed) {
    coldOpen = !Zvec.isInitialized;
    if (coldOpen) {
      Directory(logs).createSync(recursive: true);
      final config = ConfigData()
        ..setQueryThreadCount(1)
        ..setOptimizeThreadCount(1)
        ..setMemoryLimit(128 * 1024 * 1024)
        ..setLogConfig(
          LogConfig.file(
            level: LogLevel.warn,
            directory: logs,
            // zvec 0.8.0 要求文件日志的轮转大小大于 128 MB。
            fileSizeMb: 129,
            overdueDays: 7,
          ),
        );
      Zvec.initialize(config);
    }
    _collection = seed ? _createCollection(path) : Collection.open(path);
  }

  late final Collection _collection;

  @override
  late final bool coldOpen;

  @override
  int get count => _collection.stats.docCount;

  @override
  void write(SemanticLocator locator, String text, List<List<double>> vectors) {
    final docs = <Doc>[];
    final locatorJson = jsonEncode(locator.toJson());
    try {
      for (var chunk = 0; chunk < _chunksPerSource; chunk++) {
        final doc = Doc(id: '${locator.sourceKey}#$chunk');
        docs.add(doc);
        doc
          ..setField('source_key', locator.sourceKey)
          ..setField('chunk', chunk)
          ..setField('chunk_count', chunk == 0 ? _chunksPerSource : 0)
          ..setField('kind', locator.kind)
          ..setField('content', text)
          ..setField('source_version', '1')
          ..setField('locator_json', locatorJson)
          ..setField('created_at', _createdAt)
          ..setVector(
            'embedding',
            Float32List.fromList(normalizeVector(vectors[chunk])),
          );
        final materialId = locator.materialId;
        final conversationId = locator.conversationId;
        if (materialId != null) doc.setField('material_id', materialId);
        if (conversationId != null) {
          doc.setField('conversation_id', conversationId);
        }
      }
      for (final batch in [
        docs.sublist(1),
        [docs.first],
      ]) {
        final result = _collection.upsert(batch);
        if (result.errorCount != 0) throw StateError('$result');
      }
    } finally {
      for (final doc in docs) {
        doc.destroy();
      }
    }
  }

  @override
  Map<String, int> finishWrites() {
    final flush = Stopwatch()..start();
    _collection.flush();
    flush.stop();
    final optimize = Stopwatch()..start();
    _collection.optimize();
    optimize.stop();
    return {
      'flush_us': flush.elapsedMicroseconds,
      'optimize_us': optimize.elapsedMicroseconds,
    };
  }

  @override
  int query(List<double> vector, {required bool scoped}) {
    final query = VectorQuery(
      fieldName: 'embedding',
      vector: Float32List.fromList(normalizeVector(vector)),
      filter: scoped
          ? "(kind = 'material_page' and material_id = 'm1') or kind != 'material_page'"
          : null,
      topk: _topK,
      outputFields: _outputFields,
    );
    try {
      final docs = _collection.query(query);
      try {
        // 读回同一组字段，和 SQLite 实现的回表及结果构造成本对应。
        return [
          for (final doc in docs)
            StoredVector(
              sourceKey: doc.getString('source_key')!,
              chunk: doc.getInt64('chunk')!,
              content: doc.getString('content')!,
              sourceVersion: doc.getString('source_version')!,
              locatorJson: doc.getString('locator_json')!,
              distance: doc.score,
            ),
        ].length;
      } finally {
        for (final doc in docs) {
          doc.destroy();
        }
      }
    } finally {
      query.destroy();
    }
  }

  @override
  // close 释放原生句柄，destroy 则删除仍打开的 collection。
  void close() => _collection.close();
}

Collection _createCollection(String path) {
  final schema = CollectionSchema(name: 'adr0022');
  final flat = FlatIndexParams();
  final invert = InvertIndexParams();

  void add(FieldSchema field, {IndexParams? index}) {
    try {
      if (index != null) field.setIndexParams(index);
      schema.addField(field);
    } finally {
      field.destroy();
    }
  }

  try {
    add(VectorSchema('embedding', _dimensions), index: flat);
    for (final field in [
      'source_key',
      'kind',
      'material_id',
      'conversation_id',
    ]) {
      add(
        FieldSchema(name: field, dataType: DataType.string),
        index: invert,
      );
    }
    for (final field in ['chunk', 'chunk_count']) {
      add(FieldSchema(name: field, dataType: DataType.int64, nullable: false));
    }
    for (final field in [
      'content',
      'source_version',
      'locator_json',
      'created_at',
    ]) {
      add(FieldSchema(name: field, dataType: DataType.string, nullable: false));
    }
    return Collection.createAndOpen(path, schema);
  } finally {
    schema.destroy();
    flat.destroy();
    invert.destroy();
  }
}
