import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/raw_executor.dart';
import 'asset_store.dart';
import 'revision_models.dart';

/// 参与版本采集的业务表，顺序按外键依赖排列：先被引用的表在前。
///
/// 新增业务表时必须在这里登记，并向 [installRevisionSchema] 提供主键；否则
/// 写入会成功但不进入数据变更历史。版本元数据、诊断记录、缓存与密钥不登记。
const List<String> versionedTableNames = [
  'profile',
  'learning_goal',
  'material',
  'material_page',
  'conversation',
  'message',
  'study_plan',
  'plan_item',
  'timetable_entry',
  'schedule_block',
  'study_session',
  'attempt',
  'assessment',
  'memory',
];

/// 每张业务表的主键；目前版本化表都是单列主键。
const Map<String, String> versionedPrimaryKeys = {
  'profile': 'id',
  'learning_goal': 'id',
  'material': 'id',
  'material_page': 'id',
  'conversation': 'id',
  'message': 'id',
  'study_plan': 'id',
  'plan_item': 'id',
  'timetable_entry': 'id',
  'schedule_block': 'id',
  'study_session': 'id',
  'attempt': 'id',
  'assessment': 'id',
  'memory': 'id',
};

/// 版本元数据与附件对象；不参与触发器采集，单独分类。
const Set<String> revisionMetadataTables = {
  'revision_commit',
  'revision_change',
  'revision_ref',
  'revision_checkpoint',
  'revision_context',
  'revision_sequence',
  'asset_object',
  'asset_chunk',
};

/// 保留在库里、但不参与数据版本采集的持久表：内部设置。
///
/// 新增表时必须在此、[versionedTableNames] 或 [revisionMetadataTables] 三者
/// 之一登记，架构测试会核对；否则写入会绕过数据变更历史。
const Set<String> nonVersionedPersistentTables = {'app_meta'};

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

/// 兼容 sqflite 的返回值；安装、采集、重建与恢复的核心实现都在本类。
class RevisionEngine {
  RevisionEngine({
    this.clock = systemClock,
    AssetStore? assets,
    this.checkpointEvery = 25,
  }) : assets = assets ?? AssetStore();

  final Clock clock;
  final AssetStore assets;
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

  Future<void> initialize(RawDatabase db) async {
    await installRevisionSchema(db);
    await _ensureMetadata(db);
  }

