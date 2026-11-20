import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/models/chat_message_payload.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/drift/tables.dart'
    show nonVersionedPersistentTableNames, revisionMetadataTablePrefixes;
import '../db/schema.dart' show schemaTableNames, schemaTables;
import '../db/sql.dart';
import '../db/raw_executor.dart';
import 'asset_store.dart';
import 'revision_models.dart';

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
/// 所以提交收尾一并带上（ADR-0014 第 2 条）。
const Set<String> revisionHistoryTables = {
  'revision_commit',
  'revision_change',
  'revision_ref',
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

/// 每张业务表的主键；版本化表目前都是单列主键。
final Map<String, String> versionedPrimaryKeys = {
  for (final table in schemaTables())
    if (versionedTableNames.contains(table.entityName))
      table.entityName: table.$primaryKey.single.name,
};

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
  String toString() => '请求 ${commit.requestId} 已提交为版本 ${commit.id}';
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
    this.checkpointEvery = 25,
  }) : assets = assets ?? AssetStore();

  final Clock clock;
  final AssetStore assets;

  /// 同库其他文件里的方法通过它取本对象的字段与方法。
  @override
  RevisionEngine get self => this;

  /// 周期检查点原来按提交编号的间隔触发；阶段 0 之后是否保留由
  /// `revision_projection.dart` 的空闲检查点决定。
  final int checkpointEvery;

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
        await insertRow(txn, 'revision_commit', {
          'id': 0,
          'parent_id': null,
          'generation': 0,
          'actor': 'system',
          'action': '初始基线',
          'kind': RevisionKind.baseline.value,
          'request_id': null,
          'restored_commit_id': null,
          'reverted_commit_id': null,
          'change_count': 0,
          'byte_length': 0,
          'conflict_count': 0,
          'created_at': now,
        });
        await insertRow(txn, 'revision_sequence', {
          'id': 1,
          'next_commit': 1,
        }, replace: true);
        await _writeCheckpoint(
          txn,
          commitId: 0,
          kind: 'initial',
          projection: projection,
        );
        await insertRow(txn, 'revision_ref', {
          'name': RevisionRef.headName,
          'commit_id': 0,
          'note': null,
          'created_at': now,
          'updated_at': now,
        }, replace: true);
        return;
      }

      final headRows = await selectRows(
        txn,
        'revision_ref',
        where: 'name = ?',
        whereArgs: [RevisionRef.headName],
      );
      if (headRows.isEmpty) {
        final maxId = heads.last['id']! as int;
        final now = formatDateTime(clock());
        await insertRow(txn, 'revision_ref', {
          'name': RevisionRef.headName,
          'commit_id': maxId,
          'note': null,
          'created_at': now,
          'updated_at': now,
        });
      }
      final sequence = await selectRows(txn, 'revision_sequence', limit: 1);
      if (sequence.isEmpty) {
        await insertRow(txn, 'revision_sequence', {
          'id': 1,
          'next_commit': (heads.last['id']! as int) + 1,
        });
      }
      final context = await selectRows(txn, 'revision_context', limit: 1);
      if (context.isEmpty) {
        await insertRow(txn, 'revision_context', {
          'id': 1,
          'active_commit': null,
          'capturing': 0,
          'suppress': 0,
        });
      } else if (context.first['active_commit'] != null) {
        // 上次进程中断留下的上下文不跨事务保留；打开时清掉，避免新写入
        // 被记到一个并不存在的提交上。
        await updateRow(txn, 'revision_context', {
          'active_commit': null,
          'capturing': 0,
          'suppress': 0,
        }, where: 'id = 1');
      }
    });
  }
}

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';
