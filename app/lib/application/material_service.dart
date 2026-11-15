import 'dart:typed_data';

import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/repository/material_repository.dart';
import '../domain/models/material.dart';
import '../domain/models/write_result.dart';
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

  /// 当前数据代次：打开文件选择器之前取一次，导入时交给 [importDocx] 核对。
  int get dataEpoch => runtime.dataEpoch;

  Future<List<Material>> list({int? goalId}) => materials.list(goalId: goalId);

  Future<Material?> byId(int id) => materials.byId(id);

  /// 材料当前的最小与最大页码；做学习计划时据此决定可选范围。
  Future<({int? first, int? last})> pageBounds(int materialId) =>
      materials.pageBounds(materialId);

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
    return transactions.run(
      (txn) => materials.create(
        title: title,
        kind: kind,
        sourceRef: sourceRef,
        goalId: goalId,
        transaction: txn,
      ),
      label: '新建材料',
    );
  }

  Future<int> importMaterial({
    required String title,
    required List<MaterialPageDraft> pages,
    String kind = 'text',
    String? sourceRef,
    int? goalId,
  }) {
    return transactions.run(
      (txn) => materials.createWithPages(
        title: title,
        pages: pages,
        kind: kind,
        sourceRef: sourceRef,
        goalId: goalId,
        transaction: txn,
      ),
      label: '导入材料',
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
    return transactions.run(
      (txn) => materials.addPage(
        materialId: materialId,
        pageNo: pageNo,
        content: content,
        label: label,
        transaction: txn,
      ),
      label: '添加材料页',
    );
  }

  Future<WriteResult> setGoal(int materialId, int? goalId) =>
      transactions.run((txn) async {
        await materials.setGoal(materialId, goalId, transaction: txn);
        return txn.result();
      }, label: '调整材料目标');

  /// 更正页内文字；返回写结果，界面据此显示撤销入口。
  ///
  /// 内容没有变化时不形成提交，返回 skipped 并带上原因；修改前后都在提交
  /// 历史里，旧引用因此对不上。
  Future<WriteResult> correctPage({
    required MaterialPage page,
    required String corrected,
  }) {
    final text = corrected.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    return transactions.run((txn) async {
      final current = await materials.pageById(page.id, transaction: txn);
      if (current == null) throw StateError('这一页已不存在');
      if (current.content == text && current.label == page.label) {
        return const WriteResult.skipped('这一页的内容没有变化');
      }
      await materials.correctPage(
        pageId: page.id,
        content: text,
        label: page.label,
        transaction: txn,
      );
      return txn.result();
    }, label: correctMaterialPageAction);
  }
}
