import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/data/db/drift/app_database.dart';

/// 01 第 4 章的 DDL 与第 6 章的索引是 drift 建库结果的抄件。
///
/// 表结构与索引以 `app/lib/data/db/drift/tables.dart` 的表类为准：这里打开一份
/// 内存库读 `sqlite_master`，再与文档比对。代码改了而文档没改，或者文档改了
/// 而代码没跟，都会在 CI 里失败，而不是让文档慢慢过期。
void main() {
  late final String doc;
  late final Map<String, String> tables;
  late final Set<String> indexes;

  setUpAll(() async {
    doc = File('../docs/01-ER数据模型.md').readAsStringSync();
    final db = AppDatabase.memory();
    try {
      final rows = await db
          .customSelect(
            "SELECT type, name, sql FROM sqlite_master "
            "WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL",
          )
          .get();
      tables = {
        for (final row in rows)
          if (row.read<String>('type') == 'table')
            row.read<String>('name'): _compact(row.read<String>('sql')),
      };
      indexes = {
        for (final row in rows)
          if (row.read<String>('type') == 'index')
            '${row.read<String>('name')} ${_indexShape(row.read<String>('sql'))}',
      };
    } finally {
      await db.close();
    }
  });

  test('01 开头的数据版本与客户端常量一致', () {
    final match = RegExp(r'当前结构为 schema (\d+)').firstMatch(doc);
    expect(match, isNotNull, reason: '01 开头没有写“当前结构为 schema N”');
    expect(
      int.parse(match!.group(1)!),
      zhixinSchemaVersion,
      reason: '01 的版本号与 zhixinSchemaVersion 不一致',
    );
  });

  test('01 第 4 章的建表语句与表类建出的表一致', () {
    final documented = _byTable(_documentedStatements(doc));

    expect(
      documented.keys.toSet(),
      tables.keys.toSet(),
      reason: '两边建表语句覆盖的表不一致',
    );
    for (final entry in tables.entries) {
      expect(
        documented[entry.key],
        entry.value,
        reason: '${entry.key} 的建表语句与建库结果不一致，改文档或改 tables.dart，两边只能有一份',
      );
    }
  });

  test('01 第 6 章的索引与表类声明的索引一致', () {
    final documented = _documentedIndexes(doc);

    expect(documented.difference(indexes), isEmpty, reason: '文档里有、建库结果里没有的索引');
    expect(indexes.difference(documented), isEmpty, reason: '建库结果里有、文档里没有的索引');
  });
}

/// 按表名归并建表语句；顺序不同不算差异，同一张表的内容不同才算。
Map<String, String> _byTable(Iterable<String> statements) {
  final pattern = RegExp(r'^CREATE TABLE (?:IF NOT EXISTS )?"?(\w+)"?');
  return {
    for (final statement in statements)
      if (pattern.firstMatch(statement) case final match?)
        match.group(1)!: statement,
  };
}

/// 取出“## 4. 完整 DDL”下的建表语句；连接设置与种子数据不属于结构。
List<String> _documentedStatements(String markdown) {
  final section = RegExp(
    r'^## 4\. 完整 DDL\s*$([\s\S]*?)(?=^## )',
    multiLine: true,
  ).firstMatch(markdown);
  expect(section, isNotNull, reason: '找不到“## 4. 完整 DDL”一节');
  final block = RegExp(r'```sql\s*\n([\s\S]*?)```')
      .firstMatch(section!.group(1)!);
  expect(block, isNotNull, reason: '“完整 DDL”下没有 sql 代码块');
  final statements = <String>[];
  for (final piece in block!.group(1)!.split(';')) {
    final compact = _compact(piece);
    if (compact.startsWith('CREATE TABLE')) statements.add(compact);
  }
  return statements;
}

/// 第 6 章表格里的索引：一行一个，第一格是索引名，第二格是 `表名(列, 列)`。
Set<String> _documentedIndexes(String markdown) {
  final section = RegExp(
    r'^## 6\. 索引与典型查询\s*$([\s\S]*?)(?=^## )',
    multiLine: true,
  ).firstMatch(markdown);
  expect(section, isNotNull, reason: '找不到“## 6. 索引与典型查询”一节');
  final entries = <String>{};
  for (final line in section!.group(1)!.split('\n')) {
    final cells = line.split('|').map((cell) => cell.trim()).toList();
    if (cells.length < 4) continue;
    final name = RegExp(r'^`(idx_\w+)`$').firstMatch(cells[1])?.group(1);
    final shapeMatch = RegExp(r'^`(\w+)\(([^)]*)\)`$').firstMatch(cells[2]);
    if (name == null || shapeMatch == null) continue;
    final columns = shapeMatch
        .group(2)!
        .split(',')
        .map((column) => column.trim())
        .join(', ');
    entries.add(
      '$name ${shapeMatch.group(1)}($columns)'
      '${line.contains('唯一') ? ' 唯一' : ''}',
    );
  }
  return entries;
}

/// `CREATE [UNIQUE] INDEX <名> ON <表> (<列>)` 里的“表(列)”与唯一标记。
String _indexShape(String sql) {
  final match = RegExp(
    r'CREATE (UNIQUE )?INDEX "?\w+"? ON "?(\w+)"?\s*\(([^)]*)\)',
  ).firstMatch(_compact(sql));
  expect(match, isNotNull, reason: '无法解析索引语句：$sql');
  final columns = match!
      .group(3)!
      .replaceAll('"', '')
      .split(',')
      .map((column) => column.trim())
      .join(', ');
  return '${match.group(2)}($columns)${match.group(1) != null ? ' 唯一' : ''}';
}

String _compact(String sql) => sql
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\(\s+'), '(')
    .replaceAll(RegExp(r'\s+\)'), ')')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim();
