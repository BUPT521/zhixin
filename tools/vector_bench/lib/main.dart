// 20 万条 1024 维向量的向量检索基准：zvec 的 Flat/HNSW/IVF 各种量化，
// 与 sqlite-vec 的 float32/int8/bit 三种存储对比。
//
// 只在真机上运行：数据在设备上按固定种子生成，真值在设备上用暴力余弦算出来，
// 每个场景把写入耗时、优化耗时、磁盘占用、常驻内存、查询延迟与 recall@10
// 追加到外部私有目录的 results.jsonl。配置从同一个目录的 config.json 读，
// 没有时用下面 _defaultScenarios 里的默认值。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;
import 'package:sqlite3_vec/sqlite3_vec.dart';
import 'package:zvec/zvec.dart';

const List<String> _defaultScenarios = [
  'zvec_flat_fp32',
  'zvec_flat_fp16',
  'zvec_flat_int8',
  'zvec_flat_int4',
  'sqlite_f32',
  'sqlite_int8',
  'sqlite_bit',
  'zvec_hnsw_fp32',
  'zvec_hnsw_int8',
  'zvec_hnsw_int4',
  'zvec_ivf_fp32',
  'zvec_ivf_int8',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchApp());
}

/// 基准配置；config.json 里的字段都可不写。
class BenchConfig {
  const BenchConfig({
    this.vectors = 200000,
    this.dim = 1024,
    this.queries = 100,
    this.topk = 10,
    this.seed = 20261117,
    this.memoryLimitMb = 6144,
    this.optimizeThreads = 4,
    this.hnswEf = 100,
    this.hnswEfs = const [100, 400, 1600],
    this.ivfNprobe = 64,
    this.ivfNlist = 1024,
    this.hnswM = 16,
    this.hnswEfConstruction = 200,
    this.dataset = 'uniform',
    this.clusters = 512,
    this.noise = 0.5,
    this.scenarios = _defaultScenarios,
  });

  final int vectors;
  final int dim;
  final int queries;
  final int topk;
  final int seed;
  final int memoryLimitMb;
  final int optimizeThreads;
  final int hnswEf;
  final List<int> hnswEfs;
  final int ivfNprobe;
  final int ivfNlist;
  final int hnswM;
  final int hnswEfConstruction;
  final String dataset;
  final int clusters;
  final double noise;
  final List<String> scenarios;

  factory BenchConfig.fromJson(Map<String, Object?> json) => BenchConfig(
    vectors: (json['vectors'] as num?)?.toInt() ?? 200000,
    dim: (json['dim'] as num?)?.toInt() ?? 1024,
    queries: (json['queries'] as num?)?.toInt() ?? 100,
    topk: (json['topk'] as num?)?.toInt() ?? 10,
    seed: (json['seed'] as num?)?.toInt() ?? 20261117,
    memoryLimitMb: (json['memory_limit_mb'] as num?)?.toInt() ?? 6144,
    optimizeThreads: (json['optimize_threads'] as num?)?.toInt() ?? 4,
    hnswEf: (json['hnsw_ef'] as num?)?.toInt() ?? 100,
    hnswEfs:
        (json['hnsw_efs'] as List<Object?>?)
            ?.map((value) => (value as num).toInt())
            .toList() ??
        const [100, 400, 1600],
    ivfNprobe: (json['ivf_nprobe'] as num?)?.toInt() ?? 64,
    ivfNlist: (json['ivf_nlist'] as num?)?.toInt() ?? 1024,
    hnswM: (json['hnsw_m'] as num?)?.toInt() ?? 16,
    hnswEfConstruction: (json['hnsw_ef_construction'] as num?)?.toInt() ?? 200,
    dataset: json['dataset'] as String? ?? 'uniform',
    clusters: (json['clusters'] as num?)?.toInt() ?? 512,
    noise: (json['noise'] as num?)?.toDouble() ?? 0.5,
    scenarios:
        (json['scenarios'] as List<Object?>?)?.cast<String>() ??
        _defaultScenarios,
  );