  Future<void> _ensureMetadata(RawDatabase db) async {
    await db.transaction((txn) async {
      final heads = await txn.query(
        'revision_commit',
        columns: ['id', 'generation'],
        orderBy: 'id',
      );
      if (heads.isEmpty) {
        final projection = await readProjection(txn);
        final now = formatDateTime(clock());
        await txn.insert('revision_commit', {
          'id': 0,
          'parent_id': null,
          'generation': 0,
          'actor': 'system',
          'action': '初始基线',
          'change_count': 0,
          'created_at': now,
        });
        await txn.insert('revision_sequence', {
          'id': 1,
          'next_commit': 1,
        }, conflictAlgorithm: ConflictAction.replace);
        await _writeCheckpoint(
          txn,
          commitId: 0,
          kind: 'initial',
          projection: projection,
        );
        await txn.insert('revision_ref', {
          'name': RevisionRef.headName,
          'commit_id': 0,
          'note': null,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAction.replace);
        return;
      }

      final headRows = await txn.query(
        'revision_ref',
        where: 'name = ?',
        whereArgs: [RevisionRef.headName],
      );
      if (headRows.isEmpty) {
        final maxId = heads.last['id']! as int;
        final now = formatDateTime(clock());
        await txn.insert('revision_ref', {
          'name': RevisionRef.headName,
          'commit_id': maxId,
          'note': null,
          'created_at': now,
          'updated_at': now,
        });
      }
      final sequence = await txn.query('revision_sequence', limit: 1);
      if (sequence.isEmpty) {
        await txn.insert('revision_sequence', {
          'id': 1,
          'next_commit': (heads.last['id']! as int) + 1,
        });
      }
      final context = await txn.query('revision_context', limit: 1);
      if (context.isEmpty) {
        await txn.insert('revision_context', {
          'id': 1,
          'active_commit': null,
          'suppress': 0,
        });
      } else if (context.first['active_commit'] != null) {
        // 上次进程中断留下的上下文不跨事务保留；打开时清掉，避免新写入
        // 被记到一个并不存在的提交上。
        await txn.update('revision_context', {
          'active_commit': null,
          'suppress': 0,
        }, where: 'id = 1');
      }
    });
  }

  Future<int> headId(RawExecutor executor) async {
    final rows = await executor.query(
      'revision_ref',
      columns: ['commit_id'],
      where: 'name = ?',
      whereArgs: [RevisionRef.headName],
    );
    if (rows.isEmpty) throw StateError('数据版本缺少 HEAD');
    return rows.first['commit_id']! as int;
  }

  Future<RevisionCommit?> commitById(RawExecutor executor, int id) async {
    final rows = await executor.query(
      'revision_commit',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCommit.fromRow(rows.first);
  }

  Future<RevisionCommit?> commitByRequest(
    RawExecutor executor,
    String requestId,
  ) async {
    final rows = await executor.query(
      'revision_commit',
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    return rows.isEmpty ? null : RevisionCommit.fromRow(rows.first);
  }

  Future<List<RevisionCommit>> commits(
    RawExecutor executor, {
    int? limit,
  }) async {
    final rows = await executor.query(
      'revision_commit',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  Future<List<RevisionChange>> changesFor(
    RawExecutor executor,
    int commitId,
  ) async {
    final rows = await executor.query(
      'revision_change',
      where: 'commit_id = ?',
      whereArgs: [commitId],
      orderBy: 'seq',
    );
    return rows.map(RevisionChange.fromRow).toList(growable: false);
  }

  /// 当前命令在事务里分配的提交编号；没有进行中的命令时为空。
  Future<int?> activeCommit(RawExecutor executor) async {
    final rows = await executor.query(
      'revision_context',
      columns: ['active_commit'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['active_commit'] as int?;
  }

  /// 仍然可以按提交撤销的编号：存在、属于当前代次、没有被撤销过。
  ///
  /// 整版恢复或导入会推进代次，更早的提交不再进入可撤销范围；界面的回执
  /// 也用这个方法判断是否还显示撤销按钮。
  Future<Set<int>> activeCommits(
    RawExecutor executor,
    Iterable<int> ids,
  ) async {
    final values = ids.toSet().toList(growable: false);
    if (values.isEmpty) return const {};
    final head = await commitById(executor, await headId(executor));
    if (head == null) return const {};
    final placeholders = List.filled(values.length, '?').join(', ');
    final rows = await executor.rawQuery(
      '''
      SELECT c.id FROM revision_commit c
      WHERE c.id IN ($placeholders) AND c.generation = ?
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ''',
      [...values, head.generation],
    );
    return {for (final row in rows) row['id']! as int};
  }

  /// 当前代次里还没被撤销的提交，按编号倒序；撤销提交本身不在其中。
  ///
  /// 安排页的“AI 的改动”从这里挑出要展示的写入，数据版本页读的是完整历史。
  Future<List<RevisionCommit>> undoableCommits(RawExecutor executor) async {
    final head = await commitById(executor, await headId(executor));
    if (head == null) return const [];
    final rows = await executor.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      WHERE c.id != 0 AND c.generation = ? AND c.reverted_commit_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ORDER BY c.id DESC
      ''',
      [head.generation],
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  /// 指定动作、且改动落在指定表里的可撤销提交，按编号倒序。
  ///
  /// 与 [undoableCommits] 的区别是筛选放在同一条查询里：安排页只展示真正写入
  /// 记忆或学习事项的提交，原先要先读全部可撤销提交，再为每条读一次变更明细。
  Future<List<RevisionCommit>> receiptCommits(
    RawExecutor executor, {
    required Set<String> actions,
    required Set<String> tables,
  }) async {
    if (actions.isEmpty || tables.isEmpty) return const [];
    final head = await commitById(executor, await headId(executor));
    if (head == null) return const [];
    final actionSlots = List.filled(actions.length, '?').join(', ');
    final tableSlots = List.filled(tables.length, '?').join(', ');
    final rows = await executor.rawQuery(
      '''
      SELECT c.* FROM revision_commit c
      WHERE c.id != 0 AND c.generation = ? AND c.reverted_commit_id IS NULL
        AND c.action IN ($actionSlots)
        AND EXISTS (
          SELECT 1 FROM revision_change ch
          WHERE ch.commit_id = c.id AND ch.table_name IN ($tableSlots)
        )
        AND NOT EXISTS (
          SELECT 1 FROM revision_commit u WHERE u.reverted_commit_id = c.id
        )
      ORDER BY c.id DESC
      ''',
      [head.generation, ...actions, ...tables],
    );
    return rows.map(RevisionCommit.fromRow).toList(growable: false);
  }

  Future<List<RevisionRef>> refs(RawExecutor executor) async {
    final rows = await executor.query(
      'revision_ref',
      where: 'name != ?',
      whereArgs: [RevisionRef.headName],
      orderBy: 'created_at DESC',
    );
    return rows.map(RevisionRef.fromRow).toList(growable: false);
  }

  Future<List<RevisionCheckpoint>> checkpoints(
    RawExecutor executor, {
    int? limit,
  }) async {
    final rows = await executor.query(
      'revision_checkpoint',
      orderBy: 'commit_id DESC, id DESC',
      limit: limit,
    );
    return rows.map(RevisionCheckpoint.fromRow).toList(growable: false);
  }

  /// 开始一次命令：分配提交编号并把上下文写进当前事务。
  Future<int> beginCommand(RawExecutor txn, {String? requestId}) async {
    if (requestId != null) {
      final existing = await commitByRequest(txn, requestId);
      if (existing != null) throw RevisionDuplicateRequest(existing);
    }
    final rows = await txn.query('revision_sequence', limit: 1);
    if (rows.isEmpty) throw StateError('数据版本缺少提交编号');
    final id = rows.first['next_commit']! as int;
    await txn.update('revision_sequence', {
      'next_commit': id + 1,
    }, where: 'id = 1');
    await txn.update('revision_context', {
      'active_commit': id,
      'suppress': 0,
    }, where: 'id = 1');
    return id;
  }

  /// 结束一次命令：合并暂存变化，有净变化才追加提交并推进 `HEAD`。
  Future<RevisionCommit?> finishCommand(
    RawExecutor txn,
    int commitId, {
    required String action,
    String actor = 'user',
    String? requestId,
  }) async {
    final net = await _collect(txn, commitId);
    await _clearStage(txn, commitId);

    if (net.isEmpty) {
      // 没有业务净变化的写入不形成提交，也不留下可撤销的回执。
      await _clearContext(txn);
      return null;
    }

    final head = await headId(txn);
    final parent = await commitById(txn, head);
    final now = formatDateTime(clock());
    final commit = RevisionCommit(
      id: commitId,
      parentId: head,
      generation: parent?.generation ?? 0,
      actor: actor,
      action: action,
      requestId: requestId,
      changeCount: net.length,
      createdAt: clock(),
    );
    await txn.insert('revision_commit', {
      'id': commit.id,
      'parent_id': commit.parentId,
      'generation': commit.generation,
      'actor': commit.actor,
      'action': commit.action,
      'request_id': commit.requestId,
      'restored_commit_id': null,
      'reverted_commit_id': null,
      'change_count': commit.changeCount,
      'created_at': now,
    });
    await _insertChanges(txn, commit.id, net);
    await txn.update(
      'revision_ref',
      {'commit_id': commit.id, 'updated_at': now},
      where: 'name = ?',
      whereArgs: [RevisionRef.headName],
    );
    await _clearContext(txn);

    if (checkpointEvery > 0 && commit.id % checkpointEvery == 0) {
      final projection = await projectionAt(txn, commit.id);
      await _writeCheckpoint(
        txn,
        commitId: commit.id,
        kind: 'periodic',
        projection: projection,
      );
    }
    return commit;
  }

  Future<void> _clearContext(RawExecutor txn) async {
    await txn.update('revision_context', {
      'active_commit': null,
      'suppress': 0,
    }, where: 'id = 1');
  }

  Future<void> _clearStage(RawExecutor txn, int commitId) async {
    final schema = await tables(txn);
    for (final table in schema.values) {
      await txn.delete(
        table.stageTable,
        where: 'commit_id = ?',
        whereArgs: [commitId],
      );
    }
  }

  Future<List<RevisionChange>> _collect(RawExecutor txn, int commitId) async {
    final schema = await tables(txn);
    final result = <RevisionChange>[];
    var seq = 1;
    for (final table in schema.values) {
      final rows = await txn.query(
        table.stageTable,
        where: 'commit_id = ?',
        whereArgs: [commitId],
        orderBy: 'seq',
      );
      if (rows.isEmpty) continue;
      final groups = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final key = row['row_key']! as String;
        groups.putIfAbsent(key, () => []).add(row);
      }
      for (final entry in groups.entries) {
        final group = entry.value;
        final first = group.first;
        final last = group.last;
        final firstOp = first['op']! as String;
        final lastOp = last['op']! as String;
        TypedRow? before;
        TypedRow? after;
        if (firstOp != 'insert') {
          before = _sideRow(first, 'o_', table.columns);
        }
        if (lastOp != 'delete') {
          after = _sideRow(last, 'n_', table.columns);
        }
        if (before == null && after == null) continue;
        if (before != null && after != null) {
          final changed = changedColumns(before, after);
          if (changed.isEmpty) continue;
          result.add(
            RevisionChange(
              commitId: commitId,
              seq: seq++,
              table: table.name,
              rowKey: entry.key,
              op: 'update',
              before: projectColumns(before, changed),
              after: projectColumns(after, changed),
            ),
          );
          continue;
        }
        result.add(
          RevisionChange(
            commitId: commitId,
            seq: seq++,
            table: table.name,
            rowKey: entry.key,
            op: before == null ? 'insert' : 'delete',
            before: before,
            after: after,
          ),
        );
      }
    }
    return result;
  }

  TypedRow _sideRow(
    Map<String, Object?> stage,
    String prefix,
    List<String> columns,
  ) => {
    for (final column in columns)
      column: RevisionValue.of(stage['$prefix$column']),
  };

  Future<void> _insertChanges(
    RawExecutor txn,
    int commitId,
    List<RevisionChange> changes,
  ) async {
    for (final change in changes) {
      await txn.insert('revision_change', change.toRow());
    }
  }

  /// 读取当前全部业务表；投影按表名与主键字符串索引。
  Future<Projection> readProjection(RawExecutor executor) async {
    final schema = await tables(executor);
    final projection = <String, Map<String, TypedRow>>{};
    for (final table in schema.values) {
      final rows = await executor.query(table.name);
      final tableRows = <String, TypedRow>{};
      for (final row in rows) {
        final key = '${row[table.primaryKey]}';
        tableRows[key] = typedRow(row);
      }
      projection[table.name] = tableRows;
    }
    return projection;
  }

  Future<Projection> projectionAt(RawExecutor executor, int target) {
    return _rebuild(executor, target);
  }

  Future<Projection> _rebuild(RawExecutor executor, int target) async {
    final targetCommit = await commitById(executor, target);
    if (targetCommit == null) throw RevisionCorruption('提交 $target 不存在');
    final checkpoint = await _latestCheckpoint(executor, target);
    final projection = decodeProjection(checkpoint.projectionJson);
    final expected = _checksum(
      checkpoint.projectionJson,
      checkpoint.assetHashes,
    );
    if (expected != checkpoint.checksum) {
      throw RevisionCorruption('检查点 ${checkpoint.id} 校验值不一致');
    }
    final rows = await executor.query(
      'revision_change',
      where: 'commit_id > ? AND commit_id <= ?',
      whereArgs: [checkpoint.commitId, target],
      orderBy: 'commit_id, seq',
    );
    for (final row in rows) {
      _applyChange(projection, RevisionChange.fromRow(row));
    }
    return projection;
  }

  Future<RevisionCheckpoint> _latestCheckpoint(
    RawExecutor executor,
    int target,
  ) async {
    final rows = await executor.query(
      'revision_checkpoint',
      where: 'commit_id <= ?',
      whereArgs: [target],
      orderBy: 'commit_id DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      throw RevisionCorruption('提交 $target 之前没有可用检查点');
    }
    return RevisionCheckpoint.fromRow(rows.first);
  }

  void _applyChange(Projection projection, RevisionChange change) {
    final table = projection.putIfAbsent(change.table, () => {});
    final current = table[change.rowKey];
    switch (change.op) {
      case 'insert':
        if (current != null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期新增但已经存在',
          );
        }
        table[change.rowKey] = Map.of(change.after!);
        return;
      case 'delete':
        if (current == null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期删除但已经不存在',
          );
        }
        _verifyExpected(current, change.before!, change);
        table.remove(change.rowKey);
        return;
      case 'update':
        if (current == null) {
          throw RevisionCorruption(
            '${change.table}/${change.rowKey} 预期更新但已经不存在',
          );
        }
        _verifyExpected(current, change.before!, change);
        final next = Map<String, RevisionValue>.of(current);
        for (final entry in change.after!.entries) {
          next[entry.key] = entry.value;
        }
        table[change.rowKey] = next;
        return;
      default:
        throw RevisionCorruption('未知的变更类型 ${change.op}');
    }
  }

  void _verifyExpected(
    TypedRow current,
    TypedRow before,
    RevisionChange change,
  ) {
    for (final entry in before.entries) {
      final value = current[entry.key];
      if (value == null || !value.equals(entry.value)) {
        throw RevisionCorruption(
          '${change.table}/${change.rowKey}.${entry.key} 与预期旧值不一致',
        );
      }
    }
  }

  Future<RevisionDiff> compare(RawExecutor executor, int from, int to) async {
    final before = await _rebuild(executor, from);
    final after = await _rebuild(executor, to);
    return diffProjections(before, after, from: from, to: to);
  }

  RevisionDiff diffProjections(
    Projection before,
    Projection after, {
    int from = 0,
    int to = 0,
  }) {
    final entries = <RevisionDiffEntry>[];
    for (final table in versionedTableNames) {
      final left = before[table] ?? const <String, TypedRow>{};
      final right = after[table] ?? const <String, TypedRow>{};
      final keys = <String>{...left.keys, ...right.keys};
      for (final key in keys) {
        final oldRow = left[key];
        final newRow = right[key];
        if (oldRow == null && newRow == null) continue;
        if (oldRow == null) {
          entries.add(
            RevisionDiffEntry(table: table, rowKey: key, op: 'insert'),
          );
          continue;
        }
        if (newRow == null) {
          entries.add(
            RevisionDiffEntry(table: table, rowKey: key, op: 'delete'),
          );
          continue;
        }
        final changed = changedColumns(oldRow, newRow);
        if (changed.isEmpty) continue;
        entries.add(
          RevisionDiffEntry(
            table: table,
            rowKey: key,
            op: 'update',
            columns: changed,
          ),
        );
      }
    }
    return RevisionDiff(before: from, after: to, entries: entries);
  }

  Future<RevisionRestorePreview> previewRestore(
    RawExecutor executor,
    int target,
  ) async {
    final targetCommit = await commitById(executor, target);
    if (targetCommit == null) throw RevisionCorruption('提交 $target 不存在');
    final head = await headId(executor);
    final before = await readProjection(executor);
    final after = await _rebuild(executor, target);
    return RevisionRestorePreview(
      target: targetCommit,
      head: head,
      diff: diffProjections(before, after, from: head, to: target),
    );
  }

  /// 整版恢复：清空并装入已校验的目标投影，追加一条恢复提交。
  ///
  /// 清除与装入在同一个事务里完成，触发器在此期间被上下文标记为暂停，避免
  /// 把整库删除与重插记成逐行历史；净变化由事务内比较后一次性写入。
  Future<RevisionCommit> restore(
    RawDatabase db,
    int target, {
    required int expectedHead,
    String action = '恢复版本',
    String actor = 'user',
  }) async {
    final targetProjection = await _rebuild(db, target);
    final missing = <String>[];
    for (final hash in AssetStore.hashesInProjection(targetProjection)) {
      if (!await assets.verify(db, hash)) missing.add(hash);
    }
    if (missing.isNotEmpty) {
      throw RevisionCorruption('目标版本的附件校验失败：${missing.take(3).join(', ')}');
    }
    return _replaceWithProjection(
      db,
      targetProjection,
      expectedHead: expectedHead,
      action: action,
      actor: actor,
      restoredCommitId: target,
    );
  }

  /// 导入当前数据包：不依赖历史，把已校验的投影装进当前库并追加提交。
  Future<RevisionCommit> importProjection(
    RawDatabase db,
    Projection projection, {
    required int expectedHead,
    Map<String, Uint8List> attachments = const {},
    String action = '导入数据',
    String actor = 'user',
  }) {
    return _replaceWithProjection(
      db,
      projection,
      expectedHead: expectedHead,
      action: action,
      actor: actor,
      attachments: attachments,
    );
  }

  Future<RevisionCommit> _replaceWithProjection(
    RawDatabase db,
    Projection targetProjection, {
    required int expectedHead,
    required String action,
    required String actor,
    int? restoredCommitId,
    Map<String, Uint8List> attachments = const {},
  }) async {
    return db.transaction((txn) async {
      final head = await headId(txn);
      if (head != expectedHead) {
        throw RevisionStaleHead(expected: expectedHead, actual: head);
      }
      final commitId = await beginCommand(txn);
      await txn.update('revision_context', {
        'active_commit': commitId,
        'suppress': 1,
      }, where: 'id = 1');
      for (final entry in attachments.entries) {
        await assets.putBytes(txn, entry.key, entry.value);
      }
      final current = await readProjection(txn);
      await _replaceProjection(txn, targetProjection);
      await _verifyProjection(txn, targetProjection);
      final changes = _changesFromDiff(current, targetProjection, commitId);
      final parent = await commitById(txn, head);
      final now = formatDateTime(clock());
      final commit = RevisionCommit(
        id: commitId,
        parentId: head,
        generation: (parent?.generation ?? 0) + 1,
        actor: actor,
        action: action,
        restoredCommitId: restoredCommitId,
        changeCount: changes.length,
        createdAt: clock(),
      );
      await txn.insert('revision_commit', {
        'id': commit.id,
        'parent_id': commit.parentId,
        'generation': commit.generation,
        'actor': commit.actor,
        'action': commit.action,
        'request_id': null,
        'restored_commit_id': restoredCommitId,
        'reverted_commit_id': null,
        'change_count': commit.changeCount,
        'created_at': now,
      });
      await _insertChanges(txn, commit.id, changes);
      await txn.update(
        'revision_ref',
        {'commit_id': commit.id, 'updated_at': now},
        where: 'name = ?',
        whereArgs: [RevisionRef.headName],
      );
      await _clearContext(txn);
      return commit;
    });
  }

  Future<void> _replaceProjection(
    RawExecutor txn,
    Projection projection,
  ) async {
    for (final table in versionedTableNames.reversed) {
      await txn.delete(table);
    }
    for (final table in versionedTableNames) {
      final rows = projection[table] ?? const <String, TypedRow>{};
      for (final row in rows.values) {
        await txn.insert(table, sqliteRow(row));
      }
    }
    final violations = await txn.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw RevisionCorruption('恢复后的数据存在外键错误');
    }
  }

  Future<void> _verifyProjection(RawExecutor txn, Projection expected) async {
    final actual = await readProjection(txn);
    for (final table in versionedTableNames) {
      final want = expected[table] ?? const <String, TypedRow>{};
      final got = actual[table] ?? const <String, TypedRow>{};
      if (want.length != got.length) {
        throw RevisionCorruption('恢复后的 $table 行数不一致');
      }
      for (final entry in want.entries) {
        final row = got[entry.key];
        if (row == null || !typedRowsEqual(row, entry.value)) {
          throw RevisionCorruption('恢复后的 $table/${entry.key} 内容不一致');
        }
      }
    }
  }

  List<RevisionChange> _changesFromDiff(
    Projection before,
    Projection after,
    int commitId,
  ) {
    final changes = <RevisionChange>[];
    var seq = 1;
    for (final table in versionedTableNames) {
      final left = before[table] ?? const <String, TypedRow>{};
      final right = after[table] ?? const <String, TypedRow>{};
      final keys = <String>{...left.keys, ...right.keys};
      for (final key in keys) {
        final oldRow = left[key];
        final newRow = right[key];
        if (oldRow == null && newRow == null) continue;
        if (oldRow == null) {
          changes.add(
            RevisionChange(
              commitId: commitId,
              seq: seq++,
              table: table,
              rowKey: key,
              op: 'insert',
              after: newRow,
            ),
          );
          continue;
        }
        if (newRow == null) {
          changes.add(
            RevisionChange(
              commitId: commitId,
              seq: seq++,
              table: table,
              rowKey: key,
              op: 'delete',
              before: oldRow,
            ),
          );
          continue;
        }
        final changed = changedColumns(oldRow, newRow);
        if (changed.isEmpty) continue;
        changes.add(
          RevisionChange(
            commitId: commitId,
            seq: seq++,
            table: table,
            rowKey: key,
            op: 'update',
            before: projectColumns(oldRow, changed),
            after: projectColumns(newRow, changed),
          ),
        );
      }
    }
    return changes;
  }

  Future<void> _writeCheckpoint(
    RawExecutor txn, {
    required int commitId,
    required String kind,
    required Projection projection,
  }) async {
    final projectionJson = encodeProjection(projection);
    final hashes = AssetStore.hashesInProjection(projection).toList()..sort();
    await txn.insert('revision_checkpoint', {
      'kind': kind,
      'commit_id': commitId,
      'projection_json': projectionJson,
      'asset_hashes_json': jsonEncode(hashes),
      'checksum': _checksum(projectionJson, hashes),
      'created_at': formatDateTime(clock()),
    });
  }

  String _checksum(String projectionJson, List<String> hashes) {
    final input = '$projectionJson\n${hashes.join(',')}';
    return sha256.convert(utf8.encode(input)).toString();
  }

  Future<RevisionRef> nameCommit(
    RawDatabase db,
    int commitId, {
    required String name,
    String? note,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == RevisionRef.headName) {
      throw ArgumentError('版本名称不能为空，也不能叫 HEAD');
    }
    final commit = await commitById(db, commitId);
    if (commit == null) throw RevisionCorruption('提交 $commitId 不存在');
    return db.transaction((txn) async {
      final now = formatDateTime(clock());
      await txn.insert('revision_ref', {
        'name': trimmed,
        'commit_id': commitId,
        'note': note?.trim(),
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAction.replace);
      final projection = await projectionAt(txn, commitId);
      await _writeCheckpoint(
        txn,
        commitId: commitId,
        kind: 'named',
        projection: projection,
      );
      return RevisionRef(
        name: trimmed,
        commitId: commitId,
        note: note?.trim(),
        createdAt: clock(),
        updatedAt: clock(),
      );
    });
  }

  Future<void> deleteName(RawDatabase db, String name) async {
    if (name == RevisionRef.headName) throw ArgumentError('不能删除 HEAD');
    await db.transaction((txn) async {
      final rows = await txn.query(
        'revision_ref',
        where: 'name = ?',
        whereArgs: [name],
      );
      if (rows.isEmpty) return;
      final commitId = rows.first['commit_id']! as int;
      await txn.delete('revision_ref', where: 'name = ?', whereArgs: [name]);
      final others = await txn.query(
        'revision_ref',
        where: 'commit_id = ?',
        whereArgs: [commitId],
      );
      if (others.isEmpty) {
        await txn.delete(
          'revision_checkpoint',
          where: 'kind = ? AND commit_id = ?',
          whereArgs: ['named', commitId],
        );
      }
    });
  }

  /// 去掉消息里指向已删除提交或已失去撤销入口的回执编号。
  ///
  /// 清理与裁剪在维护事务里直接删历史，不经过触发器；消息如果在同一个事务里
  /// 静默改写，检查点与重建结果就和当前数据不一致。因此回执清理放在清理之后，
  /// 由调用方开一条普通提交，让触发器照常采集这次改写。没有需要清理的编号时
  /// 不更新任何消息，也不会形成提交。
  Future<int> stripDeadReceipts(RawExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT DISTINCT commit_id FROM revision_change',
    );
    final live = {for (final row in rows) row['commit_id']! as int};
    final messages = await executor.query(
      'message',
      columns: ['id', 'structured_json'],
      where: "structured_json LIKE '%commit_id%'",
    );
    var changed = 0;
    for (final row in messages) {
      final structured = _decodeStructuredJson(row['structured_json']);
      if (structured == null) continue;
      if (!_removeDeadReceipts(structured, live)) continue;
      await executor.update(
        'message',
        {'structured_json': jsonEncode(structured)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      changed++;
    }
    return changed;
  }

  Map<String, Object?>? _decodeStructuredJson(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    } on FormatException {
      return null;
    }
  }

  /// 回执只保留在仍能撤销的提交上；记忆卡片去掉编号后不再显示撤销入口。
  bool _removeDeadReceipts(Map<String, Object?> structured, Set<int> live) {
    var changed = false;
    final operations = structured['operations'];
    if (operations is List) {
      final kept = [
        for (final item in operations)
          if (item is! Map ||
              item['commit_id'] is! int ||
              live.contains(item['commit_id']))
            item,
      ];
      if (kept.length != operations.length) {
        structured['operations'] = kept;
        changed = true;
      }
    }
    final memoryItems = structured['memory_items'];
    if (memoryItems is List) {
      final updated = <Object?>[];
      var itemsChanged = false;
      for (final item in memoryItems) {
        if (item is Map &&
            item['commit_id'] is int &&
            !live.contains(item['commit_id'])) {
          updated.add(
            <String, Object?>{
              for (final entry in item.entries)
                if (entry.key is String) entry.key as String: entry.value,
            }..remove('commit_id'),
          );
          itemsChanged = true;
        } else {
          updated.add(item);
        }
      }
      if (itemsChanged) {
        structured['memory_items'] = updated;
        changed = true;
      }
    }
    return changed;
  }

  /// 清理历史：以当前数据为新基线，删除全部提交明细、命名版本与检查点。
  Future<void> clearHistory(RawDatabase db) async {
    await db.transaction((txn) async {
      final head = await headId(txn);
      final projection = await readProjection(txn);
      final commit = await commitById(txn, head);
      if (commit == null) throw RevisionCorruption('HEAD $head 不存在');
      await txn.delete('revision_change');
      await txn.delete('revision_checkpoint');
      await txn.delete('revision_commit', where: 'id != ?', whereArgs: [head]);
      await txn.delete(
        'revision_ref',
        where: 'name != ?',
        whereArgs: [RevisionRef.headName],
      );
      final now = formatDateTime(clock());
      await txn.update(
        'revision_commit',
        {
          'parent_id': null,
          'generation': commit.generation + 1,
          'action': '清理后保留',
          'reverted_commit_id': null,
          'restored_commit_id': null,
          'change_count': 0,
        },
        where: 'id = ?',
        whereArgs: [head],
      );
      await txn.update(
        'revision_ref',
        {'commit_id': head, 'updated_at': now},
        where: 'name = ?',
        whereArgs: [RevisionRef.headName],
      );
      await _writeCheckpoint(
        txn,
        commitId: head,
        kind: 'initial',
        projection: projection,
      );
      await txn.update('revision_sequence', {
        'next_commit': head + 1,
      }, where: 'id = 1');
      await _collectGarbage(txn, projection, currentHead: head);
    });
  }

  /// 有界留存：保留最近若干提交、命名版本与 `HEAD`，更早的历史先固化成
  /// 基线检查点再删除。达到容量上限时继续减少保留提交数。
  Future<RevisionRetentionResult> prune(
    RawDatabase db, {
    int keepCommits = 100,
    int? maxBytes,
  }) async {
    if (keepCommits < 1) throw RangeError.range(keepCommits, 1, null);
    var keep = keepCommits;
    while (true) {
      final result = await _pruneOnce(db, keep);
      if (maxBytes == null) return result;
      var size = await databaseBytes(db);
      if (size > maxBytes) {
        // 删除后的页空间不会自动归还；预算判断前先回收一次。
        await db.execute('VACUUM');
        size = await databaseBytes(db);
      }
      if (size <= maxBytes || keep <= 1) {
        return RevisionRetentionResult(
          removedCommits: result.removedCommits,
          removedCheckpoints: result.removedCheckpoints,
          removedAssets: result.removedAssets,
          keptFrom: result.keptFrom,
          databaseBytes: size,
        );
      }
      keep = keep ~/ 2;
      if (keep < 1) keep = 1;
    }
  }

  Future<RevisionRetentionResult> _pruneOnce(RawDatabase db, int keep) async {
    return db.transaction((txn) async {
      final head = await headId(txn);
      final all = await commits(txn);
      final named = await refs(txn);
      final namedCommits = {for (final ref in named) ref.commitId};
      final ids = all.map((commit) => commit.id).toList()..sort();
      final keepIds = <int>{head, ...namedCommits};
      for (final id in ids.reversed) {
        if (keepIds.length >= keep + namedCommits.length + 1) break;
        keepIds.add(id);
      }
      if (ids.length <= keepIds.length) {
        final projection = await readProjection(txn);
        await _collectGarbage(txn, projection, currentHead: head);
        return RevisionRetentionResult(
          removedCommits: 0,
          removedCheckpoints: 0,
          removedAssets: 0,
          keptFrom: ids.isEmpty ? 0 : ids.first,
          databaseBytes: await databaseBytes(txn),
        );
      }
      final oldest = keepIds.reduce((a, b) => a < b ? a : b);
      final projection = await projectionAt(txn, oldest);
      await _writeCheckpoint(
        txn,
        commitId: oldest,
        kind: 'trimmed',
        projection: projection,
      );
      final verified = await projectionAt(txn, oldest);
      if (!_sameProjection(projection, verified)) {
        throw RevisionCorruption('裁剪前的新基线校验失败，已取消本次清理');
      }
      final beforeCommits = await txn.query('revision_commit');
      final beforeCheckpoints = await txn.query('revision_checkpoint');
      await txn.delete(
        'revision_change',
        where: 'commit_id < ?',
        whereArgs: [oldest],
      );
      await txn.delete(
        'revision_checkpoint',
        where: 'commit_id < ? AND kind != ?',
        whereArgs: [oldest, 'named'],
      );
      final removed = <int>[];
      for (final commit in beforeCommits) {
        final id = commit['id']! as int;
        if (id >= oldest || id == head || namedCommits.contains(id)) continue;
        await txn.delete('revision_commit', where: 'id = ?', whereArgs: [id]);
        removed.add(id);
      }
      // 被删掉的中间提交不再作为父提交；保留提交的父指针置空。
      if (removed.isEmpty) {
        await txn.update(
          'revision_commit',
          {'parent_id': null},
          where: 'id = ?',
          whereArgs: [oldest],
        );
      } else {
        await txn.update(
          'revision_commit',
          {'parent_id': null},
          where:
              'id = ? OR parent_id IN (${removed.map((_) => '?').join(',')})',
          whereArgs: [oldest, ...removed],
        );
      }
      final keptProjection = await readProjection(txn);
      final removedAssets = await _collectGarbage(
        txn,
        keptProjection,
        currentHead: head,
      );
      return RevisionRetentionResult(
        removedCommits: removed.length,
        removedCheckpoints:
            beforeCheckpoints.length -
            (await txn.query('revision_checkpoint')).length,
        removedAssets: removedAssets,
        keptFrom: oldest,
        databaseBytes: await databaseBytes(txn),
      );
    });
  }

  bool _sameProjection(Projection left, Projection right) {
    for (final table in versionedTableNames) {
      final a = left[table] ?? const <String, TypedRow>{};
      final b = right[table] ?? const <String, TypedRow>{};
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        final row = b[entry.key];
        if (row == null || !typedRowsEqual(row, entry.value)) return false;
      }
    }
    return true;
  }

  Future<int> _collectGarbage(
    RawExecutor executor,
    Projection current, {
    required int currentHead,
  }) async {
    final keep = <String>{...AssetStore.hashesInProjection(current)};
    final checkpoints = await executor.query(
      'revision_checkpoint',
      columns: ['asset_hashes_json'],
    );
    for (final row in checkpoints) {
      keep.addAll(
        decodeStringList(row['asset_hashes_json'] as String? ?? '[]'),
      );
    }
    final changes = await executor.query(
      'revision_change',
      columns: ['before_json', 'after_json'],
    );
    for (final row in changes) {
      keep.addAll(
        AssetStore.hashesInChanges([
          RevisionChange(
            commitId: currentHead,
            seq: 0,
            table: '',
            rowKey: '',
            op: 'update',
            before: decodeTypedRow(row['before_json'] as String?),
            after: decodeTypedRow(row['after_json'] as String?),
          ),
        ]),
      );
    }
    return assets.collectGarbage(executor, keep: keep);
  }

  Future<int> databaseBytes(RawExecutor executor) async {
    final page = await executor.rawQuery('PRAGMA page_count');
    final size = await executor.rawQuery('PRAGMA page_size');
    final count = page.isEmpty ? 0 : page.first.values.first! as int;
    final bytes = size.isEmpty ? 0 : size.first.values.first! as int;
    return count * bytes;
  }

  /// 检查点、变更明细与当前投影引用的附件是否都能读出并通过哈希校验。
  ///
  /// 只查检查点会漏掉检查点之间提交里引用的附件；备份时把整库带走，所以
  /// 三类引用都要核对，缺任何一张都算备份不完整。
  Future<List<String>> verifyAssets(RawExecutor executor) async {
    final missing = <String>[];
    final all = <String>{};
    final checkpoints = await executor.query(
      'revision_checkpoint',
      columns: ['asset_hashes_json'],
    );
    for (final row in checkpoints) {
      all.addAll(decodeStringList(row['asset_hashes_json'] as String? ?? '[]'));
    }
    final changes = await executor.query(
      'revision_change',
      columns: ['before_json', 'after_json'],
    );
    for (final row in changes) {
      all.addAll(
        AssetStore.hashesInChanges([
          RevisionChange(
            commitId: 0,
            seq: 0,
            table: '',
            rowKey: '',
            op: 'update',
            before: decodeTypedRow(row['before_json'] as String?),
            after: decodeTypedRow(row['after_json'] as String?),
          ),
        ]),
      );
    }
    all.addAll(AssetStore.hashesInProjection(await readProjection(executor)));
    for (final hash in all) {
      if (!await assets.verify(executor, hash)) missing.add(hash);
    }
    return missing;
  }
}

/// 创建采集暂存表、触发器和版本上下文；打开库时执行，重复执行保持幂等。
Future<void> installRevisionSchema(RawDatabase db) async {
  final engine = RevisionEngine();
  final schema = await engine.tables(db);
  final existing = await db.query(
    'sqlite_master',
    columns: ['name'],
    where: "type = 'trigger' AND name NOT LIKE 'sqlite_%'",
  );
  for (final row in existing) {
    // 打开库时只保留本程序重建的采集触发器；随库带来的其他触发器一律清掉，
    // 不给恢复后的第一次写入留下执行机会。
    await db.execute('DROP TRIGGER IF EXISTS "${row['name']}"');
  }
  for (final table in schema.values) {
    final stage = table.stageTable;
    final columns = <String>[
      'seq INTEGER PRIMARY KEY AUTOINCREMENT',
      'commit_id INTEGER NOT NULL',
      'row_key TEXT NOT NULL',
      'op TEXT NOT NULL',
      for (final column in table.columns) ...[
        _quote('o_$column'),
        _quote('n_$column'),
      ],
    ];
    await db.execute(
      'CREATE TABLE IF NOT EXISTS "$stage" (${columns.join(', ')})',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS "idx_${stage}_commit" '
      'ON "$stage"(commit_id, seq)',
    );
    await _createTriggers(db, table);
  }

  await db.insert('revision_context', {
    'id': 1,
    'active_commit': null,
    'suppress': 0,
  }, conflictAlgorithm: ConflictAction.ignore);
  await db.insert('revision_sequence', {
    'id': 1,
    'next_commit': 1,
  }, conflictAlgorithm: ConflictAction.ignore);
}

Future<void> _createTriggers(RawDatabase db, RevisionTable table) async {
  final q = _quote;
  final stage = q(table.stageTable);
  final source = q(table.name);
  final when =
      '(SELECT active_commit FROM revision_context WHERE id = 1) IS NOT NULL '
      'AND (SELECT suppress FROM revision_context WHERE id = 1) = 0';
  final allOld = table.columns.map((c) => q('o_$c')).join(', ');
  final allNew = table.columns.map((c) => q('n_$c')).join(', ');
  final oldValues = table.columns.map((c) => 'OLD.${q(c)}').join(', ');
  final newValues = table.columns.map((c) => 'NEW.${q(c)}').join(', ');
  final key = 'CAST(NEW.${q(table.primaryKey)} AS TEXT)';
  final oldKey = 'CAST(OLD.${q(table.primaryKey)} AS TEXT)';

  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_insert" AFTER INSERT ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$key, \'insert\', ${List.filled(table.columns.length, 'NULL').join(', ')}, '
    '$newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_update" AFTER UPDATE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$key, \'update\', $oldValues, $newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_delete" AFTER DELETE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$oldKey, \'delete\', $oldValues, '
    '${List.filled(table.columns.length, 'NULL').join(', ')}); END',
  );
}

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

String encodeProjection(Projection projection) => jsonEncode({
  for (final table in projection.entries)
    table.key: {
      for (final row in table.value.entries) row.key: typedRowToJson(row.value),
    },
});

Projection decodeProjection(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('检查点投影不是对象');
  final projection = <String, Map<String, TypedRow>>{};
  for (final table in decoded.entries) {
    final rows = table.value;
    if (rows is! Map) continue;
    final tableRows = <String, TypedRow>{};
    for (final row in rows.entries) {
      tableRows[row.key as String] = decodeTypedRow(jsonEncode(row.value));
    }
    projection[table.key as String] = tableRows;
  }
  return projection;
}

/// 读取 `Uint8List` 的辅助，供恢复与导出使用。
Uint8List asBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  throw StateError('期望 BLOB，实际为 ${value.runtimeType}');
}
