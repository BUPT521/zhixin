import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/memory.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/write_transactions.dart';

/// 记忆（01 `memory`）：自由文本条目，带来源与有效期，可改、可删。
///
/// 三类标签只由这一层写进库；修改是原地改写，删除只改状态。检索线索
/// `search_terms` 与确认保留时间 `reviewed_at` 也在这里写入：前者随内容一起
/// 写，后者单独写一列、不更新时间（ADR-0051 决定第 7、9 条）。
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
    searchTerms: row.searchTerms,
    reviewedAt: optionalDateTime(row.reviewedAt ?? ''),
  );

  Future<List<Memory>> list({bool includeInactive = false}) async {
    final rows = await _db.selectGenerated(
      (db) => db.listMemories(includeInactive ? 0 : 1).get(),
    );
    return rows.map(_memoryOf).toList(growable: false);
  }

  /// 同一范围里仍然有效的某类记忆；作答提案据此找同一道题以前写下的情景。
  ///
  /// 返回来源作答编号，由调用方判断哪条是困难（作答有误）哪条是进展。
  Future<List<({String id, String content, String? sourceId})>> activeByKind(
    MemoryKind kind,
    String? scope,
  ) async {
    final rows = await _db.selectGenerated(
      (db) => db.activeByKind(kind.value, scope?.trim() ?? '').get(),
    );
    return [
      for (final row in rows)
        (id: row.id, content: row.content, sourceId: row.sourceId),
    ];
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

  /// 生成回答时取用的记忆：当前有效、在本次范围内，常驻的排在前面。
  ///
  /// [scope] 是本次目标的适用范围（`goal:<id>` 或 `material:<id>`）；无归属的
  /// 记忆始终可用，其他范围的记忆只在同一范围内进入回答。[limit] 为空时读出
  /// 全部有效条目，由召回服务分层。
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

  /// 写一条记忆；[searchTerms] 是写入时顺带给出的检索线索，没有时写空串。
  ///
  /// 标识由调用方给出：写入路径要在同一个事务里把编号写进回执或卡片，
  /// 编号因此先生成再传入（ADR-0053 的提交身份规则同一条思路）。
  Future<String> create({
    String? id,
    required MemoryKind kind,
    required String content,
    String? scope,
    String searchTerms = '',
    MemorySourceKind sourceKind = MemorySourceKind.user,
    String? sourceId,
    DateTime? validUntil,
    WriteTransaction? transaction,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('记忆内容不能为空');
    final now = formatDateTime(_clock());
    final memoryId = id ?? newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertMemory(
        memoryId,
        kind.value,
        text,
        scope?.trim(),
        sourceKind.value,
        sourceId,
        validUntil == null ? null : formatDateTime(validUntil),
        searchTerms.trim(),
        now,
      ),
    );
    return memoryId;
  }

  /// 原地改写一条记忆；线索随内容一起换新，没有线索时写空串。
  Future<void> updateContent(
    String id, {
    required String content,
    required MemoryKind kind,
    String? scope,
    String searchTerms = '',
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
        kind.value,
        scope?.trim(),
        searchTerms.trim(),
        stamp,
        id,
      ),
    );
  }

  /// 用户确认保留：只写 `reviewed_at`，不更新 `updated_at`，也不触发索引重建。
  Future<void> markReviewed(
    String id, {
    DateTime? at,
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(at ?? _clock());
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setMemoryReviewedAt(stamp, id));
  }

  Future<void> delete(String id, {WriteTransaction? transaction}) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setMemoryStatus(MemoryStatus.deleted.value, stamp, id),
    );
  }

  /// 这条来源是否已经有记忆记录（包括删除过的），用于避免同一来源重复生成
  /// 记忆；可以在写入事务里核对，避免读到事务外的旧状态。
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

  /// 撤销删除时恢复为 active。
  Future<void> restore(String id) async {
    final stamp = formatDateTime(_clock());
    await _db.writeGenerated(
      (db) => db.setMemoryStatus(MemoryStatus.active.value, stamp, id),
    );
  }
}
