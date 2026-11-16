import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/memory.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/write_transactions.dart';

/// 记忆（01 `memory`）：带来源与有效期，可纠正、可删除。
class MemoryRepository {
  MemoryRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  /// 记忆表的字段与领域模型同名，只补枚举与时间解析。
  static Memory _memoryOf(MemoryRow row) => Memory(
    id: row.id,
    kind: MemoryKind.fromValue(row.kind),
    content: row.content,
    scope: row.scope,
    sourceKind: MemorySourceKind.fromValue(row.sourceKind),
    sourceId: row.sourceId,
    validUntil: optionalDateTime(row.validUntil ?? ''),
    status: MemoryStatus.fromValue(row.status),
    createdAt: requiredDateTime(row.createdAt),
    updatedAt: requiredDateTime(row.updatedAt),
  );

  Future<List<Memory>> list({bool includeInactive = false}) async {
    final rows = await _db.selectGenerated(
      (db) => db.listMemories(includeInactive ? 0 : 1).get(),
    );
    return rows.map(_memoryOf).toList(growable: false);
  }

  /// 同一范围里仍然有效的困难记忆；同一困难再次出现时只比较这些条目。
  ///
  /// 原先为此读回全部记忆再在 Dart 里按类型与范围筛选，记忆越多读得越多。
  Future<List<({String id, String content})>> activeDifficulties(
    String? scope,
  ) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .activeDifficulties(MemoryKind.difficulty.value, scope?.trim() ?? '')
          .get(),
    );
    return [for (final row in rows) (id: row.id, content: row.content)];
  }

  Future<Memory?> byId(String id) async {
    final row = await _db.selectGenerated(
      (db) => db.memoryById(id).getSingleOrNull(),
    );
    return row == null ? null : _memoryOf(row);
  }

  Future<List<({String kind, String? scope, String content})>> activeIdentities(
    DateTime now, {
    WriteTransaction? transaction,
  }) async {
    final rows = await writeExecutor(transaction, _db).selectGenerated(
      (db) => db.activeMemoryIdentities(formatDateTime(now)).get(),
    );
    return [
      for (final row in rows)
        (kind: row.kind, scope: row.scope, content: row.content),
    ];
  }

  /// 生成回答时取用的记忆：当前有效，先取本次范围内的，再按约束、偏好、
  /// 困难与进展的顺序，同一类里取最近更新的；不再只按更新时间截取前 20 条。
  ///
  /// [scope] 是本次目标的适用范围（`goal:<id>` 或 `material:<id>`）；无归属的
  /// 记忆始终可用，其他范围的记忆只在同一范围内进入回答。[limit] 为空时读出
  /// 全部有效条目，由上层按本次用途挑选。
  Future<List<Memory>> activeForContext({
    required DateTime now,
    String? scope,
    int? limit = 40,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .memoriesForContext(formatDateTime(now), scope?.trim() ?? '', limit)
          .get(),
    );
    return rows.map(_memoryOf).toList(growable: false);
  }

  Future<String> create({
    required MemoryKind kind,
    required String content,
    String? scope,
    MemorySourceKind sourceKind = MemorySourceKind.user,
    String? sourceId,
    DateTime? validUntil,
    WriteTransaction? transaction,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertMemory(
        id,
        kind.value,
        text,
        scope?.trim(),
        sourceKind.value,
        sourceId,
        validUntil == null ? null : formatDateTime(validUntil),
        now,
      ),
    );
    return id;
  }

  Future<void> updateContent(
    String id, {
    required String content,
    DateTime? validUntil,
    WriteTransaction? transaction,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.updateMemoryContent(
        text,
        validUntil == null ? null : formatDateTime(validUntil),
        stamp,
        id,
      ),
    );
  }

  Future<void> supersede(String id) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated(
      (db) => db.setMemoryStatus(MemoryStatus.superseded.value, stamp, id),
    );
  }

  Future<void> delete(String id, {WriteTransaction? transaction}) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setMemoryStatus(MemoryStatus.deleted.value, stamp, id),
    );
  }

  /// 这条来源是否已经有记忆记录（包括纠正或删除过的），用于避免同一来源
  /// 重复生成记忆；可以在写入事务里核对，避免读到事务外的旧状态。
  Future<bool> hasSource(
    MemorySourceKind sourceKind,
    String sourceId, {
    WriteTransaction? transaction,
  }) async {
    final row = await writeExecutor(transaction, _db).selectGenerated(
      (db) =>
          db.hasMemoryFromSource(sourceKind.value, sourceId).getSingleOrNull(),
    );
    return row != null;
  }

  /// 撤销删除或纠正时恢复为 active。
  Future<void> restore(String id) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated(
      (db) => db.setMemoryStatus(MemoryStatus.active.value, stamp, id),
    );
  }
}
