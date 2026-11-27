/// 字面命中的 SQL 条件：查询原文出现在这一列里，且命中之后不紧接数字、ASCII
/// 字母或下划线。
///
/// 与 `domain/rules/search_terms.dart` 的 `literalMatchIndex` 是同一条边界规则的
/// 两种写法，一处给 SQL、一处给内存里的材料列表：`例 3-2` 因此不会命中
/// `例 3-20`，`a_b` 不会命中 `a_bc`。改一处要同时改另一处。
///
/// 每个条件带三个绑定参数：查询原文两次与它的长度。命中落在文本末尾时
/// `substr` 返回空串，空串不会被 GLOB 排除，与“后面没有字符”的判断一致。
({String sql, List<Object> values}) literalMatchSql(
  String column,
  String text,
) => (
  sql:
      'instr(lower($column), lower(?)) > 0 AND '
      "COALESCE(substr($column, instr(lower($column), lower(?)) "
      "+ length(?), 1), '') NOT GLOB '[0-9A-Za-z_]'",
  values: <Object>[text, text, text],
);

/// 多列任一命中：各列的条件用 OR 连接，整体加括号。
///
/// 绑定参数的顺序与 SQL 里占位符出现的先后一致，逐列拼接。
({String sql, List<Object> values}) literalMatchAny(
  List<String> columns,
  String text,
) {
  final parts = <String>[];
  final values = <Object>[];
  for (final column in columns) {
    final match = literalMatchSql(column, text);
    parts.add(match.sql);
    values.addAll(match.values);
  }
  return (sql: '(${parts.join(' OR ')})', values: values);
}
