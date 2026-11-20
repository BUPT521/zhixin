import '../db/raw_executor.dart';
import '../db/sql.dart';
import 'revision_models.dart';

/// 已被远端提交取代的本机格子（01 `sync_shadow`）。
///
/// 拉取应用一条远端提交时，对它真正写进本机的每个格子登记一行，`upto_commit`
/// 取应用之前的本机 `HEAD`；推送时按格去掉编号不大于它的本机改动，只推剩余
/// 部分，作用相当于 git 的 `pull --rebase`，粒度从行细到格子（ADR-0040）。
///
/// 遮蔽行与远端提交在同一个事务里写入，所以拉取成功、推送失败之后它仍在库里；
/// 只有两个时机删除：推送位置到达 `upto_commit`，以及裁剪与清理历史把被遮蔽的
/// 提交删掉之后。
class RevisionShadows {
  const RevisionShadows(this.executor);

  final RawExecutor executor;

  /// 全部遮蔽行；推送时一次读出，按提交编号逐条判断，不再逐格查库。
  Future<List<RevisionShadow>> list() async {
    final rows = await selectRows(
      executor,
      'sync_shadow',
      orderBy: 'table_name, row_key, column_name',
    );
    return rows.map(RevisionShadow.fromRow).toList(growable: false);
  }

  /// 登记一条已应用的远端变化覆盖到的格子。
  ///
  /// 修改只覆盖变化列，登记到列；新增、删除与整行覆盖记整行（空列）。同一格子
  /// 再次登记时取较大的 `upto_commit`：后来应用的那条远端提交覆盖的范围更靠后，
  /// 以它为准。
  Future<void> recordChange(
    RevisionChange change, {
    required int uptoCommit,
  }) async {
    if (change.op == ChangeOp.update) {
      // 远端更新真正写进本机的列就是 `after` 里带的列；`before` 只给三方比较
      // 用，不单独登记。
      for (final column in change.after?.keys ?? const <String>[]) {
        await _record(
          table: change.table,
          rowKey: change.rowKey,
          column: column,
          uptoCommit: uptoCommit,
        );
      }
      return;
    }
    await _record(
      table: change.table,
      rowKey: change.rowKey,
      column: '',
      uptoCommit: uptoCommit,
    );
  }

  Future<void> _record({
    required String table,
    required String rowKey,
    required String column,
    required int uptoCommit,
  }) async {
    await executor.execute(
      'INSERT INTO sync_shadow(table_name, row_key, column_name, upto_commit) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(table_name, row_key, column_name) '
      'DO UPDATE SET upto_commit = MAX(upto_commit, excluded.upto_commit)',
      [table, rowKey, column, uptoCommit],
    );
  }

  /// 推送位置到达 [position] 之后删掉已经用不上的遮蔽行。
  ///
  /// 编号不大于 `upto_commit` 的本机提交都已经被推上去或者被遮蔽掉，这一格之
  /// 后在服务端就是两边一致的值，遮蔽行不再需要。
  Future<void> deleteSettled(int position) async {
    await deleteRows(
      executor,
      'sync_shadow',
      where: 'upto_commit <= ?',
      whereArgs: [position],
    );
  }

  /// 裁剪与清理历史把下界之前的提交删掉之后，删掉指向这些提交的遮蔽行。
  Future<void> deleteBefore(int position) async {
    await deleteRows(
      executor,
      'sync_shadow',
      where: 'upto_commit < ?',
      whereArgs: [position],
    );
  }

  /// 整库替换与清理历史之后清空：这些都是整份数据被换掉的路径（导入、退回
  /// 整库替换的恢复、换库恢复补记的差异提交与清理历史），代次变了，旧的格子
  /// 与提交编号不再对应，留着会让下一次推送去错格子。增量恢复只改一部分行，
  /// 遮蔽行仍然对应原来的提交，不清空。
  Future<void> clear() async {
    await deleteRows(executor, 'sync_shadow');
  }
}
