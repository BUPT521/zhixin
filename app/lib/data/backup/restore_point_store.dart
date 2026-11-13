import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/rules/time_policy.dart';

/// 一份恢复点：整库恢复之前自动保存的当前状态。
///
/// [path] 指向一份版本库备份 zip，与恢复入口使用同一种包；[head]、[commitCount]
/// 与 [namedCount] 是保存时的规模，即使没有说明文件也能从文件名与修改时间认出来。
class RestorePoint {
  const RestorePoint({
    required this.path,
    required this.createdAt,
    required this.head,
    required this.commitCount,
    required this.namedCount,
    required this.reason,
    required this.size,
  });

  final String path;
  final DateTime createdAt;
  final int? head;
  final int commitCount;
  final int namedCount;
  final String reason;
  final int size;
}

/// 恢复点存在应用私有目录 `restore_points/`，每份是一个版本库备份 zip 和一份
/// 同名的 json 说明。恢复数据包或恢复点之前先把当前状态写成一份，恢复成功后
/// 仍然保留，最多留 [keep] 份；卸载应用或清空全部记录会一起删除。
///
/// 只碰传入的目录与 [write]，不依赖数据库或界面；恢复流程在独占区里调用
/// [capture]，由调用方提供真正写包的函数。
class RestorePointStore {
  RestorePointStore({
    required this.filesDir,
    this.clock = systemClock,
    this.keep = 5,
  }) : assert(keep > 0, '恢复点至少保留一份');

  final String filesDir;
  final Clock clock;
  final int keep;

  static const String _prefix = 'restore-';
  static const String _suffix = '.zip';
  static const String _partialSuffix = '.partial';

  String get directory => p.join(filesDir, 'restore_points');

  /// 用 [write] 写出一份完整备份，发布之后附上说明并清理超出 [keep] 的旧份。
  ///
  /// 先写到 `.partial` 再改名，写到一半的文件不会出现在列表里；[write] 抛错时
  /// 删掉半成品并原样抛出，调用方据此中止恢复，当前数据不动。
  Future<RestorePoint> capture({
    required Future<void> Function(String outputPath) write,
    required int? head,
    required int commitCount,
    required int namedCount,
    required String reason,
  }) async {
    final now = clock();
    final dir = Directory(directory);
    await dir.create(recursive: true);
    final base = '$_prefix${_stamp(now)}';
    final partial = File(p.join(dir.path, '$base$_partialSuffix'));
    final target = File(p.join(dir.path, '$base$_suffix'));
    try {
      await write(partial.path);
      if (!await partial.exists() || await partial.length() == 0) {
        throw StateError('恢复点没有生成有效文件');
      }
      await partial.rename(target.path);
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {
        // 半成品不在列表里，留着也不影响下一次保存。
      }
      rethrow;
    }

    final point = RestorePoint(
      path: target.path,
      createdAt: now,
      head: head,
      commitCount: commitCount,
      namedCount: namedCount,
      reason: reason,
      size: await target.length(),
    );
    await _writeMeta(point);
    await prune(protect: target.path);
    return point;
  }

  /// 按保存时间倒序返回全部恢复点；说明文件读不出来时退回文件修改时间。
  Future<List<RestorePoint>> list() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return const [];
    final points = <RestorePoint>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(_prefix) || !name.endsWith(_suffix)) continue;
      final stat = await entity.stat();
      final meta = await _readMeta(entity.path);
      points.add(
        RestorePoint(
          path: entity.path,
          createdAt: meta?.createdAt ?? stat.modified,
          head: meta?.head,
          commitCount: meta?.commitCount ?? 0,
          namedCount: meta?.namedCount ?? 0,
          reason: meta?.reason ?? '',
          size: stat.size,
        ),
      );
    }
    points.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : b.path.compareTo(a.path);
    });
    return points;
  }

  Future<Uint8List> read(RestorePoint point) => File(point.path).readAsBytes();

  Future<void> delete(RestorePoint point) async {
    final file = File(point.path);
    if (await file.exists()) await file.delete();
    final meta = File(_metaPath(point.path));
    if (await meta.exists()) await meta.delete();
  }

  /// 只保留最近的 [keep] 份；[protect] 是刚发布的那一份，排序相同也不删它。
  Future<void> prune({String? protect}) async {
    final points = await list();
    if (points.length <= keep) return;
    var kept = points.take(keep).toList(growable: false);
    if (protect != null && kept.every((point) => point.path != protect)) {
      final protected = points.firstWhere(
        (point) => point.path == protect,
        orElse: () => points.last,
      );
      kept = [...kept.take(keep - 1), protected];
    }
    final keepPaths = {for (final point in kept) point.path};
    for (final point in points) {
      if (keepPaths.contains(point.path)) continue;
      await delete(point);
    }
  }

  String _metaPath(String zipPath) => p.setExtension(zipPath, '.json');

  /// 说明文件写不进去不影响备份本身，列表退回文件时间与空规模。
  Future<void> _writeMeta(RestorePoint point) async {
    final meta = {
      'created_at': point.createdAt.toUtc().toIso8601String(),
      'head': point.head,
      'commit_count': point.commitCount,
      'named_count': point.namedCount,
      'reason': point.reason,
    };
    try {
      await File(_metaPath(point.path)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(meta),
        flush: true,
      );
    } catch (_) {
      // 恢复点的包已经发布，这里失败只让列表少显示几行说明。
    }
  }

  Future<_RestorePointMeta?> _readMeta(String zipPath) async {
    try {
      final file = File(_metaPath(zipPath));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final createdAt = DateTime.tryParse('${decoded['created_at']}');
      if (createdAt == null) return null;
      final head = decoded['head'];
      final commitCount = decoded['commit_count'];
      final namedCount = decoded['named_count'];
      final reason = decoded['reason'];
      return _RestorePointMeta(
        createdAt: createdAt.toLocal(),
        head: head is int ? head : null,
        commitCount: commitCount is int ? commitCount : 0,
        namedCount: namedCount is int ? namedCount : 0,
        reason: reason is String ? reason : '',
      );
    } catch (_) {
      return null;
    }
  }

  String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}-'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }
}

class _RestorePointMeta {
  const _RestorePointMeta({
    required this.createdAt,
    required this.head,
    required this.commitCount,
    required this.namedCount,
    required this.reason,
  });

  final DateTime createdAt;
  final int? head;
  final int commitCount;
  final int namedCount;
  final String reason;
}
