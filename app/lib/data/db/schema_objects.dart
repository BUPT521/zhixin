import 'raw_executor.dart';

import '../revisions/revision_engine.dart';
import 'schema.dart';

/// 当前数据库允许出现的对象；恢复预检与版本库备份共用这一份清单。
///
/// 版本库备份是整库快照，除了业务表和版本元数据，还会带上打开库时重建的采集
/// 暂存表、索引与触发器。允许随包进入的只有这份清单里的对象；名称不在其中的
/// 表、索引、触发器或视图一律拒绝，避免包在恢复后的第一次写入时执行它带来的
/// SQL。
Set<String> allowedDatabaseTableNames() => {
  ...schemaTableNames(),
  for (final table in versionedTableNames) 'rev_stage_$table',
};

Set<String> allowedDatabaseIndexNames() {
  final names = <String>{};
  final pattern = RegExp(
    r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+"?([A-Za-z0-9_]+)"?',
  );
  for (final statement in schemaStatements()) {
    final match = pattern.firstMatch(statement);
    if (match != null) names.add(match.group(1)!);
  }
  for (final table in versionedTableNames) {
    names.add('idx_rev_stage_${table}_commit');
  }
  return names;
}

Set<String> allowedDatabaseTriggerNames() => {
  for (final table in versionedTableNames)
    for (final operation in const ['insert', 'update', 'delete'])
      'rev_capture_${table}_$operation',
};

/// 列出不在允许清单里的数据库对象；空表示结构与当前程序一致。
Future<List<String>> unexpectedDatabaseObjects(RawExecutor db) async {
  final rows = await db.rawQuery(
    "SELECT type, name FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite_%' "
    "AND type IN ('table', 'index', 'trigger', 'view')",
  );
  final tables = allowedDatabaseTableNames();
  final indexes = allowedDatabaseIndexNames();
  final triggers = allowedDatabaseTriggerNames();
  final unexpected = <String>[];
  for (final row in rows) {
    final type = row['type']?.toString();
    final name = row['name']?.toString();
    if (type == null || name == null) continue;
    final allowed = switch (type) {
      'table' => tables.contains(name),
      'index' => indexes.contains(name),
      'trigger' => triggers.contains(name),
      'view' => false,
      _ => false,
    };
    if (!allowed) {
      final label = switch (type) {
        'table' => '表',
        'index' => '索引',
        'trigger' => '触发器',
        'view' => '视图',
        _ => type,
      };
      unexpected.add('$label $name');
    }
  }
  return unexpected;
}
