import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/raw_executor.dart';
import '../db/sql.dart';
import '../../domain/models/revision_models.dart';

/// 只登记位置、不阻止裁剪的读取位置的名字（方案 3.12）。
///
/// 检索索引与记忆索引原来把“已处理到的提交编号”写在各自的状态文件里，现在
/// 统一写进 `revision_cursor`，名字在这里登记，读写都用这两个常量；它们落后时
/// 只会退回全量重建，所以 `blocking` 恒为 0，裁剪与清理历史都不受它们影响。
/// 状态文件里的模型键、维度、数据代次与可发送范围签名照旧留在原处，不随这一项
/// 迁移。
abstract final class IndexCursorNames {
  /// 检索索引读到哪里：正文与向量两份 collection 共用一个位置，两份都写成功
  /// 才前进；任何一份清空重建时归零，下一次按全量扫描重建。
  static const String search = 'search.index';

  /// 记忆索引读到哪里：每次召回按记忆表同步之后推进；位置只用于登记进度，
  /// 召回本身仍按记忆条目的版本判断要不要重写。
  static const String memory = 'memory.index';
}

/// 历史下游读者在库里登记的读取位置（01 `revision_cursor`）。
///
/// 会丢数据的读者（同步推送）把 [RevisionCursor.blocking] 置 1，裁剪与清理
/// 历史不能越过它读到的地方；只会退回全量重建的读者（文本索引、记忆索引）
/// 只登记位置。位置随库保存，整库恢复之后跟着回到备份时的位置。
///
/// 一个库只属于一个账号与实例，位置因此不带账号归属：退出登录、删除账号与
/// 清除全部数据只把位置改成不阻塞或删掉位置，这个空间再次打开时从原位置继续
/// 增量同步（ADR-0056 决定第 9 条）。
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
  ///
  /// 一个库只属于一个账号与实例，位置因此不带账号归属（ADR-0056 决定第 9 条）。
  Future<void> set(String name, int position, {required bool blocking}) async {
    await insertRow(executor, 'revision_cursor', {
      'name': name,
      'position': position,
      'blocking': blocking ? 1 : 0,
      'updated_at': formatDateTime(clock()),
    }, replace: true);
  }

  /// 位置改成不阻塞，位置保留。
  ///
  /// 退出登录、删除账号、清除云端与重设密码之后调用：推送位置再也不代表一个
  /// 还会继续的同步，就不能一直挡住清理本机历史；这个空间再次打开时位置仍然
  /// 可用（ADR-0056）。
  Future<void> release(String name) async {
    final cursor = await read(name);
    if (cursor == null || !cursor.blocking) return;
    await set(name, cursor.position, blocking: false);
  }

  /// 读取索引读者已经处理到的提交编号；没有登记过时为零，按全量重建。
  ///
  /// 名字取 [IndexCursorNames]；读不出来时也按零处理，原因与“没有登记过”相同：
  /// 索引内容可以从业务表重建，多扫一次不会出错。
  Future<int> indexPosition(String name) async {
    try {
      return await position(name);
    } on Object {
      return 0;
    }
  }

  /// 推进索引读者的读取位置。
  ///
  /// 索引落后只会多扫一次，所以这里写 `blocking = 0`；位置写在
  /// `revision_cursor`，状态文件只保留模型键、维度、数据代次与可发送范围签名。
  Future<void> advanceIndex(String name, int position) =>
      set(name, position, blocking: false);

  Future<void> delete(String name) async {
    await deleteRows(
      executor,
      'revision_cursor',
      where: 'name = ?',
      whereArgs: [name],
    );
  }
}
