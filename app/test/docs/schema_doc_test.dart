import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/schema.dart';

/// 01 第 4 章的 DDL 是给人看的完整结构，建表语句以 schema.dart 为准。
///
/// 两边各写一份必然漂移，所以这里逐条比对建表语句：代码改了而文档没改，或者
/// 文档改了而代码没跟，都会在 CI 里失败，提示改哪一边，而不是让文档慢慢过期。
/// 索引与触发器写在…01 第 6 章，按名称列举，不在逐条比对的范围里。
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
