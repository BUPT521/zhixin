import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/raw_executor.dart';
import '../db/sql.dart';
import 'revision_models.dart';

/// 历史下游读者在库里登记的读取位置（01 `revision_cursor`）。
///
/// 会丢数据的读者（同步推送）把 [RevisionCursor.blocking] 置 1，裁剪与清理
/// 历史不能越过它读到的地方；只会退回全量重建的读者（文本索引、记忆索引）
/// 只登记位置。位置随库保存，整库恢复之后跟着回到备份时的位置。
class RevisionCursors {
  const RevisionCursors(this.executor, {this.clock = systemClock});

  final RawExecutor executor;
  final Clock clock;

  Future<RevisionCursor?> read(String name) async {
    final rows = await selectRows(
      executor,
      'revision_cursor',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCursor.fromRow(rows.first);
  }

  Future<int> position(String name) async => (await read(name))?.position ?? 0;

  Future<List<RevisionCursor>> list() async {
    final rows = await selectRows(executor, 'revision_cursor', orderBy: 'name');
    return rows.map(RevisionCursor.fromRow).toList(growable: false);
  }

  /// 仍然阻塞裁剪的最小位置；没有阻塞的读取位置时为空。
  Future<int?> minimumBlockingPosition() async {
    final rows = await executor.rawQuery(
      'SELECT MIN(position) AS position FROM revision_cursor '
      'WHERE blocking = 1',
    );
    if (rows.isEmpty) return null;
    return rows.first['position'] as int?;
  }

  /// 写入或推进一个读取位置；位置只前进，恢复旧备份之后允许后退。
  Future<void> set(String name, int position, {required bool blocking}) async {
    await insertRow(executor, 'revision_cursor', {
      'name': name,
      'position': position,
      'blocking': blocking ? 1 : 0,
      'updated_at': formatDateTime(clock()),
    }, replace: true);
  }

  Future<void> delete(String name) async {
    await deleteRows(
      executor,
      'revision_cursor',
      where: 'name = ?',
      whereArgs: [name],
    );
  }
}
