import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import '../../domain/models/material.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/text.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/write_transactions.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';
import '../revisions/asset_store.dart';

/// 材料查找的一行：材料本身与命中的一页。
///
/// 标题或来源命中的材料不带命中页，两项为空；页标签或正文命中的材料带回
/// 页码最小的一页，正文片段由调用方按查询截取。
typedef MaterialSearchRow = ({
  Material material,
  int? pageNo,
  String? pageLabel,
  String? pageContent,
});

/// 材料与页码（01 `material` / `material_page`）。
///
/// 一页一条记录，页码从 1 开始；引用先按页码找到原文，再核对摘录是否存在，
/// 用户纠正页内文字时直接更新这一页，旧引用随之失效。添加一页只新增，
/// 页码已存在时拒绝写入，避免静默覆盖已经校对过的原文。
class MaterialRepository {
  MaterialRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<String> create({
    required String title,
    MaterialKind kind = MaterialKind.text,
    String? sourceRef,
    String? goalId,
    WriteTransaction? transaction,
  }) {
    return _create(
      title: title,
      kind: kind,
      sourceRef: sourceRef,
      goalId: goalId,
      executor: writeExecutor(transaction, _db),
    );
  }

  Future<String> _create({
    required String title,
    required MaterialKind kind,
    required String? sourceRef,
    required String? goalId,
    required RawExecutor executor,
    String? sourceFileName,
    String? sourceFileHash,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('材料标题不能为空');
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await executor.writeGenerated(
      (db) => db.insertMaterial(
        id,
        text,
        kind.value,
        nullableText(sourceRef),
        sourceFileName,
        sourceFileHash,
        goalId,
        now,
      ),
    );
    return id;
  }

  /// 页码行的字段与领域模型同名，只补时间解析。
  static MaterialPage _pageOf(MaterialPageRow row) => MaterialPage(
    id: row.id,
    materialId: row.materialId,
    pageNo: row.pageNo,
    content: row.content,
    label: row.label,
  );

  /// 材料的两条查询挑的列相同，按同一组字段还原成领域模型。
  static Material _material(
    String id,
    String title,
    String kind,
    String? sourceRef,
    String? sourceFileName,
    String? goalId,
    int pageCount,
    String createdAt,
    String updatedAt,
  ) => Material(
    id: id,
    title: title,
    kind: MaterialKind.fromValue(kind),
    sourceRef: sourceRef,
    sourceFileName: sourceFileName,
    goalId: goalId,
    pageCount: pageCount,
    createdAt: requiredDateTime(createdAt),
    updatedAt: requiredDateTime(updatedAt),
  );

  static Material _materialOf(MaterialByIdResult r) => _material(
    r.id,
    r.title,
    r.kind,
    r.sourceRef,
    r.sourceFileName,
    r.goalId,
    r.pageCount,
    r.createdAt,
    r.updatedAt,
  );

  static Material _materialOfList(MaterialListResult r) => _material(
    r.id,
    r.title,
    r.kind,
    r.sourceRef,
    r.sourceFileName,
    r.goalId,
    r.pageCount,
    r.createdAt,
    r.updatedAt,
  );

  Future<Material?> byId(String id) async {
    final rows = await _db.selectGenerated((db) => db.materialById(id).get());
    return rows.isEmpty ? null : _materialOf(rows.first);
  }

  Future<List<Material>> list({String? goalId}) async {
    // 不传目标表示不限范围，查询按空参数关掉目标条件。
    final rows = await _db.selectGenerated(
      (db) => db.materialList(goalId).get(),
    );
    return rows.map(_materialOfList).toList(growable: false);
  }

  /// 材料查找的一页：标题、来源、页标签或页内正文任一命中，符合查询的材料各
  /// 占一行，按最近修改倒序排列，顺序与 [list] 一致。
  ///
  /// 一份材料最多一行，页内命中取页码最小的一页；翻页按这一份顺序执行，较早
  /// 的命中也能翻到。边界规则与记录检索的字面命中相同，见
  /// `domain/rules/search_terms.dart` 的 `literalMatchIndex`，“例 3-2”不会
  /// 命中“例 3-20”。
  Future<List<MaterialSearchRow>> search(
    String query, {
    required int limit,
    int offset = 0,
  }) async {
    final text = query.trim();
    if (text.isEmpty || limit <= 0) return const [];
    final (titleMatch, titleArgs) = _literalMatch('m.title', text);
    final (sourceMatch, sourceArgs) = _literalMatch(
      "COALESCE(m.source_ref, '')",
      text,
    );
    final (labelMatch, labelArgs) = _literalMatch(
      "COALESCE(p.label, '')",
      text,
    );
    final (contentMatch, contentArgs) = _literalMatch('p.content', text);
    // 绑定参数的顺序按 SQL 里占位符出现的先后：页内条件在 JOIN 里，标题与
    // 来源条件在 WHERE 里。
    final args = <Object>[
      ...labelArgs,
      ...contentArgs,
      ...titleArgs,
      ...sourceArgs,
    ];
    final rows = await _db.selectGenerated(
      (db) => db
          .customSelect(
            '''
SELECT m.id, m.title, m.kind, m.source_ref, m.source_file_name, m.goal_id,
  m.created_at, m.updated_at,
  (SELECT COUNT(*) FROM material_page c WHERE c.material_id = m.id)
    AS page_count,
  hp.page_no AS hit_page_no, hp.label AS hit_label,
  hp.content AS hit_content
FROM material m
LEFT JOIN material_page hp
  ON hp.material_id = m.id
  AND hp.page_no = (
    SELECT MIN(p.page_no) FROM material_page p
    WHERE p.material_id = m.id AND ($labelMatch OR $contentMatch)
  )
WHERE ($titleMatch OR $sourceMatch OR hp.material_id IS NOT NULL)
ORDER BY m.updated_at DESC, m.id DESC
LIMIT ? OFFSET ?
''',
            variables: [
              for (final value in args) Variable(value),
              Variable<int>(limit),
              Variable<int>(offset),
            ],
          )
          .get(),
    );
    return [
      for (final row in rows)
        (
          material: _material(
            row.data['id']! as String,
            row.data['title']! as String,
            row.data['kind']! as String,
            row.data['source_ref'] as String?,
            row.data['source_file_name'] as String?,
            row.data['goal_id'] as String?,
            row.data['page_count']! as int,
            row.data['created_at']! as String,
            row.data['updated_at']! as String,
          ),
          pageNo: row.data['hit_page_no'] as int?,
          pageLabel: row.data['hit_label'] as String?,
          pageContent: row.data['hit_content'] as String?,
        ),
    ];
  }

  /// 字面命中的 SQL 条件：命中之后不紧接数字、ASCII 字母或下划线。
  ///
  /// 与 `literalMatchIndex` 是同一条规则的两种写法，改一处要同时改另一处；
  /// 每个条件带三个绑定参数：查询原文两次与它的长度。
  static (String, List<Object>) _literalMatch(String column, String text) {
    final match =
        'instr(lower($column), lower(?)) > 0 AND '
        "COALESCE(substr($column, instr(lower($column), lower(?)) "
        "+ length(?), 1), '') NOT GLOB '[0-9A-Za-z_]'";
    return (match, [text, text, text]);
  }

  Future<void> setGoal(
    String id,
    String? goalId, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setMaterialGoal(goalId, stamp, id));
  }

