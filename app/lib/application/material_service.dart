import 'dart:typed_data';

import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/repository/material_repository.dart';
import '../domain/models/material.dart';
import 'docx_import.dart';
import 'service_runtime.dart';

/// 材料页的读写：导入材料、添加一页与更正页内文字。
///
/// 添加只新增，页码已存在时拒绝写入；用户明确更正时才改写这一页。更正在一次
/// 提交里完成，修改前后的整页留在提交历史里，旧引用因此不再通过核对。
class MaterialService {
  MaterialService({
    required this.materials,
    required this.transactions,
    required this.runtime,
  });

  final MaterialRepository materials;
  final WriteTransactions transactions;
  final ServiceRuntime runtime;

  Future<List<Material>> list({int? goalId}) => materials.list(goalId: goalId);

  Future<Material?> byId(int id) => materials.byId(id);

  Future<List<MaterialPage>> pages(int materialId) =>
      materials.pages(materialId);

  /// 材料里某一页；查看来源原文时只读这一页。
  Future<MaterialPage?> page(int materialId, int pageNo) =>
      materials.page(materialId, pageNo);

  /// 材料里某一页范围；做学习计划时只读选中范围。
  Future<List<MaterialPage>> pagesBetween(
    int materialId, {
    int? pageFrom,
    int? pageTo,
  }) => materials.pagesBetween(materialId, pageFrom: pageFrom, pageTo: pageTo);

  Future<int> create({
    required String title,
    String kind = 'text',
    String? sourceRef,
    int? goalId,
  }) {
    return materials.create(
      title: title,
      kind: kind,
      sourceRef: sourceRef,
      goalId: goalId,
    );
  }

  Future<int> importMaterial({
    required String title,
    required List<MaterialPageDraft> pages,
    String kind = 'text',
    String? sourceRef,
    int? goalId,
  }) {
    return materials.createWithPages(
      title: title,
      pages: pages,
      kind: kind,
      sourceRef: sourceRef,
      goalId: goalId,
    );
  }

  Future<int> importDocx({
    required DocxImport document,
    required String title,
    required int expectedEpoch,
    int? goalId,
  }) {
    return transactions.run((txn) {
      if (runtime.dataEpoch != expectedEpoch) {
        throw StateError('数据版本已变更，请重新选择 Word 文件');
      }
      return materials.createWithPages(
        title: title,
        sourceRef: document.fileName,
        goalId: goalId,
        pages: document.sections,
        sourceFile: (
          name: document.fileName,
          hash: document.hash,
          bytes: document.bytes,
        ),
        transaction: txn,
      );
    }, label: '导入 Word 材料');
  }

  Future<Uint8List?> sourceFileBytes(int materialId) =>
      materials.sourceFileBytes(materialId);

  /// 添加一页；页码已存在时抛出 [PageNumberTaken]，不改动已有原文。
  Future<int> addPage({
    required int materialId,
    required int pageNo,
    required String content,
    String? label,
  }) {
    return materials.addPage(
      materialId: materialId,
      pageNo: pageNo,
      content: content,
      label: label,
    );
  }

  Future<void> setGoal(int materialId, int? goalId) =>
      materials.setGoal(materialId, goalId);

  /// 更正页内文字；返回这次提交的编号，界面据此显示撤销入口。
  ///
  /// 内容没有变化时不形成提交，返回空；修改前后都在提交历史里，旧引用因此
  /// 对不上。
  Future<int?> correctPage({
    required MaterialPage page,
    required String corrected,
  }) {
    final text = corrected.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    return transactions.run((txn) async {
      final current = await materials.pageById(page.id, transaction: txn);
      if (current == null) throw StateError('这一页已不存在');
      if (current.content == text && current.label == page.label) return null;
      await materials.correctPage(
        pageId: page.id,
        content: text,
        label: page.label,
        transaction: txn,
      );
      return txn.requireCommitId();
    }, label: correctMaterialPageAction);
  }
}
