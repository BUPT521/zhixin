import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/drift/drift_raw.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

/// 在 Dart VM 上开一份 drift 内存库；每个用例各自一份，互不影响。
Future<RawDatabase> openTestDb() async {
  final app = AppDatabase.memory();
  final raw = DriftRawDatabase(app);
  await raw.insert('app_meta', {
    'key': 'schema_version',
    'value': '26',
    'updated_at': '2026-11-10 10:00:00',
  }, conflictAlgorithm: ConflictAction.replace);
  await raw.insert('profile', {
    'id': 1,
    'day_cutoff_hour': 4,
    'created_at': '2026-11-10 10:00:00',
    'updated_at': '2026-11-10 10:00:00',
  }, conflictAlgorithm: ConflictAction.ignore);
  await RevisionEngine().initialize(raw);
  return raw;
}

/// 带数据版本的测试库：每次写入形成提交，回执与撤销读提交历史。
///
/// 与生产装配一致：仓库拿 [GuardedDatabase]，图片缓存指向临时目录。
class TestRig {
  TestRig({
    required this.raw,
    required this.db,
    required this.engine,
    required this.revisions,
    required this.filesDir,
  });

  final RawDatabase raw;
  final GuardedDatabase db;
  final RevisionEngine engine;
  final RevisionService revisions;
  final String filesDir;

  Future<void> close() => raw.close();
}

Future<TestRig> openTestRig({
  Clock clock = systemClock,
  Future<void> Function()? onUndoApplied,
  Future<void> Function()? onDataChanged,
  AttachmentCache? cache,
}) async {
  final dir = await Directory.systemTemp.createTemp('zhixin_test_rig');
  final raw = await openTestDb();
  final engine = RevisionEngine(clock: clock);
  final db = GuardedDatabase(
    gate: DatabaseGate(),
    resolve: () => raw,
    revisions: engine,
  );
  final revisions = RevisionService(
    db: db,
    raw: () => raw,
    engine: engine,
    clock: clock,
    cache: cache ?? AttachmentCache(filesDir: () => dir.path),
    onUndoApplied: onUndoApplied,
    onDataChanged: onDataChanged,
  );
  return TestRig(
    raw: raw,
    db: db,
    engine: engine,
    revisions: revisions,
    filesDir: dir.path,
  );
}
