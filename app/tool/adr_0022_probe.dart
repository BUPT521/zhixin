import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/data/vector/zvec_vector_index.dart';
import 'package:zhixin/domain/rules/embedding.dart';
import 'package:zvec/zvec.dart';

const _dimensions = 1024;
const _chunksPerSource = 4;
const _topK = 20;
const _querySamples = 100;
const _createdAt = '2026-11-16T00:00:00Z';
const _sizes = [2000, 20000];
const _spec = EmbeddingModelSpec(id: 'adr-0022-probe', dim: _dimensions);

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
  int _size = _sizes.last;
  bool _busy = false;
  String _result = '先生成索引，再强行停止并重开本应用。重开后选择同一数量，测量冷打开与检索。';

  @override
  void initState() {
    super.initState();
    final match = RegExp(r'^/adr0022/(2000|20000)/(seed|query)$')
        .firstMatch(widget.launchRoute);
    if (match != null) {
      _size = int.parse(match.group(1)!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(seed: match.group(2) == 'seed');
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
      final size = _size;
      final metrics = await _measureInBackground(
        directory,
        logs,
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
        DropdownButton<int>(
          value: _size,
          items: [
            for (final size in _sizes)
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
  int size, {
  required bool seed,
}) => Isolate.run(() => _measure(directory, logs, size, seed: seed));

/// 用与刷新相同的写入路径测量 zvec 索引：打开、写入、查询、内存与磁盘。
///
/// 打开与写入都走 [ZvecVectorIndex]，引擎参数因此与实际应用一致；探针只改
/// 数据量，不另起一套建表代码。查询分不限定与限定一份材料两种，后者使用
/// [MaterialVectorPrefilter]，与检索服务生成的预过滤相同。
Map<String, Object> _measure(
  String directory,
  String logs,
  int size, {
  required bool seed,
}) {
  final dataset = Directory(path.join(directory, 'zvec-$size'));
  if (seed) {
    if (dataset.existsSync()) dataset.deleteSync(recursive: true);
    dataset.createSync(recursive: true);
  } else if (!dataset.existsSync()) {
    throw StateError('请先生成对应的索引');
  }

  final baselineRss = ProcessInfo.currentRss;
  final startupPeakRss = ProcessInfo.maxRss;
  final coldOpen = !_engineInitialized();
  final openWatch = Stopwatch()..start();
  final index = ZvecVectorIndex.open(
    rootPath: dataset.path,
    spec: _spec,
    logDirectory: logs,
  );
  openWatch.stop();

  final metrics = <String, Object>{
    'engine': 'zvec',
    'vectors': size,
    'dimensions': _dimensions,
    'phase': seed ? 'seed' : 'open_and_query',
    'open_us': openWatch.elapsedMicroseconds,
    'cold_zvec_open': coldOpen,
    'baseline_rss_bytes': baselineRss,
    'startup_peak_rss_bytes': startupPeakRss,
  };
  try {
    if (seed) {
      metrics.addAll(_seed(index, size));
    } else {
      if (index.entryCount != size) throw StateError('已有索引未写完');
      metrics['all_query'] = _query(index, scoped: false);
      metrics['material_query'] = _query(index, scoped: true);
    }
    if (index.entryCount != size) {
      throw StateError('索引中应有 $size 条向量，实际有 ${index.entryCount} 条');
    }
    final peakRss = ProcessInfo.maxRss;
    metrics['process_peak_rss_bytes'] = peakRss;
    // 进程历史峰值可能包含启动峰值，所得增量为本次操作峰值增量的上界。
    metrics['rss_delta_upper_bound_bytes'] = math.max(0, peakRss - baselineRss);
  } finally {
    final closeWatch = Stopwatch()..start();
    index.close();
    closeWatch.stop();
    metrics['close_us'] = closeWatch.elapsedMicroseconds;
  }
  metrics['disk_bytes'] = dataset
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .fold<int>(0, (total, file) => total + file.lengthSync());
  return metrics;
}

bool _engineInitialized() {
  try {
    return Zvec.isInitialized;
  } on Object {
    return false;
  }
}

Map<String, Object> _seed(VectorIndex index, int size) {
  final random = math.Random(22);
  final write = Stopwatch();
  final text = List.filled(40, '知新语义索引试验').join();
  final sources = size ~/ _chunksPerSource;
  for (var source = 0; source < sources; source++) {
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
    index.replaceSource(
      locator: locator,
      sourceVersion: '1',
      chunks: List.filled(_chunksPerSource, text),
      vectors: vectors,
      createdAt: _createdAt,
    );
    write.stop();
  }
  final finish = Stopwatch()..start();
  index.finishRefresh(
    builtAt: DateTime.now().toUtc().toIso8601String(),
    sourceCount: sources,
    writtenEntries: size,
  );
  finish.stop();
  return {
    'write_us': write.elapsedMicroseconds,
    'finish_refresh_us': finish.elapsedMicroseconds,
    'total_write_us': write.elapsedMicroseconds + finish.elapsedMicroseconds,
  };
}

List<double> _vector(math.Random random) => List.generate(
  _dimensions,
  (_) => random.nextDouble() * 2 - 1,
  growable: false,
);

Map<String, Object> _query(VectorIndex index, {required bool scoped}) {
  final random = math.Random(23);
  final samples = <int>[];
  var minHits = _topK;
  for (var sample = -5; sample < _querySamples; sample++) {
    final vector = _vector(random);
    final watch = Stopwatch()..start();
    final hits = index.search(
      vector,
      k: _topK,
      prefilter: scoped ? const MaterialVectorPrefilter('m1') : null,
    );
    watch.stop();
    if (sample >= 0) {
      samples.add(watch.elapsedMicroseconds);
      minHits = math.min(minHits, hits.length);
    }
  }
  samples.sort();
  return {'p50': samples[49], 'p95': samples[94], 'min_hits': minHits};
}