  Map<String, Object?> toJson() => {
    'vectors': vectors,
    'dim': dim,
    'queries': queries,
    'topk': topk,
    'seed': seed,
    'memory_limit_mb': memoryLimitMb,
    'optimize_threads': optimizeThreads,
    'hnsw_ef': hnswEf,
    'hnsw_efs': hnswEfs,
    'ivf_nprobe': ivfNprobe,
    'ivf_nlist': ivfNlist,
    'hnsw_m': hnswM,
    'hnsw_ef_construction': hnswEfConstruction,
    'dataset': dataset,
    'clusters': clusters,
    'noise': noise,
    'scenarios': scenarios,
  };
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});

  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  bool _running = false;
  String? _resultPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
      _lines.clear();
    });
    try {
      final root = await _benchRoot();
      final configFile = File(p.join(root, 'config.json'));
      if (!configFile.existsSync()) {
        configFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(
            const BenchConfig().toJson(),
          ),
        );
      }
      final configJson =
          jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
      final config = BenchConfig.fromJson(configJson);
      final resultFile = File(p.join(root, 'results.jsonl'));
      if (resultFile.existsSync()) resultFile.deleteSync();

      final receive = ReceivePort();
      await Isolate.spawn(_benchEntry, {
        'send': receive.sendPort,
        'config': config.toJson(),
        'root': root,
      });
      receive.listen((message) {
        final data = message as Map<String, Object?>;
        switch (data['type']) {
          case 'log':
            _log(data['line'] as String);
          case 'done':
            _log('完成。结果：${p.join(root, 'results.jsonl')}');
            setState(() {
              _running = false;
              _resultPath = root;
            });
            receive.close();
          case 'error':
            _log('失败：${data['error']}');
            setState(() {
              _running = false;
              _error = '${data['error']}';
            });
            receive.close();
        }
      });
    } catch (error) {
      setState(() {
        _running = false;
        _error = '$error';
      });
    }
  }

  void _log(String line) {
    setState(() => _lines.add(line));
    debugPrint('VECBENCH $line');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('向量检索基准 · 20 万')),
      body: Column(
        children: [
          if (_running) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _running ? null : _start,
                  child: const Text('重新运行'),
                ),
                const SizedBox(width: 12),
                if (_error != null)
                  const Expanded(
                    child: Text(
                      '有场景失败，详见下面的日志',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
          if (_resultPath != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SelectableText('结果目录：$_resultPath'),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (context, index) => Text(
                _lines[index],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 外部私有目录：adb 可以直接读写，不需要额外权限。
Future<String> _benchRoot() async {
  Directory? external;
  try {
    external = await getExternalStorageDirectory();
  } on Object {
    external = null;
  }
  final base = external ?? await getApplicationSupportDirectory();
  final root = p.join(base.path, 'vector_bench');
  Directory(root).createSync(recursive: true);
  return root;
}

Future<void> _benchEntry(Map<String, Object?> message) async {
  final send = message['send'] as SendPort;
  final config = BenchConfig.fromJson(
    message['config'] as Map<String, Object?>,
  );
  final root = message['root'] as String;
  void log(String line) => send.send({'type': 'log', 'line': line});
  try {
    await _runBenchmark(config, root, log);
    send.send({'type': 'done'});
  } catch (error, stack) {
    send.send({'type': 'error', 'error': '$error\n$stack'});
  }
}

Future<void> _runBenchmark(
  BenchConfig config,
  String root,
  void Function(String) log,
) async {
  final resultFile = File(p.join(root, 'results.jsonl'));
  final startedAt = DateTime.now().toUtc().toIso8601String();
  // 上一轮如果中途退出，会留下没跑完的 collection 目录；统一在开始时清掉，
  // 否则后面测 sqlite 的磁盘占用会把它们算进去。
  final dataRoot = Directory(p.join(root, 'data'));
  if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  dataRoot.createSync(recursive: true);
  resultFile.writeAsStringSync(
    '${jsonEncode({'event': 'start', 'started_at': startedAt, 'config': config.toJson()})}\n',
  );

  log('生成 ${config.vectors} × ${config.dim} 的数据集（种子 ${config.seed}）…');
  final genWatch = Stopwatch()..start();
  final data = _generateVectors(
    config.vectors,
    config.dim,
    config.seed,
    dataset: config.dataset,
    clusters: config.clusters,
    noise: config.noise,
  );
  final queries = _generateVectors(
    config.queries,
    config.dim,
    config.seed ^ 0x5DEECE66D,
    dataset: config.dataset,
    clusters: config.clusters,
    noise: config.noise,
  );
  genWatch.stop();
  log('数据集生成完成：${_mb(genWatch.elapsedMicroseconds)} s，'
      '${(data.lengthInBytes / 1048576).round()} MiB');

  log('计算 ${config.queries} 条查询的精确 top-${config.topk} 真值…');
  final truthWatch = Stopwatch()..start();
  final invNorms = _inverseNorms(data, config.vectors, config.dim);
  final truth = _exactTopK(data, queries, invNorms, config);
  truthWatch.stop();
  log('真值计算完成：${_mb(truthWatch.elapsedMicroseconds)} s');

  _initZvec(config);

  for (final scenario in config.scenarios) {
    log('开始 $scenario …');
    final watch = Stopwatch()..start();
    Map<String, Object?> row;
    try {
      if (scenario.startsWith('zvec_')) {
        row = _runZvec(
          scenario,
          config,
          data,
          queries,
          truth,
          root,
        );
      } else if (scenario.startsWith('sqlite_')) {
        row = _runSqlite(scenario, config, data, queries, truth, root);
      } else {
        throw ArgumentError('未知场景 $scenario');
      }
      row['status'] = 'ok';
    } catch (error, stack) {
      row = {'scenario': scenario, 'status': 'error', 'error': '$error'};
      log('$scenario 失败：$error');
      debugPrint('$stack');
    }
    row['wall_ms'] = watch.elapsedMilliseconds;
    row['scenario'] = scenario;
    resultFile.writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
    log(
      _describe(row),
    );
  }

  resultFile.writeAsStringSync(
    '${jsonEncode({'event': 'end', 'ended_at': DateTime.now().toUtc().toIso8601String()})}\n',
    mode: FileMode.append,
  );
}

String _describe(Map<String, Object?> row) {
  if (row['status'] != 'ok') {
    return '${row['scenario']}：${row['error']}';
  }
  String ms(Object? value) => value == null ? '-' : '$value ms';
  return '${row['scenario']}：写入 ${ms(row['insert_ms'])}，'
      '优化 ${ms(row['optimize_ms'])}，'
      '磁盘 ${row['disk_mb']} MB，'
      '查询 p50 ${ms(row['query_p50_ms'])} / p95 ${ms(row['query_p95_ms'])}，'
      'recall@${row['topk']} ${row['recall']}，'
      '峰值内存 ${row['process_peak_rss_mb']} MB';
}

String _mb(int microseconds) => (microseconds / 1e6).toStringAsFixed(1);

/// 用 32 位线性同余生成器在 [-1, 1) 上取均匀值；同一个种子在任何设备上给出
/// 同一批向量，换机器重跑时数据一致。
///
/// [dataset] 为 `uniform` 时每个分量独立取值，是向量检索里最简单也最难的
/// 分布；为 `clusters` 时先在同样的范围里取 [clusters] 个中心，再在中心上
/// 叠 [-noise, noise] 的均匀扰动，用来近似真实嵌入的聚集形状。
Float32List _generateVectors(
  int count,
  int dim,
  int seed, {
  String dataset = 'uniform',
  int clusters = 512,
  double noise = 0.5,
}) {
  final rng = _Rng(seed);
  final out = Float32List(count * dim);
  if (dataset == 'clusters') {
    final centers = Float32List(clusters * dim);
    for (var i = 0; i < centers.length; i++) {
      centers[i] = rng.next();
    }
    for (var v = 0; v < count; v++) {
      final center = rng.nextInt(clusters) * dim;
      final base = v * dim;
      for (var d = 0; d < dim; d++) {
        out[base + d] = centers[center + d] + rng.next() * noise;
      }
    }
    return out;
  }
  for (var i = 0; i < out.length; i++) {
    out[i] = rng.next();
  }
  return out;
}

class _Rng {
  _Rng(int seed) : _state = (seed & 0xFFFFFFFF) | 1;

  int _state;
  static const int _step = 1664525;
  static const int _increment = 1013904223;

  int _advance() => _state = (_state * _step + _increment) & 0xFFFFFFFF;

  double next() => ((_advance() >> 8) / 8388608.0) - 1.0;

  int nextInt(int bound) => (_advance() >> 8) % bound;
}

/// 每条向量的模长倒数，余弦排序只需要 dot * invNorm。
Float32List _inverseNorms(Float32List data, int count, int dim) {
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    final base = i * dim;
    var sum = 0.0;
    for (var d = 0; d < dim; d++) {
      final value = data[base + d];
      sum += value * value;
    }
    out[i] = 1 / math.sqrt(sum);
  }
  return out;
}

/// 暴力精确 top-k：与引擎无关，作为 recall 的参照。
List<List<int>> _exactTopK(
  Float32List data,
  Float32List queries,
  Float32List invNorms,
  BenchConfig config,
) {
  final dim = config.dim;
  final count = config.vectors;
  final topk = config.topk;
  final result = <List<int>>[];
  for (var q = 0; q < config.queries; q++) {
    final queryBase = q * dim;
    final bestScores = Float64List(topk)..fillRange(0, topk, -2.0);
    final bestIds = Int32List(topk)..fillRange(0, topk, -1);
    for (var v = 0; v < count; v++) {
      final base = v * dim;
      var dot = 0.0;
      for (var d = 0; d + 3 < dim; d += 4) {
        dot +=
            data[base + d] * queries[queryBase + d] +
            data[base + d + 1] * queries[queryBase + d + 1] +
            data[base + d + 2] * queries[queryBase + d + 2] +
            data[base + d + 3] * queries[queryBase + d + 3];
      }
      for (var d = dim & ~3; d < dim; d++) {
        dot += data[base + d] * queries[queryBase + d];
      }
      final score = dot * invNorms[v];
      if (score <= bestScores[topk - 1]) continue;
      var position = topk - 1;
      while (position > 0 && bestScores[position - 1] < score) {
        bestScores[position] = bestScores[position - 1];
        bestIds[position] = bestIds[position - 1];
        position--;
      }
      bestScores[position] = score;
      bestIds[position] = v;
    }
    result.add(bestIds.toList());
  }
  return result;
}

int _dirSize(Directory dir) {
  var total = 0;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += entity.lengthSync();
      } on FileSystemException {
        // 统计期间被删掉的文件略过。
      }
    }
  }
  return total;
}

double _recall(List<List<int>> got, List<List<int>> truth) {
  var hits = 0;
  var total = 0;
  for (var i = 0; i < truth.length; i++) {
    total += truth[i].length;
    if (i >= got.length) continue;
    final expected = truth[i].toSet();
    for (final id in got[i]) {
      if (expected.contains(id)) hits++;
    }
  }
  return total == 0 ? 0 : hits / total;
}

int _percentile(List<int> samples, double fraction) {
  if (samples.isEmpty) return 0;
  final sorted = [...samples]..sort();
  final index = ((sorted.length - 1) * fraction).round();
  return sorted[index];
}

Map<String, Object?> _queryStats(
  List<int> micros,
  List<List<int>> got,
  List<List<int>> truth,
  BenchConfig config,
) {
  final mean = micros.isEmpty
      ? 0.0
      : micros.reduce((a, b) => a + b) / micros.length / 1000;
  return {
    'query_p50_ms': _percentile(micros, 0.5) / 1000,
    'query_p95_ms': _percentile(micros, 0.95) / 1000,
    'query_mean_ms': mean.toStringAsFixed(2),
    'recall': _recall(got, truth).toStringAsFixed(4),
    'topk': config.topk,
  };
}

void _initZvec(BenchConfig config) {
  try {
    if (Zvec.isInitialized) return;
  } on Object {
    // 未初始化时读取会抛异常，继续初始化。
  }
  final data = ConfigData()
    ..setMemoryLimit(config.memoryLimitMb * 1024 * 1024)
    ..setQueryThreadCount(1)
    ..setOptimizeThreadCount(config.optimizeThreads);
  try {
    Zvec.initialize(data);
  } on ZvecException catch (error) {
    if (error.code != ZvecErrorCode.alreadyExists) rethrow;
  }
}

IndexParams _zvecIndexParams(String scenario, BenchConfig config) {
  switch (scenario) {
    case 'zvec_flat_fp32':
      return FlatIndexParams(metricType: MetricType.cosine);
    case 'zvec_flat_fp16':
      return FlatIndexParams(
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.fp16,
      );
    case 'zvec_flat_int8':
      return FlatIndexParams(
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.int8,
      );
    case 'zvec_flat_int4':
      return FlatIndexParams(
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.int4,
      );
    case 'zvec_hnsw_fp32':
      return HnswIndexParams(
        m: config.hnswM,
        efConstruction: config.hnswEfConstruction,
        metricType: MetricType.cosine,
      );
    case 'zvec_hnsw_fp16':
      return HnswIndexParams(
        m: config.hnswM,
        efConstruction: config.hnswEfConstruction,
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.fp16,
      );
    case 'zvec_hnsw_int8':
      return HnswIndexParams(
        m: config.hnswM,
        efConstruction: config.hnswEfConstruction,
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.int8,
      );
    case 'zvec_hnsw_int4':
      return HnswIndexParams(
        m: config.hnswM,
        efConstruction: config.hnswEfConstruction,
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.int4,
      );
    case 'zvec_hnsw_rabitq':
      return HnswIndexParams(
        m: config.hnswM,
        efConstruction: config.hnswEfConstruction,
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.rabitq,
      );
    case 'zvec_ivf_fp32':
      return IVFIndexParams(
        nList: config.ivfNlist,
        nIters: 10,
        metricType: MetricType.cosine,
      );
    case 'zvec_ivf_int8':
      return IVFIndexParams(
        nList: config.ivfNlist,
        nIters: 10,
        metricType: MetricType.cosine,
        quantizeType: QuantizeType.int8,
      );
  }
  throw ArgumentError('未知 zvec 场景 $scenario');
}

QueryParams? _zvecQueryParams(String scenario, BenchConfig config) {
  if (scenario.startsWith('zvec_hnsw')) {
    return HnswQueryParams(ef: config.hnswEf);
  }
  if (scenario.startsWith('zvec_ivf')) {
    return IVFQueryParams(nprobe: config.ivfNprobe);
  }
  return null;
}

/// [QueryParams] 是抽象类，销毁方法只在具体类型上，这里按类型分派。
void _destroyQueryParams(QueryParams? params) {
  switch (params) {
    case HnswQueryParams():
      params.destroy();
    case IVFQueryParams():
      params.destroy();
    case FlatQueryParams():
      params.destroy();
    case null:
      break;
  }
}

Map<String, Object?> _runZvec(
  String scenario,
  BenchConfig config,
  Float32List data,
  Float32List queries,
  List<List<int>> truth,
  String root,
) {
  final dim = config.dim;
  final count = config.vectors;
  final dir = Directory(p.join(root, 'data', scenario));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  // zvec 的 createAndOpen 要求目标路径还不存在，父目录必须先建好。
  dir.parent.createSync(recursive: true);

  final rssBefore = ProcessInfo.currentRss;
  final params = _zvecIndexParams(scenario, config);
  final field = VectorSchema('embedding', dim, indexParams: params);
  final schema = CollectionSchema(name: 'bench', fields: [field]);
  final openWatch = Stopwatch()..start();
  Collection collection;
  try {
    schema.validate();
    collection = Collection.createAndOpen(dir.path, schema);
  } finally {
    schema.destroy();
    field.destroy();
    params.destroy();
  }
  openWatch.stop();

  final insertWatch = Stopwatch()..start();
  const batchSize = 1000;
  for (var start = 0; start < count; start += batchSize) {
    final end = math.min(start + batchSize, count);
    final docs = <Doc>[
      for (var i = start; i < end; i++)
        Doc(id: '$i')
          ..setVector(
            'embedding',
            Float32List.sublistView(data, i * dim, (i + 1) * dim),
          ),
    ];
    final result = collection.upsert(docs);
    for (final doc in docs) {
      doc.destroy();
    }
    if (result.errorCount > 0) {
      throw StateError('写入失败 ${result.errorMessages.take(3).join('; ')}');
    }
  }
  insertWatch.stop();

  final optimizeWatch = Stopwatch()..start();
  collection.optimize();
  optimizeWatch.stop();

  final stats = collection.stats;
  final docCount = stats.docCount;
  stats.destroy();
  final rssAfterInsert = ProcessInfo.currentRss;

  final micros = <int>[];
  final got = <List<int>>[];
  var shortResults = 0;
  final sweep = <Map<String, Object?>>[];

  ({List<int> micros, List<List<int>> got, int shortResults}) runQueries(
    QueryParams? queryParams,
  ) {
    final latencies = <int>[];
    final hits = <List<int>>[];
    var short = 0;
    for (var q = -5; q < config.queries; q++) {
      final index = q < 0 ? -q - 1 : q;
      final base = index * dim;
      final vector = Float32List.fromList(
        Float32List.sublistView(queries, base, base + dim),
      );
      final query = VectorQuery(
        fieldName: 'embedding',
        vector: vector,
        topk: config.topk,
        queryParams: queryParams,
      );
      final watch = Stopwatch()..start();
      final docs = collection.query(query);
      final ids = <int>[];
      for (final doc in docs) {
        final pk = doc.pk;
        if (pk != null) ids.add(int.parse(pk));
      }
      watch.stop();
      query.destroy();
      for (final doc in docs) {
        doc.destroy();
      }
      if (q < 0) continue;
      if (ids.length < config.topk) short++;
      latencies.add(watch.elapsedMicroseconds);
      hits.add(ids);
    }
    return (micros: latencies, got: hits, shortResults: short);
  }

  if (scenario.startsWith('zvec_hnsw') && config.hnswEfs.length > 1) {
    // HNSW 的召回由查询期的 ef 决定，同一份索引多测几档，看延迟与召回的取舍。
    for (final ef in config.hnswEfs) {
      final params = HnswQueryParams(ef: ef);
      final outcome = runQueries(params);
      params.destroy();
      sweep.add({'ef': ef, ..._queryStats(outcome.micros, outcome.got, truth, config)});
      if (ef == config.hnswEfs.first) {
        micros.addAll(outcome.micros);
        got.addAll(outcome.got);
        shortResults = outcome.shortResults;
      }
    }
  } else {
    final queryParams = _zvecQueryParams(scenario, config);
    final outcome = runQueries(queryParams);
    _destroyQueryParams(queryParams);
    micros.addAll(outcome.micros);
    got.addAll(outcome.got);
    shortResults = outcome.shortResults;
  }

  final rssAfterQuery = ProcessInfo.currentRss;
  final diskBytes = _dirSize(dir);

  final closeWatch = Stopwatch()..start();
  collection.close();
  closeWatch.stop();

  final reopenWatch = Stopwatch()..start();
  final reopened = Collection.open(dir.path);
  reopenWatch.stop();
  final reopenParams = _zvecQueryParams(scenario, config);
  final firstQueryWatch = Stopwatch()..start();
  final firstDocs = reopened.query(
    VectorQuery(
      fieldName: 'embedding',
      vector: Float32List.fromList(Float32List.sublistView(queries, 0, dim)),
      topk: config.topk,
      queryParams: reopenParams,
    ),
  );
  firstQueryWatch.stop();
  for (final doc in firstDocs) {
    doc.destroy();
  }
  _destroyQueryParams(reopenParams);
  reopened.close();

  dir.deleteSync(recursive: true);

  return {
    'engine': 'zvec',
    'index': scenario.split('_')[1],
    'quant': scenario.split('_').length > 2 ? scenario.split('_').sublist(2).join('_') : 'none',
    'vectors': count,
    'dim': dim,
    'open_ms': openWatch.elapsedMilliseconds,
    'insert_ms': insertWatch.elapsedMilliseconds,
    'optimize_ms': optimizeWatch.elapsedMilliseconds,
    'doc_count': docCount,
    'disk_mb': (diskBytes / 1048576).toStringAsFixed(1),
    'rss_before_mb': (rssBefore / 1048576).round(),
    'rss_after_insert_mb': (rssAfterInsert / 1048576).round(),
    'rss_after_query_mb': (rssAfterQuery / 1048576).round(),
    'process_peak_rss_mb': (ProcessInfo.maxRss / 1048576).round(),
    'close_ms': closeWatch.elapsedMilliseconds,
    'reopen_ms': reopenWatch.elapsedMilliseconds,
    'first_query_ms': firstQueryWatch.elapsedMilliseconds,
    'short_results': shortResults,
    if (sweep.isNotEmpty) 'ef_sweep': sweep,
    ..._queryStats(micros, got, truth, config),
  };
}

/// sqlite-vec 的三种存储：float32、int8、bit。量化在 SQL 里做，走
/// sqlite-vec 自带的 vec_quantize_int8('unit') 与 vec_quantize_binary()。
class _SqliteSpec {
  const _SqliteSpec(this.type, this.insertExpr, this.queryExpr, this.metric);
  final String type;
  final String insertExpr;
  final String queryExpr;
  final String metric;
}

_SqliteSpec _sqliteSpec(String scenario) {
  switch (scenario) {
    case 'sqlite_f32':
      return const _SqliteSpec('float', '?', '?', ' distance_metric=cosine');
    case 'sqlite_int8':
      return const _SqliteSpec(
        'int8',
        "vec_quantize_int8(?, 'unit')",
        "vec_quantize_int8(?, 'unit')",
        ' distance_metric=cosine',
      );
    case 'sqlite_bit':
      return const _SqliteSpec(
        'bit',
        'vec_quantize_binary(?)',
        'vec_quantize_binary(?)',
        '',
      );
  }
  throw ArgumentError('未知 sqlite-vec 场景 $scenario');
}

Map<String, Object?> _runSqlite(
  String scenario,
  BenchConfig config,
  Float32List data,
  Float32List queries,
  List<List<int>> truth,
  String root,
) {
  loadSqliteVec();
  final dim = config.dim;
  final count = config.vectors;
  final spec = _sqliteSpec(scenario);
  final dir = Directory(p.join(root, 'data'))..createSync(recursive: true);
  final file = File(p.join(dir.path, '$scenario.db'));
  if (file.existsSync()) file.deleteSync();

  final rssBefore = ProcessInfo.currentRss;
  var db = sqlite3.open(file.path);
  db.execute('PRAGMA journal_mode = OFF');
  db.execute('PRAGMA synchronous = OFF');
  db.execute(
    'CREATE VIRTUAL TABLE v USING vec0(embedding ${spec.type}[$dim]${spec.metric})',
  );

  final insertWatch = Stopwatch()..start();
  final statement = db.prepare(
    'INSERT INTO v(rowid, embedding) VALUES (?, ${spec.insertExpr})',
  );
  db.execute('BEGIN');
  for (var i = 0; i < count; i++) {
    final offset = data.offsetInBytes + i * dim * 4;
    statement.execute([
      i,
      Uint8List.view(data.buffer, offset, dim * 4),
    ]);
  }
  db.execute('COMMIT');
  statement.close();
  insertWatch.stop();

  final rssAfterInsert = ProcessInfo.currentRss;

  final queryStatement = db.prepare(
    'SELECT rowid, distance FROM v WHERE embedding MATCH ${spec.queryExpr} '
    'AND k = ${config.topk} ORDER BY distance',
  );
  final micros = <int>[];
  final got = <List<int>>[];
  var shortResults = 0;
  for (var q = -5; q < config.queries; q++) {
    final index = q < 0 ? -q - 1 : q;
    final offset = queries.offsetInBytes + index * dim * 4;
    final blob = Uint8List.view(queries.buffer, offset, dim * 4);
    final watch = Stopwatch()..start();
    final rows = queryStatement.select([blob]);
    final ids = <int>[for (final row in rows) row['rowid'] as int];
    watch.stop();
    if (q < 0) continue;
    if (ids.length < config.topk) shortResults++;
    micros.add(watch.elapsedMicroseconds);
    got.add(ids);
  }
  queryStatement.close();
  final rssAfterQuery = ProcessInfo.currentRss;

  // 只统计这一个库文件（及其 WAL、SHM），不统计同目录下其他场景留下的文件。
  var diskBytes = 0;
  for (final suffix in ['', '-wal', '-shm']) {
    final part = File('${file.path}$suffix');
    if (part.existsSync()) diskBytes += part.lengthSync();
  }
  db.close();

  final reopenWatch = Stopwatch()..start();
  db = sqlite3.open(file.path);
  reopenWatch.stop();
  final firstWatch = Stopwatch()..start();
  db
      .select(
        'SELECT rowid FROM v WHERE embedding MATCH ${spec.queryExpr} '
        'AND k = ${config.topk} ORDER BY distance',
        [Uint8List.view(queries.buffer, queries.offsetInBytes, dim * 4)],
      )
      .toList();
  firstWatch.stop();
  db.close();

  file.deleteSync();

  return {
    'engine': 'sqlite-vec',
    'index': 'vec0',
    'quant': spec.type,
    'vectors': count,
    'dim': dim,
    'insert_ms': insertWatch.elapsedMilliseconds,
    'optimize_ms': 0,
    'doc_count': count,
    'disk_mb': (diskBytes / 1048576).toStringAsFixed(1),
    'rss_before_mb': (rssBefore / 1048576).round(),
    'rss_after_insert_mb': (rssAfterInsert / 1048576).round(),
    'rss_after_query_mb': (rssAfterQuery / 1048576).round(),
    'process_peak_rss_mb': (ProcessInfo.maxRss / 1048576).round(),
    'reopen_ms': reopenWatch.elapsedMilliseconds,
    'first_query_ms': firstWatch.elapsedMilliseconds,
    'short_results': shortResults,
    ..._queryStats(micros, got, truth, config),
  };
}

