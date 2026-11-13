import 'package:sqflite/sqflite.dart';

import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../revisions/revision_engine.dart';
import 'schema.dart';

export '../../domain/rules/attachments.dart' show questionImagesDirName;

/// 库文件与 schema 版本。库文件放在应用私有目录，导出时整份复制。
///
/// 本地库只维护当前结构：打开时版本不一致就清空旧表并按当前结构重建，
/// 不写迁移函数，也不保留旧格式分支（00 第 7 章，01 第 7 章）。
const String zhixinDbFileName = 'zhixin.db';
const int zhixinSchemaVersion = 26;

/// 与库文件同名的附属文件：回滚日志、WAL 与共享内存。
const List<String> zhixinDbSideFiles = ['-journal', '-wal', '-shm'];

/// 打开（必要时新建）本地库。
///
/// 版本与当前结构不一致时清空所有表并按当前结构重建：开发期只有可丢弃的
/// 测试数据，旧库整体重建，不进入升级路径。
Future<Database> openZhixinDatabase({
  required DatabaseFactory factory,
  required String path,
  Clock clock = systemClock,
}) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: zhixinSchemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: (db, version) => _createSchema(db, version, clock),
      onUpgrade: (db, oldVersion, newVersion) =>
          _rebuild(db, newVersion, clock),
      onDowngrade: (db, oldVersion, newVersion) =>
          _rebuild(db, newVersion, clock),
      // 触发器与采集暂存表按实际列生成；打开时重新安装，避免残留旧结构。
      onOpen: (db) => RevisionEngine(clock: clock).initialize(db),
    ),
  );
}

Future<void> _rebuild(Database db, int version, Clock clock) async {
  await _dropAllTables(db);
  await _createSchema(db, version, clock);
}

Future<void> _createSchema(Database db, int version, Clock clock) async {
  for (final statement in schemaStatements()) {
    await db.execute(statement);
  }
  await _seed(db, version, clock);
}

/// 重建前清空所有表。
///
/// 版本变化在事务里执行，`PRAGMA foreign_keys` 不能在事务内关闭，因此按
/// 建表顺序的逆序删除，先删引用方再删被引用方，并用延迟检查兜住顺序不理想
/// 的旧库：删完全部表后没有待检查的引用，提交时不会因为旧表之间的级联或
/// 置空而失败。
Future<void> _dropAllTables(Database db) async {
  await db.execute('PRAGMA defer_foreign_keys = ON');
  final rows = await db.query(
    'sqlite_master',
    columns: ['name', 'type'],
    where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
    orderBy: 'rowid DESC',
  );
  for (final row in rows) {
    final name = row['name']! as String;
    await db.execute('DROP TABLE IF EXISTS "$name"');
  }
}

Future<void> _seed(Database db, int version, Clock clock) async {
  final now = formatDateTime(clock());
  await db.insert('app_meta', {
    'key': 'schema_version',
    'value': '$version',
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('profile', {
    'id': 1,
    'day_cutoff_hour': 4,
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}
