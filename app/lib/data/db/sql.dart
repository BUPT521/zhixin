/// 动态表名的 SQL 只在这一点组装：字段与表名加引号，值一律走占位符。
///
/// 版本引擎与撤销会按业务表的当前结构读写整行，表名来自运行时；其余仓库使用
/// drift 生成查询。把这一处收口之后，执行器只负责执行语句与读回行，不再提供
/// 按表名和字符串条件拼装语句的接口。
library;

import 'raw_executor.dart';

/// 给表名或字段名加引号；名称来自代码常量或数据库结构，不接受用户输入。
String quoteSqlName(String name) => '"${name.replaceAll('"', '""')}"';

String _placeholders(int count) => List.filled(count, '?').join(', ');

/// 按列、条件与排序读取；条件里的值走参数，不拼进 SQL。
Future<List<Map<String, Object?>>> selectRows(
  RawExecutor executor,
  String table, {
  List<String>? columns,
  String? where,
  List<Object?>? whereArgs,
  String? orderBy,
  int? limit,
  int? offset,
}) {
  final buffer = StringBuffer('SELECT ');
  buffer.write(columns == null ? '*' : columns.map(quoteSqlName).join(', '));
  buffer.write(' FROM ${quoteSqlName(table)}');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  if (orderBy != null && orderBy.trim().isNotEmpty) {
    buffer.write(' ORDER BY $orderBy');
  }
  if (limit != null) buffer.write(' LIMIT $limit');
  if (offset != null) {
    if (limit == null) buffer.write(' LIMIT -1');
    buffer.write(' OFFSET $offset');
  }
  return executor.rawQuery(buffer.toString(), whereArgs);
}

/// 插入一行并返回执行结果；业务表主键由调用方在 [values] 里给出，不再取新行
/// 编号（ADR-0018）。[replace] 覆盖同主键旧行，[ignore] 跳过冲突。
Future<int> insertRow(
  RawExecutor executor,
  String table,
  Map<String, Object?> values, {
  bool replace = false,
  bool ignore = false,
}) async {
  final name = quoteSqlName(table);
  final prefix = replace
      ? 'INSERT OR REPLACE'
      : ignore
      ? 'INSERT OR IGNORE'
      : 'INSERT';
  if (values.isEmpty) {
    return executor.execute('$prefix INTO $name DEFAULT VALUES');
  }
  final columns = values.keys.map(quoteSqlName).join(', ');
  return executor.execute(
    '$prefix INTO $name ($columns) VALUES (${_placeholders(values.length)})',
    values.values.toList(growable: false),
  );
}

/// 按条件更新若干字段；[where] 为空时更新整表，占位符由 [whereArgs] 提供。
Future<void> updateRow(
  RawExecutor executor,
  String table,
  Map<String, Object?> values, {
  String? where,
  List<Object?>? whereArgs,
}) async {
  if (values.isEmpty) return;
  final assignments = values.keys
      .map((column) => '${quoteSqlName(column)} = ?')
      .join(', ');
  final buffer = StringBuffer('UPDATE ${quoteSqlName(table)} SET $assignments');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  await executor.execute(buffer.toString(), [...values.values, ...?whereArgs]);
}

/// 按条件删除；[where] 为空时删除整表。
Future<void> deleteRows(
  RawExecutor executor,
  String table, {
  String? where,
  List<Object?>? whereArgs,
}) async {
  final buffer = StringBuffer('DELETE FROM ${quoteSqlName(table)}');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  await executor.execute(buffer.toString(), whereArgs);
}
