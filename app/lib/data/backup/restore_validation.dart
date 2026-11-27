import '../db/app_database.dart';
import '../db/raw_executor.dart';
import '../db/schema.dart';
import '../db/schema_objects.dart';
import '../revisions/revision_engine.dart' show versionedTableNames;
import 'backup_manifest.dart';

/// 暂存库校验发现的第一处问题；[category] 用来说明是哪一类检查。
typedef StagedValidationProblem = ({String category, String detail});

/// 版本化业务表的行数；两处预检与恢复后的核对共用这一份统计。
///
/// 只比行数，不比内容：包里的库在替换或复制时被截断、或打开时落到新建的空库，
/// 行数变少就能发现。
Future<Map<String, int>> versionedRowCounts(RawExecutor db) async {
  final counts = <String, int>{};
  for (final table in versionedTableNames) {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    counts[table] = (rows.first['n'] as int?) ?? 0;
  }
  return counts;
}

/// 暂存库校验：数据包恢复预检与版本库备份（导出前、恢复前）共用这一套检查。
///
/// 只读检查必须在按当前结构打开之前做：打开会重建采集触发器与索引，包带来的
/// 额外对象会被清理掉，预检就发现不了。打开之后只再核对表、列与版本记录。
/// 这里只负责判断并返回问题，具体抛哪种异常由调用方决定：数据包恢复抛
/// [BackupException]，版本库备份的发布与预检分别抛 [StateError] 与
/// [FormatException]。
class StagedDatabaseValidator {
  const StagedDatabaseValidator({required this.schemaVersion});

  final int schemaVersion;

  /// 只读核对版本、对象白名单、物理完整性与外键。
  Future<StagedValidationProblem?> readOnlyProblem(
    String path, {
    int? manifestSchemaVersion,
  }) async {
    RawDatabase db;
    try {
      db = openReadOnlyDatabase(path);
    } catch (_) {
      return (category: '版本', detail: '数据库无法读取');
    }
    try {
      final versionRows = await db.rawQuery('PRAGMA user_version');
      final actual = versionRows.isEmpty ? 0 : versionRows.first.values.first;
      if (actual is! int || actual <= 0) {
        return (category: '版本', detail: '数据库没有版本信息');
      }
      if (actual != schemaVersion) {
        return (category: '版本', detail: '数据库是 v$actual，当前只接受 v$schemaVersion。');
      }
      if (manifestSchemaVersion != null && actual != manifestSchemaVersion) {
        return (
          category: '版本',
          detail:
              'manifest 记录 v$manifestSchemaVersion，数据库实际是 v$actual，'
              '无法确认这份包记录的是同一份数据。',
        );
      }

      final unexpected = await unexpectedDatabaseObjects(db);
      if (unexpected.isNotEmpty) {
        return (
          category: '对象',
          detail: '数据库带有当前程序不认识的${_joinObjects(unexpected)}',
        );
      }

      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final result = integrity.isEmpty ? null : integrity.first.values.first;
      if (result != 'ok') {
        return (category: '完整性', detail: '数据库检查返回 $result');
      }

      final foreignKey = await db.rawQuery('PRAGMA foreign_key_check');
      if (foreignKey.isNotEmpty) {
        final first = foreignKey.first;
        return (category: '外键', detail: '${first['table']} 的引用在数据库里找不到对应记录');
      }
      return null;
    } finally {
      await db.close();
    }
  }

  /// 按当前结构打开之后核对版本、对象白名单、表、必需列与版本记录。
  Future<StagedValidationProblem?> openedProblem(RawDatabase db) async {
    final versionRows = await db.rawQuery('PRAGMA user_version');
    final version = versionRows.isEmpty ? 0 : versionRows.first.values.first;
    if (version != schemaVersion) {
      return (category: '版本', detail: '打开后的库是 v$version，应当是 v$schemaVersion');
    }

    final unexpected = await unexpectedDatabaseObjects(db);
    if (unexpected.isNotEmpty) {
      return (
        category: '对象',
        detail: '数据库带有当前程序不认识的${_joinObjects(unexpected)}',
      );
    }

    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final present = {for (final row in tableRows) row['name']! as String};
    for (final table in schemaTableNames()) {
      if (!present.contains(table)) {
        return (category: '表结构', detail: '数据库缺少表 $table');
      }
    }

    final metaRows = await db.rawQuery(
      'SELECT value FROM app_meta WHERE key = ? LIMIT 1',
      ['schema_version'],
    );
    if (metaRows.isEmpty ||
        metaRows.first['value'] != schemaVersion.toString()) {
      return (
        category: '表结构',
        detail: 'app_meta.schema_version 与 v$schemaVersion 不一致',
      );
    }

    for (final entry in requiredColumns.entries) {
      final info = await db.rawQuery('PRAGMA table_info("${entry.key}")');
      final columns = {for (final row in info) row['name']! as String};
      for (final column in entry.value) {
        if (!columns.contains(column)) {
          return (category: '表结构', detail: '${entry.key} 缺少字段 $column');
        }
      }
    }
    return null;
  }
}

/// 资源校验：数据库引用的附件必须都能读出且哈希一致，返回缺失说明。
///
/// 导出、版本库备份与预检共用这一份判断，空表示全部可读。
String? assetProblem(List<String> missing) {
  if (missing.isEmpty) return null;
  return '数据库引用的 ${missing.length} 个附件缺失或校验失败'
      '（${missing.take(3).join('、')}${missing.length > 3 ? ' 等' : ''}）';
}

String _joinObjects(List<String> names) =>
    '${names.take(5).join('、')}${names.length > 5 ? ' 等' : ''}';

/// 在暂存处校验数据包里的库：先只读核对，再按当前结构打开核对。
///
/// 恢复入口只接受当前 schema 的包：manifest 与库的 `user_version` 必须一致且
/// 等于当前版本；这里再核对物理完整性、对象白名单、表与字段和外键。
class StagedRestoreValidator {
  StagedRestoreValidator({required this.schemaVersion});

  final int schemaVersion;

  late final _validator = StagedDatabaseValidator(schemaVersion: schemaVersion);

  Future<void> validate({
    required String path,
    required int manifestSchemaVersion,
  }) async {
    final readOnly = await _validator.readOnlyProblem(
      path,
      manifestSchemaVersion: manifestSchemaVersion,
    );
    if (readOnly != null) {
      throw BackupException('恢复校验未通过（${readOnly.category}）：${readOnly.detail}');
    }
    final db = await _open(path);
    try {
      final opened = await _validator.openedProblem(db);
      if (opened != null) {
        throw BackupException('恢复校验未通过（${opened.category}）：${opened.detail}');
      }
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  Future<RawDatabase> _open(String path) async {
    try {
      return await openZhixinDatabase(path: path);
    } catch (error) {
      throw BackupException('恢复校验未通过（打开）：打开数据包中的数据库时失败。', detail: '$error');
    }
  }
}
