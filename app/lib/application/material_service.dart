import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/repository/material_repository.dart';
import '../domain/models/material.dart';
import '../domain/models/write_result.dart';
import 'command_ids.dart';
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

  Future<List<Material>> list({String? goalId}) =>
      materials.list(goalId: goalId);

  /// 材料页读到的表：材料行、页码与所属目标。
  ///
  /// 任一表被写入之后整份重读一次，材料列表与材料详情因此跟随其它入口的
  /// 导入、更正与归属调整（ADR-0014）。
  static const Set<String> _listTables = {
    'material',
    'material_page',
    'learning_goal',
  };

  /// 跟随写入更新的材料列表。
  Stream<List<Material>> watchList({String? goalId}) => runtime.watch(
    tables: _listTables,
    read: () => list(goalId: goalId),
  );

  /// 跟随写入更新的单份材料：材料行与它的页码。
  Stream<Material?> watchMaterial(String id) =>
      runtime.watch(tables: _listTables, read: () => byId(id));

  /// 材料详情与单页原文读到的表：材料行的时间与页码计数随页码一起变化。
  static const Set<String> _pageTables = {'material', 'material_page'};

  /// 跟随写入更新的页码列表；材料详情逐页显示时整份重读。
  Stream<List<MaterialPage>> watchPages(String materialId) =>
      runtime.watch(tables: _pageTables, read: () => pages(materialId));

  /// 跟随写入更新的单页原文；只显示一页的地方换页时换一条新流。
  Stream<MaterialPage?> watchPage(String materialId, int pageNo) =>
      runtime.watch(tables: _pageTables, read: () => page(materialId, pageNo));

  Future<Material?> byId(String id) => materials.byId(id);

  /// 材料当前的最小与最大页码；做学习计划时据此决定可选范围。
  Future<({int? first, int? last})> pageBounds(String materialId) =>
      materials.pageBounds(materialId);

  Future<List<MaterialPage>> pages(String materialId) =>
      materials.pages(materialId);

  /// 材料里某一页；查看来源原文与更正后的回显都只读这一页。
  Future<MaterialPage?> page(String materialId, int pageNo) =>
      materials.page(materialId, pageNo);

  Future<String> create({
    required String title,
    MaterialKind kind = MaterialKind.text,
    String? sourceRef,
    String? goalId,
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

  Future<String> importMaterial({
    required String title,
    required List<MaterialPageDraft> pages,
    MaterialKind kind = MaterialKind.text,
    String? sourceRef,
    String? goalId,
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

  Future<String> importDocx({
    required DocxImport document,
    required String title,
    required int expectedEpoch,
    String? goalId,
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

  /// 添加一页；页码已存在时抛出 [PageNumberTaken]，不改动已有原文。
  Future<String> addPage({
    required String materialId,
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

  Future<WriteResult> setGoal(String materialId, String? goalId) =>
      transactions.run((txn) async {
        await materials.setGoal(materialId, goalId, transaction: txn);
        return txn.result();
      }, label: '调整材料目标');

  /// 更正页内文字；返回写结果，界面据此显示撤销入口。
  ///
  /// 内容没有变化时不形成提交，返回 skipped 并带上原因；修改前后都在提交
  /// 历史里，旧引用因此对不上。
  /// 更正一页材料；编号按页、标题与更正后的原文生成，同一份更正连点两次
  /// 只形成一条提交。
  Future<WriteResult> correctPage({
    required MaterialPage page,
    required String corrected,
  }) {
    final text = corrected.trim();
    if (text.isEmpty) throw ArgumentError('这一页还没有内容');
    return transactions.run(
      (txn) async {
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
      },
      label: correctMaterialPageAction,
      requestId: commandId('correct-material-page', [
        page.id,
        page.label,
        text,
      ]),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }
}