  Future<List<MaterialPage>> pages(String materialId) async {
    final rows = await _db.selectGenerated(
      (db) => db.pagesOfMaterial(materialId).get(),
    );
    return rows.map(_pageOf).toList(growable: false);
  }

  /// 材料里某一页范围；做学习计划与带入原文时只读选中范围。
  ///
  /// [pageFrom]、[pageTo] 为空表示这一端不设限，两端都为空时等同全部页面。
  Future<List<MaterialPage>> pagesBetween(
    String materialId, {
    int? pageFrom,
    int? pageTo,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db.pagesInRange(materialId, pageFrom, pageTo).get(),
    );
    return rows.map(_pageOf).toList(growable: false);
  }

  Future<({int? first, int? last})> pageBounds(String materialId) async {
    final rows = await _db.selectGenerated(
      (db) => db.materialPageBounds(materialId).get(),
    );
    if (rows.isEmpty) return (first: null, last: null);
    return (first: rows.single.firstPage, last: rows.single.lastPage);
  }

  Future<MaterialPage?> page(String materialId, int pageNo) async {
    final row = await _db.selectGenerated(
      (db) => db.materialPageByNumber(materialId, pageNo).getSingleOrNull(),
    );
    return row == null ? null : _pageOf(row);
  }

  /// 按页编号取这一页；更正时在同一个事务里读修改前的整行。
  Future<MaterialPage?> pageById(
    String pageId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.pageById(pageId).getSingleOrNull(),
    );
    return row == null ? null : _pageOf(row);
  }

  /// 新增一页；同一材料同一页码已有原文时抛出 [PageNumberTaken]，不覆盖。
  Future<String> addPage({
    required String materialId,
    required int pageNo,
    required String content,
    String? label,
    WriteTransaction? transaction,
  }) {
    return _addPage(
      materialId: materialId,
      pageNo: pageNo,
      content: content,
      label: label,
      executor: writeExecutor(transaction, _db),
    );
  }

  Future<String> _addPage({
    required String materialId,
    required int pageNo,
    required String content,
    required String? label,
    required RawExecutor executor,
  }) async {
    if (pageNo <= 0) throw ArgumentError('页码从 1 开始');
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    final existing = await executor.selectGenerated(
      (db) => db.materialPageByNumber(materialId, pageNo).getSingleOrNull(),
    );
    if (existing != null) throw PageNumberTaken(pageNo);
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await executor.writeGenerated(
      (db) => db.insertMaterialPage(
        id,
        materialId,
        pageNo,
        nullableText(label),
        text,
        now,
      ),
    );
    await _touch(materialId, now, executor: executor);
    return id;
  }

  /// 更正已有的一页；这一页不存在时抛出 [StateError]。
  Future<void> correctPage({
    required String pageId,
    required String content,
    String? label,
    WriteTransaction? transaction,
  }) {
    return _correctPage(
      pageId: pageId,
      content: content,
      label: label,
      executor: writeExecutor(transaction, _db),
    );
  }

  Future<void> _correctPage({
    required String pageId,
    required String content,
    required String? label,
    required RawExecutor executor,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    final materialId = await executor.selectGenerated(
      (db) => db.pageMaterialId(pageId).getSingleOrNull(),
    );
    if (materialId == null) throw StateError('这一页已不存在');
    final now = formatDateTime(_clock());
    await executor.writeGenerated(
      (db) => db.updateMaterialPage(text, nullableText(label), now, pageId),
    );
    await _touch(materialId, now, executor: executor);
  }

  /// 创建材料与导入的全部页码；传入 [transaction] 时整批落在同一个提交里。
  ///
  /// 导入前先检查页码：同一批出现重复页码时整批拒绝，不写入任何一页。
  Future<String> createWithPages({
    required String title,
    required List<MaterialPageDraft> pages,
    MaterialKind kind = MaterialKind.text,
    String? sourceRef,
    String? goalId,
    ({String name, String hash, Uint8List bytes})? sourceFile,
    WriteTransaction? transaction,
  }) async {
    _checkImportedPages(pages);
    Future<String> save(RawExecutor executor) async {
      if (sourceFile != null) {
        await AssetStore().putBytes(
          executor,
          sourceFile.hash,
          sourceFile.bytes,
        );
      }
      final materialId = await _create(
        title: title,
        kind: kind,
        sourceRef: sourceRef,
        goalId: goalId,
        executor: executor,
        sourceFileName: sourceFile?.name,
        sourceFileHash: sourceFile?.hash,
      );
      for (final page in pages) {
        await _addPage(
          materialId: materialId,
          pageNo: page.pageNo,
          content: page.content,
          label: page.label,
          executor: executor,
        );
      }
      return materialId;
    }

    return save(writeExecutor(transaction, _db));
  }

  Future<Uint8List?> sourceFileBytes(String materialId) async {
    final hash = await _db.selectGenerated(
      (db) => db.materialFileHash(materialId).getSingleOrNull(),
    );
    return hash == null ? null : AssetStore().readBytes(_db, hash);
  }

  void _checkImportedPages(List<MaterialPageDraft> pages) {
    final seen = <int>{};
    for (final page in pages) {
      if (page.pageNo <= 0) throw ArgumentError('页码从 1 开始');
      if (!seen.add(page.pageNo)) throw ArgumentError('第 ${page.pageNo} 页重复');
      if (page.content.trim().isEmpty) {
        throw ArgumentError('第 ${page.pageNo} 页还没有内容');
      }
    }
  }

  Future<void> _touch(
    String materialId,
    String stamp, {
    RawExecutor? executor,
  }) async {
    await (executor ?? _db).writeGenerated(
      (db) => db.touchMaterial(stamp, materialId),
    );
  }
}
