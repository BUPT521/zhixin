/// 检索索引增量刷新使用的一行来源变化。
///
/// `revision_change` 保存的是业务表的行级净变化，索引只关心材料页、消息与作答
/// 三张表；这里把它们换成“这一行还是来源、还是已经不是来源”的两种可能，调用
/// 方按表名与主键重新读出当前来源，删除行则按 [removedRow] 还原来源定位。
class SemanticRowChange {
  const SemanticRowChange({
    required this.table,
    required this.rowKey,
    required this.removed,
    this.removedRow,
  });

  /// 业务表名：`material_page`、`message` 或 `attempt`。
  final String table;

  /// 这一行的主键；材料页是页编号，消息与作答是各自的记录编号。
  final String rowKey;

  /// 这一行被删除，或者改动之后不再是来源。
  ///
  /// 判断是否还是来源要读当前业务行，所以这里只记录提交日志里的删除；改动之后
  /// 不再是来源的行由调用方读到空来源之后按删除处理。
  final bool removed;

  /// 删除前的整行，字段与 SQLite 的值类型一致；删除之外的改动为空。
  final Map<String, Object?>? removedRow;
}

/// 一段时间里的来源行变化；[usable] 为假表示起点提交已经从历史里裁掉。
///
/// 历史裁剪会删掉 `revision_commit` 与 `revision_change` 的旧行，起点提交不在
/// 库里时无法确定漏掉了哪些改动，增量刷新不能再做，只能退回全量扫描。
class SemanticChangeWindow {
  const SemanticChangeWindow({this.changes = const [], this.usable = true});

  final List<SemanticRowChange> changes;
  final bool usable;

  /// 起点提交已经不在了：调用方退回全量扫描。
  static const SemanticChangeWindow unavailable = SemanticChangeWindow(
    usable: false,
  );
}
