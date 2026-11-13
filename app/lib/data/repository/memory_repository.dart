import 'package:sqflite/sqflite.dart';

import '../../domain/models/memory.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 记忆（01 `memory`）：带来源与有效期，可纠正、可删除。
class MemoryRepository {
  MemoryRepository(this._db, {this._clock = systemClock});

  final Database _db;
  final Clock _clock;

  Future<List<Memory>> list({bool includeInactive = false}) async {
    final rows = await _db.query(
      'memory',
      where: includeInactive ? null : 'status = ?',
      whereArgs: includeInactive ? null : ['active'],
      orderBy: 'status, updated_at DESC, id DESC',
    );
    return rows.map(Memory.fromRow).toList(growable: false);
  }

  /// 同一范围里仍然有效的困难记忆；同一困难再次出现时只比较这些条目。
  ///
  /// 原先为此读回全部记忆再在 Dart 里按类型与范围筛选，记忆越多读得越多。
  Future<List<({int id, String content})>> activeDifficulties(
    String? scope,
  ) async {
    final rows = await _db.query(
      'memory',
      columns: ['id', 'content'],
      where: "status = 'active' AND kind = ? AND scope IS ?",
      whereArgs: [MemoryKind.difficulty.value, scope?.trim()],
      orderBy: 'id DESC',
    );
    return [
      for (final row in rows)
        (id: row['id']! as int, content: row['content']! as String),
    ];
  }

  Future<Memory?> byId(int id) async {
    final rows = await _db.query('memory', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Memory.fromRow(rows.first);
  }

  Future<List<({String kind, String? scope, String content})>> activeIdentities(
    DateTime now, {
    required WriteTransaction transaction,
  }) async {
    final rows = await writeExecutor(transaction, _db).query(
      'memory',
      columns: ['kind', 'scope', 'content'],
      where: "status = 'active' AND (valid_until IS NULL OR valid_until >= ?)",
      whereArgs: [formatDateTime(now)],
    );
    return [
      for (final row in rows)
        (
          kind: row['kind']! as String,
          scope: row['scope'] as String?,
          content: row['content']! as String,
        ),
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
    final activeScope = scope?.trim();
    final scopeWhere = activeScope == null || activeScope.isEmpty
        ? 'scope IS NULL'
        : '(scope IS NULL OR scope = ?)';
    final rows = await _db.query(
      'memory',
      where:
          "status = 'active' AND (valid_until IS NULL OR valid_until >= ?) "
          'AND $scopeWhere',
      whereArgs: [
        formatDateTime(now),
        if (activeScope != null && activeScope.isNotEmpty) activeScope,
      ],
      orderBy:
          'CASE WHEN scope IS NULL THEN 1 ELSE 0 END, '
          "CASE kind WHEN 'constraint' THEN 0 WHEN 'preference' THEN 1 "
          "WHEN 'difficulty' THEN 2 ELSE 3 END, "
          'updated_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(Memory.fromRow).toList(growable: false);
  }

  Future<int> create({
    required MemoryKind kind,
    required String content,
    String? scope,
    String sourceKind = 'user',
    int? sourceId,
    DateTime? validUntil,
    WriteTransaction? transaction,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    final now = formatDateTime(_clock());
    return writeExecutor(transaction, _db).insert('memory', {
      'kind': kind.value,
      'content': text,
      'scope': scope?.trim(),
      'source_kind': sourceKind,
      'source_id': sourceId,
      'valid_until': validUntil == null ? null : formatDateTime(validUntil),
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> updateContent(
    int id, {
    required String content,
    DateTime? validUntil,
    WriteTransaction? transaction,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    await writeExecutor(transaction, _db).update(
      'memory',
      {
        'content': text,
        'valid_until': validUntil == null ? null : formatDateTime(validUntil),
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> supersede(int id) async {
    await _db.update(
      'memory',
      {'status': 'superseded', 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(int id, {WriteTransaction? transaction}) async {
    await writeExecutor(transaction, _db).update(
      'memory',
      {'status': 'deleted', 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 这条来源是否已经有记忆记录（包括纠正或删除过的），用于避免同一来源
  /// 重复生成记忆；可以在写入事务里核对，避免读到事务外的旧状态。
  Future<bool> hasSource(
    String sourceKind,
    int sourceId, {
    WriteTransaction? transaction,
  }) async {
    final rows = await writeExecutor(transaction, _db).query(
      'memory',
      columns: ['id'],
      where: 'source_kind = ? AND source_id = ?',
      whereArgs: [sourceKind, sourceId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 撤销删除或纠正时恢复为 active。
  Future<void> restore(int id) async {
    await _db.update(
      'memory',
      {'status': 'active', 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
