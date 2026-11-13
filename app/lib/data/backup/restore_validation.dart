import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/schema.dart';
import '../db/schema_objects.dart';
import '../db/raw_executor.dart';
import 'backup_manifest.dart';

/// 在临时库里核对版本、检查结构与必要查询。
///
/// 只接受当前 schema 的包：manifest 与库的 `user_version` 必须一致且等于
/// 当前版本；这里再核对物理完整性、表与字段、外键，以及应用真正会跑的
/// 几条查询。
class StagedRestoreValidator {
  StagedRestoreValidator({required this.factory, required this.schemaVersion});

  final DatabaseFactory factory;
  final int schemaVersion;

  Future<void> validate({
    required String path,
    required int manifestSchemaVersion,
  }) async {
    final actual = await _readUserVersion(path);
    if (actual <= 0) {
      throw const BackupException('恢复校验未通过（版本）：数据包中的数据库没有版本信息');
    }
    if (actual != schemaVersion) {
      throw BackupException('恢复校验未通过（版本）：数据库是 v$actual，当前只接受 v$schemaVersion。');
    }
    if (actual != manifestSchemaVersion) {
      throw BackupException(
        '恢复校验未通过（版本）：manifest 记录 v$manifestSchemaVersion，'
        '数据库实际是 v$actual，无法确认这份包记录的是同一份数据。',
      );
    }

    await _verifyReadOnlyObjects(path);
    await _quickCheck(path);
    final db = await _open(path);
    try {
      await _verifyStructure(db);
      await _verifyForeignKey(db);
      await _verifyBusinessQueries(db);
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  Future<int> _readUserVersion(String path) async {
    Database? db;
    try {
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final rows = await db.rawQuery('PRAGMA user_version');
      final value = rows.isEmpty ? 0 : rows.first.values.first;
      return value is int ? value : 0;
    } catch (error) {
      throw BackupException('恢复校验未通过（版本）：数据包中的数据库无法读取。', detail: '$error');
    } finally {
      await db?.close();
    }
  }

  /// 在按当前程序打开之前核对对象；打开时的初始化会重建触发器，若这时才查，
  /// 包带来的额外对象已经被清理，预检就发现不了。
  Future<void> _verifyReadOnlyObjects(String path) async {
    Database? db;
    try {
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final unexpected = await unexpectedDatabaseObjects(db.raw);
      if (unexpected.isNotEmpty) {
        throw BackupException(
          '恢复校验未通过（对象）：数据包带有当前程序不认识的'
          '${unexpected.take(5).join('、')}${unexpected.length > 5 ? ' 等' : ''}',
        );
      }
    } finally {
      await db?.close();
    }
  }

  Future<void> _quickCheck(String path) async {
    Database? db;
    try {
      db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final rows = await db.rawQuery('PRAGMA quick_check');
      final result = rows.isEmpty ? null : rows.first.values.first;
      if (result != 'ok') {
        throw BackupException('恢复校验未通过（完整性）：数据库检查返回 $result');
      }
    } finally {
      await db?.close();
    }
  }

  Future<RawDatabase> _open(String path) async {
    try {
      return await openZhixinDatabase(path: path);
    } catch (error) {
      throw BackupException('恢复校验未通过（打开）：打开数据包中的数据库时失败。', detail: '$error');
    }
  }

  Future<void> _verifyStructure(RawDatabase db) async {
    final versionRows = await db.rawQuery('PRAGMA user_version');
    final version = versionRows.isEmpty ? 0 : versionRows.first.values.first;
    if (version != schemaVersion) {
      throw BackupException('恢复校验未通过（版本）：打开后的库是 v$version，应当是 v$schemaVersion');
    }

    final unexpected = await unexpectedDatabaseObjects(db);
    if (unexpected.isNotEmpty) {
      throw BackupException(
        '恢复校验未通过（对象）：数据包带有当前程序不认识的'
        '${unexpected.take(5).join('、')}${unexpected.length > 5 ? ' 等' : ''}',
      );
    }

    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final present = {for (final row in tableRows) row['name']! as String};
    for (final table in schemaTableNames()) {
      if (!present.contains(table)) {
        throw BackupException('恢复校验未通过（表结构）：数据包缺少表 $table');
      }
    }

    final metaRows = await db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['schema_version'],
      limit: 1,
    );
    if (metaRows.isEmpty ||
        metaRows.first['value'] != schemaVersion.toString()) {
      throw BackupException(
        '恢复校验未通过（表结构）：app_meta.schema_version 与 v$schemaVersion 不一致',
      );
    }

    for (final entry in requiredColumns.entries) {
      final info = await db.rawQuery('PRAGMA table_info(${entry.key})');
      final columns = {for (final row in info) row['name']! as String};
      for (final column in entry.value) {
        if (!columns.contains(column)) {
          throw BackupException('恢复校验未通过（表结构）：${entry.key} 缺少字段 $column');
        }
      }
    }
  }

  Future<void> _verifyForeignKey(RawDatabase db) async {
    final rows = await db.rawQuery('PRAGMA foreign_key_check');
    if (rows.isEmpty) return;
    final first = rows.first;
    throw BackupException('恢复校验未通过（外键）：${first['table']} 的引用在数据包里找不到对应记录');
  }

  Future<void> _verifyBusinessQueries(RawDatabase db) async {
    try {
      final profile = await db.rawQuery(
        'SELECT id, day_cutoff_hour FROM profile WHERE id = 1',
      );
      if (profile.isEmpty) {
        throw const BackupException('恢复校验未通过（必要查询）：缺少 profile 主记录');
      }
      final cutoff = profile.first['day_cutoff_hour'];
      if (cutoff is! int || cutoff < 0 || cutoff > 6) {
        throw BackupException(
          '恢复校验未通过（必要查询）：day_cutoff_hour 超出 0–6，收到 $cutoff',
        );
      }

      await db.rawQuery('''
        SELECT a.id FROM attempt a
        JOIN conversation c ON c.id = a.conversation_id
        WHERE a.submitted_at IS NOT NULL
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT b.id FROM schedule_block b
        JOIN plan_item p ON p.id = b.plan_item_id
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT m.id FROM memory m
        JOIN profile p ON p.id = 1
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT g.id FROM learning_goal g
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT c.id FROM conversation c
        JOIN message m ON m.conversation_id = c.id
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT c.id FROM conversation c
        WHERE EXISTS (SELECT 1 FROM attempt a WHERE a.conversation_id = c.id)
          AND EXISTS (
            SELECT 1 FROM message m
            WHERE m.conversation_id = c.id AND m.role = 'user'
          )
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT p.id FROM plan_item p
        LEFT JOIN conversation c ON c.id = p.conversation_id
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT mp.id FROM material_page mp
        JOIN material m ON m.id = mp.material_id
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT sp.id FROM study_plan sp
        LEFT JOIN plan_item pi ON pi.study_plan_id = sp.id
        LIMIT 1
      ''');
      await db.rawQuery('''
        SELECT a.id FROM assessment a
        JOIN attempt t ON t.id = a.attempt_id
        LIMIT 1
      ''');
    } on BackupException {
      rethrow;
    } catch (error) {
      throw BackupException('恢复校验未通过（必要查询）：数据包里缺少应用需要的记录。', detail: '$error');
    }
  }
}
