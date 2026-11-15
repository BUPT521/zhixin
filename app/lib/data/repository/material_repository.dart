import 'dart:typed_data';

import '../../domain/models/material.dart';
import '../../domain/rules/binary_bigrams.dart';
import '../../domain/rules/search_terms.dart';
import '../db/fts.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';
import '../db/drift/app_database.dart';
import '../db/drift/drift_raw.dart';
import '../db/raw_executor.dart';
import '../revisions/asset_store.dart';

/// 材料与页码（01 `material` / `material_page`）。
///
/// 一页一条记录，页码从 1 开始；引用先按页码找到原文，再核对摘录是否存在，
/// 用户纠正页内文字时直接更新这一页，旧引用随之失效。添加一页只新增，
/// 页码已存在时拒绝写入，避免静默覆盖已经校对过的原文。
class MaterialRepository {
  MaterialRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<int> create({
    required String title,
    String kind = 'text',
    String? sourceRef,
    int? goalId,
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

  Future<int> _create({
    required String title,
    required String kind,
    required String? sourceRef,
    required int? goalId,
    required RawExecutor executor,
    String? sourceFileName,
    String? sourceFileHash,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('材料标题不能为空');
    final now = formatDateTime(_clock());
    return executor.writeGenerated(
      (db) => db.insertMaterial(
        text,
        kind,
        _clean(sourceRef),
        sourceFileName,
        sourceFileHash,
        goalId,
        now,
      ),
    );
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
    int id,
    String title,
    String kind,
    String? sourceRef,
    String? sourceFileName,
    int? goalId,
    int pageCount,
    String createdAt,
    String updatedAt,
  ) => Material(
    id: id,
    title: title,
    kind: kind,
    sourceRef: sourceRef,
    sourceFileName: sourceFileName,
    goalId: goalId,
    pageCount: pageCount,
    createdAt: DateTime.tryParse(createdAt),
    updatedAt: DateTime.tryParse(updatedAt),
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

  Future<Material?> byId(int id) async {
    final rows = await _db.selectGenerated((db) => db.materialById(id).get());
    return rows.isEmpty ? null : _materialOf(rows.first);
  }

  Future<List<Material>> list({int? goalId}) async {
    // 传 0 表示不限目标：材料标识从 1 开始，0 不会命中任何一条。
    final rows = await _db.selectGenerated(
      (db) => db.materialList(goalId ?? 0).get(),
    );
    return rows.map(_materialOfList).toList(growable: false);
  }

  Future<void> setGoal(int id, int? goalId) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated((db) => db.setMaterialGoal(goalId, stamp, id));
  }

  Future<List<MaterialPage>> pages(int materialId) async {
    final rows = await _db.selectGenerated(
      (db) => db.pagesOfMaterial(materialId).get(),
    );
    return rows.map(_pageOf).toList(growable: false);
  }

  /// 材料里某一页范围；做学习计划与带入原文时只读选中范围。
  ///
  /// [pageFrom]、[pageTo] 为空表示这一端不设限，两端都为空时等同全部页面。
  Future<List<MaterialPage>> pagesBetween(
    int materialId, {
    int? pageFrom,
    int? pageTo,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db.pagesInRange(materialId, pageFrom ?? 0, pageTo ?? 0).get(),
    );
    return rows.map(_pageOf).toList(growable: false);
  }

  Future<({int? first, int? last})> pageBounds(int materialId) async {
    final rows = await _db.selectGenerated(
      (db) => db.materialPageBounds(materialId).get(),
    );
    if (rows.isEmpty) return (first: null, last: null);
    return (first: rows.single.firstPage, last: rows.single.lastPage);
  }

  Future<MaterialPage?> page(int materialId, int pageNo) async {
    final row = await _db.selectGenerated(
      (db) => db.materialPageByNumber(materialId, pageNo).getSingleOrNull(),
    );
    return row == null ? null : _pageOf(row);
  }

  /// 按页编号取这一页；更正时在同一个事务里读修改前的整行。
  Future<MaterialPage?> pageById(
    int pageId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.pageById(pageId).getSingleOrNull(),
    );
    return row == null ? null : _pageOf(row);
  }

  /// 新增一页；同一材料同一页码已有原文时抛出 [PageNumberTaken]，不覆盖。
  Future<int> addPage({
    required int materialId,
    required int pageNo,
    required String content,
    String? label,
    WriteTransaction? transaction,
  }) {
    if (transaction != null) {
      return _addPage(
        materialId: materialId,
        pageNo: pageNo,
        content: content,
        label: label,
        executor: writeExecutor(transaction, _db),
      );
    }
    return _db.transaction(
      (txn) => _addPage(
        materialId: materialId,
        pageNo: pageNo,
        content: content,
        label: label,
        executor: txn,
      ),
    );
  }

  Future<int> _addPage({
    required int materialId,
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
    final id = await executor.writeGenerated(
      (db) =>
          db.insertMaterialPage(materialId, pageNo, _clean(label), text, now),
    );
    await _touch(materialId, now, executor: executor);
    return id;
  }

  /// 更正已有的一页；这一页不存在时抛出 [StateError]。
  Future<void> correctPage({
    required int pageId,
    required String content,
    String? label,
    WriteTransaction? transaction,
  }) {
    if (transaction != null) {
      return _correctPage(
        pageId: pageId,
        content: content,
        label: label,
        executor: writeExecutor(transaction, _db),
      );
    }
    return _db.transaction(
      (txn) => _correctPage(
        pageId: pageId,
        content: content,
        label: label,
        executor: txn,
      ),
    );
  }

  Future<void> _correctPage({
    required int pageId,
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
      (db) => db.updateMaterialPage(text, _clean(label), now, pageId),
    );
    await _touch(materialId, now, executor: executor);
  }

  /// 在同一事务内创建材料及导入的全部页码。
  ///
  /// 导入前先检查页码：同一批出现重复页码时整批拒绝，不写入任何一页。
  Future<int> createWithPages({
    required String title,
    required List<MaterialPageDraft> pages,
    String kind = 'text',
    String? sourceRef,
    int? goalId,
    ({String name, String hash, Uint8List bytes})? sourceFile,
    WriteTransaction? transaction,
  }) async {
    _checkImportedPages(pages);
    Future<int> save(RawExecutor executor) async {
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

    return transaction == null
        ? _db.transaction(save)
        : save(transaction.executor);
  }

  Future<Uint8List?> sourceFileBytes(int materialId) async {
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

  /// 按关键词找材料页。
  ///
  /// 回答上下文默认只取同一目标或未归属的材料；用户主动检索时把
  /// `restrictToGoal` 设为 false，搜索结果覆盖全部材料。关键词命中与排序都
  /// 交给 FTS5 索引：候选由 `MATCH` 选出，先后按 `bm25()` 排。
  Future<List<MaterialHit>> search(
    String query, {
    int? goalId,
    bool restrictToGoal = true,
    int? limit = 4,
    int? excludeMaterialId,
    int? excludePageNo,
  }) async {
    final terms = searchTerms(query);
    if (terms.isEmpty) return const [];
    final tokens = <String>[];
    for (final term in terms) {
      for (final token in bigrams(term)) {
        if (!tokens.contains(token)) tokens.add(token);
      }
    }
    if (tokens.isEmpty) return const [];
    final where = <String>[];
    final args = <Object?>[];
    if (restrictToGoal) {
      if (goalId == null) {
        where.add('m.goal_id IS NULL');
      } else {
        where.add('(m.goal_id = ? OR m.goal_id IS NULL)');
        args.add(goalId);
      }
    }
    if (excludeMaterialId != null) {
      where.add('NOT (mp.material_id = ? AND mp.page_no = ?)');
      args
        ..add(excludeMaterialId)
        ..add(excludePageNo ?? -1);
    }
    where.add(
      'mp.id IN (SELECT rowid FROM material_page_fts '
      'WHERE material_page_fts MATCH ?)',
    );
    args.add(ftsQuery(tokens));
    final rows = await _db.rawQuery(
      '''
      SELECT mp.material_id, mp.page_no, mp.label, mp.content,
        m.title AS material_title, m.source_file_name
      FROM material_page mp JOIN material m ON m.id = mp.material_id
      WHERE ${where.join(' AND ')}
      ORDER BY (SELECT bm25(material_page_fts) FROM material_page_fts
        WHERE material_page_fts MATCH ? AND rowid = mp.id),
        mp.material_id DESC, mp.page_no
      ${limit == null ? '' : 'LIMIT ?'}
      ''',
      [...args, ftsQuery(tokens), ?limit],
    );
    return rows
        .map(
          (row) => MaterialHit(
            materialId: row['material_id']! as int,
            materialTitle: row['material_title'] as String? ?? '材料',
            isDocx: isDocxFile(row['source_file_name'] as String?),
            pageNo: row['page_no']! as int,
            label: row['label'] as String?,
            content: row['content']! as String,
            snippetText: searchSnippet(row['content']! as String, terms),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _touch(
    int materialId,
    String stamp, {
    RawExecutor? executor,
  }) async {
    await (executor ?? _db).writeGenerated(
      (db) => db.touchMaterial(stamp, materialId),
    );
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
