import 'dart:io';

import 'package:drift/native.dart';

import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../revisions/revision_engine.dart';
import 'drift/app_database.dart';
import 'drift/drift_raw.dart';
import 'raw_executor.dart';

/// 库文件与 schema 版本。库文件放在应用私有目录，导出时整份复制。
const String zhixinDbFileName = 'zhixin.db';
const int zhixinSchemaVersion = 26;

/// 与库文件同名的附属文件：回滚日志、WAL 与共享内存。
const List<String> zhixinDbSideFiles = ['-journal', '-wal', '-shm'];

/// 打开（必要时新建）本地库。
///
/// 表结构由 drift 的 [AppDatabase] 建立；版本与当前结构不一致时清空所有表
/// 并按当前结构重建：开发期只有可丢弃的测试数据，旧库整体重建，不进入升级
/// 路径（ADR-0002）。版本引擎初始化时安装版本采集和关键词索引的触发器。
Future<RawDatabase> openZhixinDatabase({
  required String path,
  Clock clock = systemClock,
}) async {
  final app = AppDatabase(NativeDatabase(File(path)));
  final raw = DriftRawDatabase(app);
  // 触发一次查询，让 drift 完成建表与迁移。
  await raw.rawQuery('PRAGMA user_version');
  await RevisionEngine(clock: clock)
      .initialize(raw, seed: () => _seed(raw, zhixinSchemaVersion, clock));
  return raw;
}

Future<void> _seed(RawDatabase db, int version, Clock clock) async {
  final now = formatDateTime(clock());
  await db.insert('app_meta', {
    'key': 'schema_version',
    'value': '$version',
    'updated_at': now,
  }, conflictAlgorithm: ConflictAction.replace);
  await db.insert('profile', {
    'id': 1,
    'day_cutoff_hour': 4,
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAction.ignore);
}
