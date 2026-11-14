/// 关键词检索的 FTS5 索引：口径见 ADR-0013。
///
/// 材料页、消息与作答各有一张外部内容表。FTS5 只能对普通列建索引，而二元组要
/// 在写入时按 [bigramsExpression] 算出来，因此索引列 `idx` 不随业务行存放，而由
/// 业务表上的触发器写入；`content=` 仍指向业务表，索引的行号用业务表主键。
/// 查询用 [bigrams] 切出同一套词，交给 `MATCH`，排序用 FTS5 自带的 `bm25()`。
///
/// 触发器必须在版本引擎安装采集触发器之前建立：打开库时引擎会删掉库里所有非
/// `sqlite_` 前缀的触发器再重建，装晚了会被清掉。
library;

import '../../domain/rules/binary_bigrams.dart';
import 'raw_executor.dart';

/// 一张索引表：索引表名、业务表名，以及参与索引的业务列。
class FtsIndex {
  const FtsIndex({
    required this.table,
    required this.source,
    required this.columns,
  });

  final String table;
  final String source;
  final List<String> columns;

  String get insertTrigger => 'fts_${table}_ai';
  String get updateTrigger => 'fts_${table}_au';
  String get deleteTrigger => 'fts_${table}_ad';
}

/// 三张索引表；顺序固定，测试与恢复校验都按这份清单核对。
const List<FtsIndex> ftsIndexes = [
  FtsIndex(
    table: 'material_page_fts',
    source: 'material_page',
    columns: ['content', 'label'],
  ),
  FtsIndex(table: 'message_fts', source: 'message', columns: ['content']),
  FtsIndex(
    table: 'attempt_fts',
    source: 'attempt',
    columns: ['user_answer', 'solution', 'feedback'],
  ),
];

/// 索引表与 FTS5 影子表的名称：恢复校验与版本采集都不把它们当业务表。
///
/// 外部内容表的影子表是 `_data`、`_idx`、`_docsize` 与 `_config`；正文留在
/// 业务表里，所以没有 `_content`。
Set<String> ftsTableNames() => {
  for (final index in ftsIndexes) ...[
    index.table,
    '${index.table}_data',
    '${index.table}_idx',
    '${index.table}_docsize',
    '${index.table}_config',
  ],
};

/// 三张索引表配套的触发器名称。
Set<String> ftsTriggerNames() => {
  for (final index in ftsIndexes) ...[
    index.insertTrigger,
    index.updateTrigger,
    index.deleteTrigger,
  ],
};

/// 建表与触发器语句；安装与测试共用这一份，重复执行保持幂等。
List<String> ftsStatements() => [
  for (final index in ftsIndexes) ...[
    'CREATE VIRTUAL TABLE IF NOT EXISTS "${index.table}" USING fts5('
        'idx, content="${index.source}", content_rowid="id")',
    ..._triggers(index),
  ],
];

/// 安装三张索引表与触发器；打开库时在建版本采集触发器之前调用。
Future<void> installFtsSchema(RawExecutor db) async {
  for (final statement in ftsStatements()) {
    await db.execute(statement);
  }
}

/// 重建索引：删掉索引内容，再按业务表逐行重算。
///
/// FTS5 自带的 rebuild 会按内容表的原列重算，而这里的索引列存的是切好的二元组，
/// 因此只能自己重放一遍：清空索引，再用同样的切词表达式从业务表写回去。
Future<void> rebuildFtsIndex(RawExecutor db, FtsIndex index) async {
  final value = bigramsExpression('s.${index.columns.first}');
  // 外部内容表不认识普通的 DELETE，用 delete-all 命令清空。
  await db.execute(
    'INSERT INTO "${index.table}"("${index.table}") VALUES(\'delete-all\')',
  );
  await db.execute(
    'INSERT INTO "${index.table}"(rowid, idx) '
    'SELECT s.id, $value FROM "${index.source}" AS s',
  );
}

/// 把一组词拼成 FTS5 查询：每个词加双引号，点号与连字符不会被当成语法。
String ftsQuery(Iterable<String> tokens) =>
    tokens.map((token) => '"${token.replaceAll('"', '""')}"').join(' OR ');

List<String> _triggers(FtsIndex index) {
  final value = bigramsExpression('NEW.${index.columns.first}');
  final old = bigramsExpression('OLD.${index.columns.first}');
  final table = index.table;
  return [
    'CREATE TRIGGER IF NOT EXISTS "${index.insertTrigger}" '
        'AFTER INSERT ON "${index.source}" BEGIN '
        'INSERT INTO "$table"(rowid, idx) VALUES (NEW.id, $value); END',
    // 先按旧值删掉索引行，再按新值写入；外部内容表不认识普通的 DELETE，
    // 只能用 FTS5 的 delete 命令，否则会去业务表核对旧值。
    'CREATE TRIGGER IF NOT EXISTS "${index.updateTrigger}" '
        'AFTER UPDATE OF ${index.columns.join(', ')} ON "${index.source}" '
        'BEGIN INSERT INTO "$table"("$table", rowid, idx) '
        "VALUES('delete', OLD.id, $old); "
        'INSERT INTO "$table"(rowid, idx) VALUES (NEW.id, $value); END',
    'CREATE TRIGGER IF NOT EXISTS "${index.deleteTrigger}" '
        'AFTER DELETE ON "${index.source}" BEGIN '
        'INSERT INTO "$table"("$table", rowid, idx) '
        "VALUES('delete', OLD.id, $old); END",
  ];
}
