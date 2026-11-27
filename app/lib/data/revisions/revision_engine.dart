import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Table, TableInfo;

import '../../domain/models/chat_message_payload.dart';
import '../../domain/rules/revision_retention.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/drift/tables.dart'
    show
        nonVersionedPersistentTableNames,
        revisionColumnGroups,
        revisionMetadataTablePrefixes,
        revisionUniqueKeys,
        RevisionUniqueKey,
        RevisionUniqueKeyPolicy;
import '../db/schema.dart' show schemaTableNames, schemaTables;
import '../db/sql.dart';
import '../db/raw_executor.dart';
import 'asset_store.dart';
import 'revision_digest.dart';
import '../../domain/models/revision_models.dart';
import 'revision_shadow.dart';

part 'revision_capture.dart';
part 'revision_log.dart';
part 'revision_maintenance.dart';
part 'revision_projection.dart';
part 'revision_remote.dart';

/// 版本元数据与附件对象；不参与触发器采集，单独分类。
///
/// 由 drift 表类登记的表名单按 [revisionMetadataTablePrefixes] 派生，新增这类
/// 表沿用前缀即可。
final Set<String> revisionMetadataTables = {
  for (final name in schemaTableNames())
    if (revisionMetadataTablePrefixes.any(name.startsWith)) name,
};

/// 保留在库里、但不参与数据版本采集的持久表：内部设置。
const Set<String> nonVersionedPersistentTables =
    nonVersionedPersistentTableNames;

/// 记录提交历史的版本元数据表；每次提交都会写到，历史页因此也跟随更新。
///
/// 这三张表不参与采集，业务表的通知按提交里的净变化发，历史页读的是它们，
/// 所以提交收尾一并带上（ADR-0014 第 2 条）。`HEAD` 每次提交都写进
/// `revision_state`，命名版本只在用户命名、改名、删除时写 `revision_ref`
/// （ADR-0054 实施前核对第 3 条）。
const Set<String> revisionHistoryTables = {
  'revision_commit',
  'revision_change',
  'revision_state',
};

/// 参与版本采集的业务表，顺序按外键依赖排列：先被引用的表在前。
///
/// 由 drift 表类派生：元数据、附件对象与内部设置表以外的表都参与采集。新增
/// 业务表不需要另外登记，写入会自动进入数据变更历史；版本元数据、诊断记录、
/// 缓存与密钥不登记。
final List<String> versionedTableNames = [
  for (final name in schemaTableNames())
    if (!revisionMetadataTables.contains(name) &&
        !nonVersionedPersistentTables.contains(name))
      name,
];

/// 每张业务表的主键；每张业务表都要有一个主键列，复合主键不在采集范围内。
final Map<String, String> versionedPrimaryKeys = {
  for (final table in schemaTables())
    if (versionedTableNames.contains(table.entityName))
      table.entityName: _primaryKeyOf(table),
};

/// 表的主键列名；复合主键或没有主键时给出能看懂的报错。
String _primaryKeyOf(TableInfo<Table, Object?> table) {
  final key = table.$primaryKey;
  if (key.length != 1) {
    throw StateError('业务表 ${table.entityName} 有 ${key.length} 列主键，版本采集只支持单列主键');
  }
  return key.single.name;
}

class RevisionTable {
  const RevisionTable({
    required this.name,
    required this.primaryKey,
    required this.columns,
  });

  final String name;
  final String primaryKey;
  final List<String> columns;

  String get stageTable => 'rev_stage_$name';
}

/// 提交编号已被其他请求使用；调用方应读取原提交而不是重复执行写入。
class RevisionDuplicateRequest implements Exception {
  const RevisionDuplicateRequest(this.commit);

  final RevisionCommit commit;

  @override
  String toString() => '请求 ${commit.uid} 已提交为版本 ${commit.id}';
}

/// 重建时断链或值与预期不一致。
class RevisionCorruption implements Exception {
  const RevisionCorruption(this.message);

  final String message;

  @override
  String toString() => '数据版本无法重建：$message';
}

/// 预览之后 `HEAD` 已被其他写入推进。
class RevisionStaleHead implements Exception {
  const RevisionStaleHead({required this.expected, required this.actual});

  final int expected;
  final int actual;

  @override
  String toString() => '当前版本已从 $expected 变为 $actual，请重新预览后再恢复';
}

