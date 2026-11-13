import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/schema.dart';

/// 01 第 4 章的 DDL 是给人看的完整结构，建表语句以 schema.dart 为准。
///
/// 两边各写一份必然漂移，所以这里按表比对建表语句、按索引比对第 6 章的索引：
/// 代码改了而文档没改，或者文档改了而代码没跟，都会在 CI 里失败，提示改哪
/// 一边，而不是让文档慢慢过期。
void main() {
  test('01 第 4 章的建表语句与 schemaStatements() 一致', () {
    final doc = File('../docs/01-ER数据模型.md').readAsStringSync();
    final documented = _byTable(_documentedStatements(doc));
    final actual = _byTable(schemaStatements().map(_compact));

    expect(
      documented.keys.toSet(),
      actual.keys.toSet(),
      reason: '两边建表语句覆盖的表不一致',
    );
    for (final entry in actual.entries) {
      expect(
        documented[entry.key],
        entry.value,
        reason: '${entry.key} 的建表语句不一致，改文档或改 schema.dart，两边只能有一份',
      );
    }
  });

  test('01 第 6 章的索引与 schemaStatements() 一致', () {
    final doc = File('../docs/01-ER数据模型.md').readAsStringSync();
    final documented = _documentedIndexes(doc);
    final actual = _indexes(schemaStatements());

    expect(documented.difference(actual), isEmpty, reason: '文档里有、代码里没有的索引');
    expect(actual.difference(documented), isEmpty, reason: '代码里有、文档里没有的索引');
  });
}

/// 按表名归并建表语句；顺序不同不算差异，同一张表的内容不同才算。
Map<String, String> _byTable(Iterable<String> statements) {
  final pattern = RegExp(r'^CREATE TABLE IF NOT EXISTS (\w+)');
  return {
    for (final statement in statements)
      if (pattern.firstMatch(statement) case final match?)
        match.group(1)!: statement,
  };
}

/// 取出“## 4. 完整 DDL”下的 sql 代码块，去掉连接设置那几行。
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
    if (compact.isEmpty || compact.startsWith('PRAGMA')) continue;
    statements.add(compact);
  }
  return statements;
}

String _compact(String sql) =>
    sql.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r';\s*$'), '').trim();

/// 代码里的索引：表名与列名按固定写法归并，列修饰（ASC/DESC）不算差异。
Set<String> _indexes(Iterable<String> statements) {
  final pattern = RegExp(
    r'CREATE (?:UNIQUE )?INDEX IF NOT EXISTS \w+\s+ON\s+(\w+)\s*\(([^)]*)\)',
  );
  return {
    for (final statement in statements)
      for (final match in pattern.allMatches(_compact(statement)))
        '${match.group(1)}(${_columns(match.group(2)!)})',
  };
}

/// 第 6 章表格里的索引：单元格写成 `表名(列, 列)`，一行可以写多个。
Set<String> _documentedIndexes(String markdown) {
  final section = RegExp(
    r'^## 6\. 索引与典型查询\s*$([\s\S]*?)(?=^## )',
    multiLine: true,
  ).firstMatch(markdown);
  expect(section, isNotNull, reason: '找不到“## 6. 索引与典型查询”一节');
  final table = section!.group(1)!.split('```').first;
  return {
    for (final match in RegExp(r'`(\w+)\(([^)]*)\)`').allMatches(table))
      '${match.group(1)}(${_columns(match.group(2)!)})',
  };
}

String _columns(String raw) => raw
    .split(',')
    .map((column) => column.replaceAll(RegExp(r'\s+(ASC|DESC)'), '').trim())
    .where((column) => column.isNotEmpty)
    .join(',');
