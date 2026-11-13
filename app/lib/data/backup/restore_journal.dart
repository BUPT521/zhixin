import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 恢复阶段；只有 `replacing` 与 `reopening` 要在中断后回滚。
enum RestoreStage {
  preparing,
  snapshotting,
  replacing,
  reopening,
  committed,
  settled;

  static RestoreStage? fromName(String value) {
    for (final stage in RestoreStage.values) {
      if (stage.name == value) return stage;
    }
    return null;
  }
}

class RestoreJournalCorruptException implements Exception {
  const RestoreJournalCorruptException(this.path, this.reason);

  final String path;
  final Object reason;

  @override
  String toString() => '恢复阶段记录损坏（$path）：$reason';
}

/// 一次未完成的恢复。恢复失败或进程中断时，下次启动据此回到恢复前的数据。
class RestoreJournalEntry {
  const RestoreJournalEntry({
    required this.stage,
    required this.rollbackDir,
    required this.startedAt,
    required this.manifestSchemaVersion,
  });

  final RestoreStage stage;
  final String rollbackDir;
  final String startedAt;
  final int manifestSchemaVersion;

  bool get mayHaveReplacedData =>
      stage == RestoreStage.replacing || stage == RestoreStage.reopening;

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'rollback_dir': rollbackDir,
    'started_at': startedAt,
    'manifest_schema_version': manifestSchemaVersion,
  };

  static RestoreJournalEntry? fromJson(Map<String, Object?> json) {
    final stage = json['stage'];
    final rollbackDir = json['rollback_dir'];
    final startedAt = json['started_at'];
    final version = json['manifest_schema_version'];
    if (stage is! String ||
        rollbackDir is! String ||
        rollbackDir.isEmpty ||
        startedAt is! String ||
        version is! int) {
      return null;
    }
    final parsedStage = RestoreStage.fromName(stage);
    if (parsedStage == null) return null;
    return RestoreJournalEntry(
      stage: parsedStage,
      rollbackDir: rollbackDir,
      startedAt: startedAt,
      manifestSchemaVersion: version,
    );
  }
}

/// 恢复阶段记录（01 第 7 章）：每个阶段写入新的文件，再以同目录重命名发布。
///
/// 保留前一份记录直到新文件发布后，进程中断时可以读取最后一个完整阶段；
/// 完成或回滚时先写入 `settled`，再删除旧记录与标记。
class RestoreJournal {
  RestoreJournal(this.filesDir);

  final String filesDir;

  static const String fileName = '.restore-journal.json';
  static const String _versionedPrefix = '.restore-journal.';
  static const String _temporaryPrefix = '.restore-journal.tmp-';

  String get path => p.join(filesDir, fileName);

  Future<RestoreJournalEntry?> read() async => (await _latest())?.entry;

  Future<void> write(RestoreJournalEntry entry) async {
    final directory = Directory(filesDir);
    await directory.create(recursive: true);
    final previous = await _latest();
    final generation = (previous?.generation ?? 0) + 1;
    final suffix = generation.toString().padLeft(20, '0');
    final published = File(p.join(filesDir, '$_versionedPrefix$suffix.json'));
    final temporary = File(p.join(filesDir, '$_temporaryPrefix$suffix'));
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(entry.toJson()),
        flush: true,
      );
      // 目标文件名唯一，因此 rename 不需要先删除当前有效记录。
      await temporary.rename(published.path);
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // 保留临时文件不会改变当前阶段；清理时再删除。
      }
      rethrow;
    }
    await _deleteOlderThan(generation);
  }

  Future<void> clear() async {
    final current = await _latest();
    if (current != null) {
      await write(
        RestoreJournalEntry(
          stage: RestoreStage.settled,
          rollbackDir: current.entry!.rollbackDir,
          startedAt: current.entry!.startedAt,
          manifestSchemaVersion: current.entry!.manifestSchemaVersion,
        ),
      );
    }

    final files = await _journalFiles(includeTemporary: true);
    files.sort((a, b) => a.generation.compareTo(b.generation));
    final latest = files.isEmpty ? null : files.last;
    for (final stored in files) {
      if (identical(stored, latest)) continue;
      await stored.file.delete();
    }
    if (latest != null) await latest.file.delete();
  }

  Future<_StoredJournal?> _latest() async {
    final files = await _journalFiles();
    if (files.isEmpty) return null;
    files.sort((a, b) => a.generation.compareTo(b.generation));
    final stored = files.last;
    try {
      final decoded = jsonDecode(await stored.file.readAsString());
      final entry = decoded is Map<String, Object?>
          ? RestoreJournalEntry.fromJson(decoded)
          : null;
      if (entry == null) {
        throw const FormatException('字段缺失或阶段值无效');
      }
      return _StoredJournal(stored.generation, stored.file, entry);
    } catch (error) {
      throw RestoreJournalCorruptException(stored.file.path, error);
    }
  }

  Future<List<_StoredJournal>> _journalFiles({
    bool includeTemporary = false,
  }) async {
    final directory = Directory(filesDir);
    if (!await directory.exists()) return [];
    final files = <_StoredJournal>[];
    final pattern = RegExp(r'^\.restore-journal\.(\d{20})\.json$');
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == fileName) {
        files.add(_StoredJournal(0, entity, null));
        continue;
      }
      final match = pattern.firstMatch(name);
      if (match != null) {
        files.add(_StoredJournal(int.parse(match.group(1)!), entity, null));
      } else if (includeTemporary && name.startsWith(_temporaryPrefix)) {
        files.add(_StoredJournal(-1, entity, null));
      }
    }
    return files;
  }

  Future<void> _deleteOlderThan(int generation) async {
    final files = await _journalFiles();
    for (final stored in files) {
      if (stored.generation >= generation) continue;
      try {
        await stored.file.delete();
      } catch (_) {
        // 最新阶段已发布，残留旧记录会在后续阶段或清理时删除。
      }
    }
  }
}

class _StoredJournal {
  const _StoredJournal(this.generation, this.file, this.entry);

  final int generation;
  final File file;
  final RestoreJournalEntry? entry;
}
