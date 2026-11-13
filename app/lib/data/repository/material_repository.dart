import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../domain/models/material.dart';
import '../../domain/rules/search_terms.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';
import '../revisions/asset_store.dart';

/// 材料与页码（01 `material` / `material_page`）。
///
/// 一页一条记录，页码从 1 开始；引用先按页码找到原文，再核对摘录是否存在，
/// 用户纠正页内文字时直接更新这一页，旧引用随之失效。添加一页只新增，
/// 页码已存在时拒绝写入，避免静默覆盖已经校对过的原文。
class MaterialRepository {
  MaterialRepository(this._db, {this._clock = systemClock});

  final Database _db;
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
    required DatabaseExecutor executor,
    String? sourceFileName,
    String? sourceFileHash,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('材料标题不能为空');
    final now = formatDateTime(_clock());
    return executor.insert('material', {
      'title': text,
      'kind': kind,
      'source_ref': _clean(sourceRef),
      'source_file_name': sourceFileName,
      'source_file_hash': sourceFileHash,
      'goal_id': goalId,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<Material?> byId(int id) async {
    final rows = await _db.rawQuery(
      '''
      SELECT m.*, (SELECT COUNT(*) FROM material_page p
        WHERE p.material_id = m.id) AS page_count
      FROM material m WHERE m.id = ?
      ''',
      [id],
    );
    return rows.isEmpty ? null : Material.fromRow(rows.first);
  }

  Future<List<Material>> list({int? goalId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (goalId != null) {
      where.add('(m.goal_id = ? OR m.goal_id IS NULL)');
      args.add(goalId);
    }
    final rows = await _db.rawQuery('''
      SELECT m.*, (SELECT COUNT(*) FROM material_page p
        WHERE p.material_id = m.id) AS page_count
      FROM material m
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY m.updated_at DESC, m.id DESC
      ''', args);
    return rows.map(Material.fromRow).toList(growable: false);
  }

  Future<void> setGoal(int id, int? goalId) async {
    await _db.update(
      'material',
      {'goal_id': goalId, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<MaterialPage>> pages(int materialId) async {
    final rows = await _db.query(
      'material_page',
      where: 'material_id = ?',
      whereArgs: [materialId],
      orderBy: 'page_no',
    );
    return rows.map(MaterialPage.fromRow).toList(growable: false);
  }

  /// 材料里某一页范围；做学习计划与带入原文时只读选中范围。
  ///
  /// [pageFrom]、[pageTo] 为空表示这一端不设限，两端都为空时等同全部页面。
  Future<List<MaterialPage>> pagesBetween(
    int materialId, {
    int? pageFrom,
    int? pageTo,
  }) async {
    final where = <String>['material_id = ?'];
    final args = <Object?>[materialId];
    if (pageFrom != null) {
      where.add('page_no >= ?');
      args.add(pageFrom);
    }
    if (pageTo != null) {
      where.add('page_no <= ?');
      args.add(pageTo);
    }
    final rows = await _db.query(
      'material_page',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'page_no',
    );
    return rows.map(MaterialPage.fromRow).toList(growable: false);
  }

  Future<({int? first, int? last})> pageBounds(int materialId) async {
    final rows = await _db.rawQuery(
      'SELECT MIN(page_no) AS first_page, MAX(page_no) AS last_page '
      'FROM material_page WHERE material_id = ?',
      [materialId],
    );
    if (rows.isEmpty) return (first: null, last: null);
    return (
      first: rows.single['first_page'] as int?,
      last: rows.single['last_page'] as int?,
    );
  }

  Future<MaterialPage?> page(int materialId, int pageNo) async {
    final rows = await _db.query(
      'material_page',
      where: 'material_id = ? AND page_no = ?',
      whereArgs: [materialId, pageNo],
      limit: 1,
    );
    return rows.isEmpty ? null : MaterialPage.fromRow(rows.first);
  }

  /// 按页编号取这一页；更正时在同一个事务里读修改前的整行。
  Future<MaterialPage?> pageById(
    int pageId, {
    WriteTransaction? transaction,
  }) async {
    final rows = await writeExecutor(
      transaction,
      _db,
    ).query('material_page', where: 'id = ?', whereArgs: [pageId], limit: 1);
    return rows.isEmpty ? null : MaterialPage.fromRow(rows.first);
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
    required DatabaseExecutor executor,
  }) async {
    if (pageNo <= 0) throw ArgumentError('页码从 1 开始');
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    final rows = await executor.query(
      'material_page',
      where: 'material_id = ? AND page_no = ?',
      whereArgs: [materialId, pageNo],
      limit: 1,
    );
    if (rows.isNotEmpty) throw PageNumberTaken(pageNo);
    final now = formatDateTime(_clock());
    final id = await executor.insert('material_page', {
      'material_id': materialId,
      'page_no': pageNo,
      'label': _clean(label),
      'content': text,
      'created_at': now,
      'updated_at': now,
    });
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
    required DatabaseExecutor executor,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    final rows = await executor.query(
      'material_page',
      columns: ['material_id'],
      where: 'id = ?',
      whereArgs: [pageId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('这一页已不存在');
    final now = formatDateTime(_clock());
    await executor.update(
      'material_page',
      {'content': text, 'label': _clean(label), 'updated_at': now},
      where: 'id = ?',
      whereArgs: [pageId],
    );
    await _touch(rows.first['material_id']! as int, now, executor: executor);
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
    Future<int> save(DatabaseExecutor executor) async {
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
    final rows = await _db.query(
      'material',
      columns: ['source_file_hash'],
      where: 'id = ?',
      whereArgs: [materialId],
    );
    final hash = rows.firstOrNull?['source_file_hash'] as String?;
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

  Future<void> deletePage(int pageId) async {
    final rows = await _db.query(
      'material_page',
      columns: ['material_id'],
      where: 'id = ?',
      whereArgs: [pageId],
      limit: 1,
    );
    await _db.delete('material_page', where: 'id = ?', whereArgs: [pageId]);
    if (rows.isNotEmpty) {
      await _touch(rows.first['material_id']! as int, formatDateTime(_clock()));
    }
  }

  /// 按关键词找材料页。
  ///
  /// 回答上下文默认只取同一目标或未归属的材料；用户主动检索时把
  /// `restrictToGoal` 设为 false，搜索结果覆盖全部材料。
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
    final match = <String>[];
    for (final term in terms) {
      match.add('(mp.content LIKE ? OR mp.label LIKE ? OR m.title LIKE ?)');
      args
        ..add('%$term%')
        ..add('%$term%')
        ..add('%$term%');
    }
    where.add('(${match.join(' OR ')})');
    final ranking = terms
        .map(
          (_) =>
              '(CASE WHEN mp.content LIKE ? OR mp.label LIKE ? OR m.title LIKE ? '
              'THEN 1 ELSE 0 END)',
        )
        .join(' + ');
    for (final term in terms) {
      args
        ..add('%$term%')
        ..add('%$term%')
        ..add('%$term%');
    }
    final rows = await _db.rawQuery('''
      SELECT mp.material_id, mp.page_no, mp.label, mp.content,
        m.title AS material_title, m.source_file_name
      FROM material_page mp JOIN material m ON m.id = mp.material_id
      WHERE ${where.join(' AND ')}
      ORDER BY $ranking DESC, mp.material_id DESC, mp.page_no
      ${limit == null ? '' : 'LIMIT ?'}
      ''', limit == null ? args : [...args, limit]);
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
    DatabaseExecutor? executor,
  }) async {
    await (executor ?? _db).update(
      'material',
      {'updated_at': stamp},
      where: 'id = ?',
      whereArgs: [materialId],
    );
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