/// 安装、采集、提交、投影、留存与远端应用的实现核心。
///
/// 本文件只放类定义、字段、构造、表结构缓存与初始化；其余成员按读取路径拆在
/// 同库的 `part` 文件里，每个文件由一条开发泳道拥有（ADR-0039）。
class RevisionEngine
    with
        RevisionCaptureMixin,
        RevisionLogMixin,
        RevisionMaintenanceMixin,
        RevisionProjectionMixin,
        RevisionRemoteMixin {
  RevisionEngine({
    this.clock = systemClock,
    AssetStore? assets,
    this.idleCheckpointBytes = 8 * 1024 * 1024,
    this.autoRetentionCommits = revisionAutoRetentionCommits,
    this.autoRetentionBytes = revisionHistoryBudgetBytes,
  }) : assets = assets ?? AssetStore();

  final Clock clock;
  final AssetStore assets;

  /// 同库其他文件里的方法通过它取本对象的字段与方法。
  @override
  RevisionEngine get self => this;

  /// 空闲检查点的累计阈值：距最近检查点的提交变更明细字节数超过它时，在
  /// 写事务之外的维护事务里生成一份检查点（ADR-0039 第 2 条）。
  final int idleCheckpointBytes;

  /// 自动裁剪的提交条数阈值：历史超过这么多条提交时，在空闲检查点之后按
  /// 时间优先的口径裁剪一次（方案 3.8，对照 `git gc --auto`）。
  final int autoRetentionCommits;

  /// 自动裁剪的历史字节阈值，同时是更早历史的保留预算：提交变更明细与
  /// 检查点字节之和超过它时触发，裁剪时更早的提交按这个预算保留。
  final int autoRetentionBytes;

  Map<String, RevisionTable>? _cache;

  Future<Map<String, RevisionTable>> tables(RawExecutor executor) async {
    final cached = _cache;
    if (cached != null) return cached;
    final result = <String, RevisionTable>{};
    for (final name in versionedTableNames) {
      final info = await executor.rawQuery('PRAGMA table_info("$name")');
      if (info.isEmpty) {
        throw StateError('业务表 $name 不存在，无法生成版本采集触发器');
      }
      final pk = versionedPrimaryKeys[name];
      if (pk == null) throw StateError('业务表 $name 没有登记主键');
      final columns = <String>[];
      var hasPk = false;
      for (final row in info) {
        final column = row['name']! as String;
        columns.add(column);
        if (column == pk && (row['pk'] as int? ?? 0) > 0) hasPk = true;
      }
      if (!hasPk) throw StateError('业务表 $name 没有主键 $pk');
      result[name] = RevisionTable(
        name: name,
        primaryKey: pk,
        columns: List.unmodifiable(columns),
      );
    }
    _cache = result;
    return result;
  }

  Future<void> initialize(
    RawDatabase db, {
    Future<void> Function()? seed,
  }) async {
    await installRevisionSchema(db, this);
    await _dropLegacySearchIndexes(db);
    await seed?.call();
    await _ensureMetadata(db);
  }

  /// 旧版关键词索引的派生表与触发器已无人读取，打开库时删除。
  ///
  /// 三张 FTS5 表与同步触发器是在关键词检索并入 zvec 之前建立的（ADR-0024），
  /// 新库不再创建；已有的开发库在第一次打开时清理，避免整库备份的对象白名单
  /// 把它们当成当前程序不认识的对象。删除的是派生数据，业务行不动。
  Future<void> _dropLegacySearchIndexes(RawDatabase db) async {
    final triggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name GLOB 'fts_*_fts_*'",
    );
    for (final row in triggers) {
      await db.execute('DROP TRIGGER IF EXISTS "${row['name']}"');
    }
    for (final table in const [
      'material_page_fts',
      'message_fts',
      'attempt_fts',
    ]) {
      await db.execute('DROP TABLE IF EXISTS "$table"');
    }
  }

  /// 写基线提交、初始检查点与单行状态；打开库时执行，重复执行保持幂等。
  ///
  /// `HEAD` 已经在 `revision_state.head_commit_id` 里，不再有“缺 HEAD 就补成
  /// 最大编号”的分支（ADR-0054 决定第 4 条）；单行状态由
  /// `installRevisionSchema` 建好，这里只补进程中断留下的预留编号与缺失的
  /// 分表摘要。
  Future<void> _ensureMetadata(RawDatabase db) async {
    await db.transaction((txn) async {
      final heads = await selectRows(
        txn,
        'revision_commit',
        columns: ['id', 'generation'],
        orderBy: 'id',
      );
      if (heads.isEmpty) {
        final projection = await readProjection(txn);
        final now = formatDateTime(clock());
        // 初始基线的摘要是当前投影的整库重算，分表值同时写上，本机提交没有
        // 来源设备与作者时间（方案 3.5、3.12）。
        final digests = revisionTableDigests(projection);
        await insertRow(txn, 'revision_commit', {
          'id': 0,
          'uid': newUuidV7(),
          'parent_id': null,
          'generation': 0,
          'state_digest': revisionStateDigest(projection),
          'actor': 'system',
          'action': '初始基线',
          'kind': RevisionKind.baseline.value,
          'restored_commit_id': null,
          'reverted_commit_id': null,
          'byte_length': 0,
          'server_seq': null,
          'origin_device': null,
          'authored_at': null,
          'created_at': now,
        });
        await updateRow(txn, 'revision_state', {
          'active_commit': null,
          'capturing': 0,
          'suppress': 0,
          'next_commit': 1,
          'head_commit_id': 0,
          'table_digests_json': jsonEncode(digests),
        }, where: 'id = 1');
        await _writeCheckpoint(
          txn,
          commitId: 0,
          kind: 'initial',
          projection: projection,
        );
        return;
      }

      final state = await selectRows(txn, 'revision_state', limit: 1);
      if (state.isEmpty) {
        await insertRow(txn, 'revision_state', {
          'id': 1,
          'active_commit': null,
          'capturing': 0,
          'suppress': 0,
          'next_commit': (heads.last['id']! as int) + 1,
          'head_commit_id': heads.last['id']! as int,
          'table_digests_json': jsonEncode(revisionEmptyTableDigests()),
        });
        return;
      }
      // 上次进程中断留下的预留编号不跨事务保留；打开时清掉，避免新写入被记到
      // 一个并不存在的提交上。
      final row = state.first;
      if (row['active_commit'] != null ||
          (row['capturing'] as int? ?? 0) != 0 ||
          (row['suppress'] as int? ?? 0) != 0) {
        await updateRow(txn, 'revision_state', {
          'active_commit': null,
          'capturing': 0,
          'suppress': 0,
        }, where: 'id = 1');
      }
      // 基线提交的分表摘要缺失时按它的摘要重建一份：全部记在首张业务表上，
      // 各表之和仍等于这条提交的摘要。
      final digests = row['table_digests_json'] as String?;
      if (digests == null || digests.isEmpty || digests == '{}') {
        final headRows = await selectRows(
          txn,
          'revision_commit',
          columns: ['state_digest'],
          where: 'id = ?',
          whereArgs: [row['head_commit_id'] as int? ?? 0],
          limit: 1,
        );
        final headDigest = headRows.isEmpty
            ? revisionEmptyStateDigest
            : headRows.first['state_digest']! as String;
        final head = await commitById(txn, row['head_commit_id'] as int? ?? 0);
        await updateRow(txn, 'revision_state', {
          'table_digests_json': jsonEncode({
            for (final name in versionedTableNames)
              name: _legacyHeadDigestSplit(
                head?.stateDigest ?? headDigest,
                name,
              ),
          }),
        }, where: 'id = 1');
      }
    });
  }

  /// 旧口径的提交只有整库摘要：把它记在首张业务表上，其余表写零。
  String _legacyHeadDigestSplit(String digest, String table) =>
      table == versionedTableNames.first ? digest : revisionEmptyStateDigest;
}

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

/// 变更明细里要一起写的列：变化列加上同一列组的其余列（审查 S18）。
///
/// 跨列 CHECK 只约束总是一起写入的列，所以采集与远端应用都把整组带上；组里
/// 有列不在这一次的变化里时也照常带上，整组从同一行取值为准。
Set<String> expandedRevisionColumns(String table, Set<String> changed) {
  final columns = {...changed};
  final prefix = '$table.';
  for (final group in revisionColumnGroups) {
    final members = [
      for (final entry in group)
        if (entry.startsWith(prefix)) entry.substring(prefix.length),
    ];
    if (members.length < 2) continue;
    if (members.any(columns.contains)) columns.addAll(members);
  }
  return columns;
}
