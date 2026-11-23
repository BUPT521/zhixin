import 'dart:convert';
import 'dart:typed_data';

import '../../domain/rules/coded_enum.dart';
import '../../domain/rules/time_format.dart';

/// 提交类型（01 `revision_commit.kind`）。
///
/// 由写入路径决定，界面按它显示标签与图标；动作文案 [RevisionCommit.action]
/// 只给人看，不参与类型判断（ADR-0039）。`kind` 只表示这条提交做了什么，来源
/// 是另一台设备还是本机只看 [RevisionCommit.originDevice]（审查 S23），所以
/// 远端提交沿用它在原来设备上的类型。
enum RevisionKind implements CodedEnum {
  baseline('baseline', '初始基线'),
  write('write', '写入'),
  undo('undo', '撤销'),
  restore('restore', '恢复版本'),
  import('import', '导入数据'),
  maintenance('maintenance', '维护');

  const RevisionKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static RevisionKind fromValue(String value) =>
      codedValueOrNull(RevisionKind.values, value) ??
      (throw FormatException('未知的提交类型：$value'));
}

/// 一条净变化的类型（01 `revision_change.op`）；库与数据包里仍写稳定值。
enum ChangeOp implements CodedEnum {
  insert('insert', '新增'),
  update('update', '修改'),
  delete('delete', '删除');

  const ChangeOp(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static ChangeOp fromValue(String value) =>
      codedValueOrNull(ChangeOp.values, value) ??
      (throw FormatException('未知的变更类型：$value'));
}

/// 版本值的类型；比较时类型和内容一起比较（01 `revision_change.before_json`）。
enum RevisionValueType {
  nullValue('null'),
  integer('integer'),
  real('real'),
  text('text'),
  blob('blob');

  const RevisionValueType(this.value);

  /// 写进库与数据包的稳定值，与 ADR-0018 之前的格式相同。
  final String value;

  static RevisionValueType fromValue(String value) {
    for (final type in RevisionValueType.values) {
      if (type.value == value) return type;
    }
    throw FormatException('未知的版本值类型：$value');
  }
}

/// 只记录维护信息、不算内容变化的列；撤销核对与撤销写回都跳过它们。
const Set<String> revisionBookkeepingColumns = {'updated_at'};

/// 没有任何业务行时的一致性摘要：多重集为空，和为零（方案 3.5）。
const String revisionEmptyStateDigest =
    '0000000000000000000000000000000000000000000000000000000000000000';

/// 数据版本里的一次提交。
///
/// 完整性只认 [stateDigest] 一个原语：变更明细条数与冲突条数在读取时现数，提交
/// 没有哈希链（ADR-0054 与数据库结构过度设计审查的 S1）。
class RevisionCommit {
  const RevisionCommit({
    required this.id,
    required this.uid,
    required this.parentId,
    required this.generation,
    required this.actor,
    required this.action,
    required this.kind,
    required this.changeCount,
    required this.createdAt,
    this.restoredCommitId,
    this.revertedCommitId,
    this.byteLength = 0,
    this.conflictCount = 0,
    this.stateDigest = revisionEmptyStateDigest,
    this.serverSeq,
    this.originDevice,
    this.authoredAt,
  });

  factory RevisionCommit.fromRow(Map<String, Object?> row) => RevisionCommit(
    id: row['id']! as int,
    uid: row['uid']! as String,
    parentId: row['parent_id'] as int?,
    generation: row['generation']! as int,
    actor: row['actor']! as String,
    action: row['action']! as String,
    kind: RevisionKind.fromValue(row['kind']! as String),
    restoredCommitId: row['restored_commit_id'] as int?,
    revertedCommitId: row['reverted_commit_id'] as int?,
    changeCount: row['change_count'] as int? ?? 0,
    byteLength: row['byte_length'] as int? ?? 0,
    conflictCount: row['conflict_count'] as int? ?? 0,
    stateDigest: row['state_digest'] as String? ?? revisionEmptyStateDigest,
    serverSeq: row['server_seq'] as int?,
    originDevice: row['origin_device'] as String?,
    authoredAt: optionalDateTime(row['authored_at'] as String? ?? ''),
    createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
  );

  final int id;

  /// 提交身份：全局唯一、永不复用，推送与服务端去重、远端提交的本机去重都按它。
  final String uid;
  final int? parentId;

  /// 这条提交落库之后全部业务行的一致性摘要（方案 3.5）。
  final String stateDigest;
  final int generation;
  final String actor;
  final String action;
  final RevisionKind kind;
  final int? restoredCommitId;
  final int? revertedCommitId;

  /// 这条提交变更明细的条数；读取时从 `revision_change` 现数，不存列。
  final int changeCount;

  /// 这条提交变更明细的字节数；按容量裁剪用它估算每条提交占用的空间。
  final int byteLength;

  /// 应用远端提交时记下的冲突条数；读取时从 `revision_conflict` 现数，不存列。
  final int conflictCount;

  /// 这条提交在服务端序列上的序号；还不知道时为空（ADR-0054 决定第 2 条）。
  final int? serverSeq;

  /// 远端提交由服务端带来的设备标识；本机提交为空（方案 3.12）。
  final String? originDevice;

  /// 远端提交的作者创建时间；本机提交为空，界面回退到 [createdAt]（方案 3.12）。
  final DateTime? authoredAt;
  final DateTime? createdAt;

  bool get isBaseline => id == 0;
  bool get isUndo => kind == RevisionKind.undo;

  /// 是否来自其他设备；界面据此显示“来自另一台设备”（方案 3.12）。
  bool get isRemote => originDevice != null;

  /// 界面显示的作者时间：远端用作者时间，本机用落库时间。
  DateTime? get displayAuthoredAt => authoredAt ?? createdAt;

  Map<String, Object?> toRow() => {
    'id': id,
    'uid': uid,
    'parent_id': parentId,
    'generation': generation,
    'state_digest': stateDigest,
    'actor': actor,
    'action': action,
    'kind': kind.value,
    'restored_commit_id': restoredCommitId,
    'reverted_commit_id': revertedCommitId,
    'byte_length': byteLength,
    'server_seq': serverSeq,
    'origin_device': originDevice,
    'authored_at': authoredAt == null ? null : formatDateTime(authoredAt!),
    'created_at': createdAt?.toIso8601String(),
  };
}

/// 一条提交内的行级净变化。
class RevisionChange {
  const RevisionChange({
    required this.commitId,
    required this.seq,
    required this.table,
    required this.rowKey,
    required this.op,
    this.before,
    this.after,
  });

  factory RevisionChange.fromRow(Map<String, Object?> row) => RevisionChange(
    commitId: row['commit_id']! as int,
    seq: row['seq']! as int,
    table: row['table_name']! as String,
    rowKey: row['row_key']! as String,
    op: ChangeOp.fromValue(row['op']! as String),
    before: decodeTypedRow(row['before_json'] as String?),
    after: decodeTypedRow(row['after_json'] as String?),
  );

  final int commitId;
  final int seq;
  final String table;
  final String rowKey;

  /// 新增、修改或删除；库与数据包仍写 `insert`、`update`、`delete`。
  final ChangeOp op;

  /// 更新只保存变化列；新增时为空，删除时为完整旧行。
  final TypedRow? before;
  final TypedRow? after;

  bool get isUpdate => op == ChangeOp.update;
  bool get isDelete => op == ChangeOp.delete;

  Map<String, Object?> toRow() => {
    'commit_id': commitId,
    'seq': seq,
    'table_name': table,
    'row_key': rowKey,
    'op': op.value,
    'before_json': before == null ? null : encodeTypedRow(before!),
    'after_json': after == null ? null : encodeTypedRow(after!),
  };
}

/// 用户给版本起的名字；`HEAD` 另存在 `revision_state` 里（ADR-0054 决定第 4 条）。
///
/// 指向的提交按 [commitUid] 查，本机已经没有这条提交时就是“只剩标签”的名字，
/// 可以查看标签、不能恢复。
class RevisionRef {
  const RevisionRef({
    required this.name,
    required this.commitUid,
    this.syncState = RevisionRefSyncState.clean,
    this.note,
    this.createdAt,
    this.updatedAt,
  });

  factory RevisionRef.fromRow(Map<String, Object?> row) => RevisionRef(
    name: row['name']! as String,
    commitUid: row['commit_uid']! as String,
    syncState: RevisionRefSyncState.fromValue(
      row['sync_state'] as String? ?? RevisionRefSyncState.clean.value,
    ),
    note: row['note'] as String?,
    createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
    updatedAt: optionalDateTime(row['updated_at'] as String? ?? ''),
  );

  /// 每账号最多保留的名字数，客户端与服务端取同一个值。
  static const int maxRefs = 200;

  /// 名字规范化之后的字符数上限，两端一致。
  static const int maxNameLength = 30;

  final String name;
  final String commitUid;
  final RevisionRefSyncState syncState;
  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isDirty => syncState == RevisionRefSyncState.dirty;

  RevisionRef copyWith({
    String? name,
    String? commitUid,
    RevisionRefSyncState? syncState,
    String? note,
  }) => RevisionRef(
    name: name ?? this.name,
    commitUid: commitUid ?? this.commitUid,
    syncState: syncState ?? this.syncState,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  Map<String, Object?> toRow() => {
    'name': name,
    'commit_uid': commitUid,
    'sync_state': syncState.value,
    'note': note,
    'created_at': createdAt == null ? null : formatDateTime(createdAt!),
    'updated_at': updatedAt == null ? null : formatDateTime(updatedAt!),
  };
}

/// 命名版本的同步状态：干净表示与云端一致，已改表示本机改过、还没推送。
enum RevisionRefSyncState implements CodedEnum {
  clean('clean', '已同步'),
  dirty('dirty', '待同步');

  const RevisionRefSyncState(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static RevisionRefSyncState fromValue(String value) =>
      codedValueOrNull(RevisionRefSyncState.values, value) ??
      RevisionRefSyncState.clean;
}

/// 用户显式删除一个名字留下的墓碑；推送成功之后删行（ADR-0054 决定第 4 条）。
class RevisionRefTombstone {
  const RevisionRefTombstone({required this.name, required this.deletedAt});

  factory RevisionRefTombstone.fromRow(Map<String, Object?> row) =>
      RevisionRefTombstone(
        name: row['name']! as String,
        deletedAt: optionalDateTime(row['deleted_at'] as String? ?? ''),
      );

  final String name;
  final DateTime? deletedAt;

  Map<String, Object?> toRow() => {
    'name': name,
    'deleted_at': deletedAt == null ? null : formatDateTime(deletedAt!),
  };
}

/// 检查点：从某一提交重建所需的业务投影。
///
/// 只有一种编码（gzip 压缩的 JSON）；完整性由 [stateDigest] 与重建出的投影比对，
/// 附件清单存在 `revision_asset_ref` 里（ADR-0054 与审查 S2、S10）。
class RevisionCheckpoint {
  const RevisionCheckpoint({
    required this.id,
    required this.kind,
    required this.commitId,
    required this.payload,
    required this.rawBytes,
    required this.createdAt,
    this.stateDigest = revisionEmptyStateDigest,
  });

  factory RevisionCheckpoint.fromRow(Map<String, Object?> row) =>
      RevisionCheckpoint(
        id: row['id']! as int,
        kind: row['kind']! as String,
        commitId: row['commit_id']! as int,
        payload: row['payload']! as Uint8List,
        rawBytes: row['raw_bytes']! as int,
        stateDigest: row['state_digest'] as String? ?? revisionEmptyStateDigest,
        createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
      );

  final int id;
  final String kind;
  final int commitId;

  /// 业务投影的字节，gzip 压缩的检查点原文。
  final Uint8List payload;

  /// 压缩之前的字节数。
  final int rawBytes;

  /// 这份投影的一致性摘要；重建之后可以直接与当前表比对（方案 3.5）。
  final String stateDigest;
  final DateTime? createdAt;
}

/// 历史的下游读者在库里登记读到哪里。
///
/// 会丢数据的读者（同步推送）把 [blocking] 置 1，裁剪与清理历史不能越过它的
/// [position]；只会退回全量重建的读者（索引）只登记位置，不阻止裁剪。一个库
/// 只属于一个账号与实例，位置因此不再带账号归属（ADR-0056 决定第 9 条）。
class RevisionCursor {
  const RevisionCursor({
    required this.name,
    required this.position,
    this.blocking = false,
    this.updatedAt,
  });

  factory RevisionCursor.fromRow(Map<String, Object?> row) => RevisionCursor(
    name: row['name']! as String,
    position: row['position']! as int,
    blocking: (row['blocking'] as int? ?? 0) != 0,
    updatedAt: optionalDateTime(row['updated_at'] as String? ?? ''),
  );

  /// 同步推送读到哪里；落后于 `HEAD` 时阻止裁剪与清理历史。
  static const String syncPushed = 'sync.pushed';

  /// 服务端最近一次拉到的位置；不阻止裁剪。
  static const String syncServerHead = 'sync.server_head';

  /// 整库恢复之后待重新对齐的标记：存在时下一轮同步不拉取旧位置之后的提交，
  /// 而是先要求确认，再把恢复前后的差异推到服务端（同步方案 3.4）。
  ///
  /// [position] 是补记的恢复提交编号；恢复前后没有差异时为 0，这一轮只把两个
  /// 位置挪到当前服务端位置与本机 `HEAD`；补记失败时为 -1，这一轮按首次基线
  /// 重新对齐。
  static const String syncRestoreAlign = 'sync.restore_align';
  static const String syncRefMerge = 'sync.ref_merge';

  final String name;
  final int position;
  final bool blocking;
  final DateTime? updatedAt;

  Map<String, Object?> toRow() => {
    'name': name,
    'position': position,
    'blocking': blocking ? 1 : 0,
    'updated_at': updatedAt == null
        ? formatDateTime(DateTime.now())
        : formatDateTime(updatedAt!),
  };
}

/// 已被远端提交取代的一个本机格子（01 `sync_shadow`）。
///
/// [uptoCommit] 是应用那条远端提交之前的本机 `HEAD`：编号不大于它的本机提交
/// 在这个格子上的改动作废，推送时去掉这个格子（ADR-0040）。[column] 为空字符串
/// 表示整行变化，整行遮蔽把这一行的变化整条去掉。
class RevisionShadow {
  const RevisionShadow({
    required this.table,
    required this.rowKey,
    required this.column,
    required this.uptoCommit,
  });

  factory RevisionShadow.fromRow(Map<String, Object?> row) => RevisionShadow(
    table: row['table_name']! as String,
    rowKey: row['row_key']! as String,
    column: row['column_name']! as String,
    uptoCommit: row['upto_commit']! as int,
  );

  final String table;
  final String rowKey;
  final String column;
  final int uptoCommit;

  /// 整行被覆盖：新增、删除与整行覆盖记空列，不细分到列。
  bool get isWholeRow => column.isEmpty;

  Map<String, Object?> toRow() => {
    'table_name': table,
    'row_key': rowKey,
    'column_name': column,
    'upto_commit': uptoCommit,
  };
}

/// 应用远端提交时被覆盖的本机修改。
///
/// 同步仍然是后到覆盖先到；这条记录让本机能列出每一处被覆盖的本机值，并把
/// 本机值作为一条普通提交写回（`keepLocal`）。[id] 与 [commitId] 在写库之前
/// 都是 0，由写入方补上。
class RevisionConflict {
  const RevisionConflict({
    required this.table,
    required this.rowKey,
    required this.reason,
    required this.local,
    required this.remoteAfter,
    this.id = 0,
    this.commitId = 0,
    this.column,
    this.remoteBefore,
    this.resolvedCommitId,
  });

  factory RevisionConflict.fromRow(Map<String, Object?> row) =>
      RevisionConflict(
        id: row['id']! as int,
        commitId: row['commit_id']! as int,
        table: row['table_name']! as String,
        rowKey: row['row_key']! as String,
        column: row['column_name'] as String?,
        reason: row['reason']! as String,
        local: decodeTypedRow(row['local_json'] as String?),
        remoteBefore: decodeTypedRow(row['remote_before_json'] as String?),
        remoteAfter: decodeTypedRow(row['remote_after_json'] as String?),
        resolvedCommitId: row['resolved_commit_id'] as int?,
      );

  /// 本机与远端各改了一列，且本机值既不是远端旧值也不是远端新值。
  static const String concurrentUpdate = 'concurrent_update';

  /// 本机已经删掉这一行，远端提交还在改它；写入仍然跳过。
  static const String deletedLocally = 'deleted_locally';

  /// 远端新增撞上本机已有的同一主键，且内容不同。
  static const String insertCollision = 'insert_collision';

  /// 本机改过这一行，远端把它删掉了。
  static const String deletedRemotelyModified = 'deleted_remotely_modified';

  /// 远端这一行与另一条本机行撞上有含义的唯一键（目前是 `material_page` 的
  /// 页码与 `memory_usage` 的记忆加设备），这一行跳过不写（审查 S18）。
  static const String uniqueKeyTaken = 'unique_key_taken';

  final int id;
  final int commitId;
  final String table;
  final String rowKey;

  /// 整行冲突（新增撞上同一主键）时为空。
  final String? column;
  final String reason;

  /// 被覆盖之前本机的值，只含 [column]；整行冲突时是整行。
  final TypedRow local;
  final TypedRow? remoteBefore;
  final TypedRow remoteAfter;
  final int? resolvedCommitId;

  bool get isResolved => resolvedCommitId != null;

  Map<String, Object?> toRow() => {
    'commit_id': commitId,
    'table_name': table,
    'row_key': rowKey,
    'column_name': column,
    'reason': reason,
    'local_json': encodeTypedRow(local),
    'remote_before_json': remoteBefore == null
        ? null
        : encodeTypedRow(remoteBefore!),
    'remote_after_json': encodeTypedRow(remoteAfter),
    'resolved_commit_id': resolvedCommitId,
  };
}

/// 业务投影：表名 → 主键 → 行。
typedef Projection = Map<String, Map<String, TypedRow>>;

/// 两个版本之间的比较结果。
class RevisionDiff {
  const RevisionDiff({
    required this.before,
    required this.after,
    required this.entries,
  });

  final int before;
  final int after;
  final List<RevisionDiffEntry> entries;

  int get insertCount =>
      entries.where((entry) => entry.op == ChangeOp.insert).length;
  int get updateCount =>
      entries.where((entry) => entry.op == ChangeOp.update).length;
  int get deleteCount =>
      entries.where((entry) => entry.op == ChangeOp.delete).length;
  bool get isEmpty => entries.isEmpty;
}

class RevisionDiffEntry {
  const RevisionDiffEntry({
    required this.table,
    required this.rowKey,
    required this.op,
    this.columns = const {},
  });

  final String table;
  final String rowKey;
  final ChangeOp op;
  final Set<String> columns;
}

/// 整版恢复预览：目标版本、当前 `HEAD` 与差异。
class RevisionRestorePreview {
  const RevisionRestorePreview({
    required this.target,
    required this.head,
    required this.diff,
  });

  final RevisionCommit target;
  final int head;
  final RevisionDiff diff;
}

/// 单项撤销的结果；失败时不写入任何数据，并说明原因。
class RevisionUndoResult {
  const RevisionUndoResult({
    required this.applied,
    required this.message,
    this.commit,
  });

  final bool applied;
  final String message;
  final RevisionCommit? commit;
}

/// 历史与附件的占用概况，用于留存页说明空间去向。
class RevisionStorageUsage {
  const RevisionStorageUsage({
    required this.databaseBytes,
    required this.assetBytes,
    required this.assetCount,
    required this.checkpointCount,
    required this.commitCount,
    required this.namedCount,
  });

  final int databaseBytes;
  final int assetBytes;
  final int assetCount;
  final int checkpointCount;
  final int commitCount;
  final int namedCount;
}

/// 历史留存与清理的结果。
class RevisionRetentionResult {
  const RevisionRetentionResult({
    required this.removedCommits,
    required this.removedCheckpoints,
    required this.removedAssets,
    required this.keptFrom,
    required this.databaseBytes,
  });

  final int removedCommits;
  final int removedCheckpoints;
  final int removedAssets;
  final int keptFrom;
  final int databaseBytes;
}

/// SQLite 里一个值的类型与内容；比较时类型和内容一起比较。
///
/// SQLite 的值只有 NULL、整数、实数、文本、BLOB 五种，JSON 本身分不出整数
/// 与实数，也不能直接放 BLOB，所以版本明细保存 `{"t": 类型, "v": 内容}`，
/// BLOB 用 base64。行级净变化、检查点与比较都按这一份格式读写。
class RevisionValue {
  const RevisionValue._(this.type, this.value);

  factory RevisionValue.of(Object? value) {
    if (value == null) {
      return const RevisionValue._(RevisionValueType.nullValue, null);
    }
    if (value is int) {
      return RevisionValue._(RevisionValueType.integer, value);
    }
    if (value is double) {
      return RevisionValue._(RevisionValueType.real, value);
    }
    if (value is String) {
      return RevisionValue._(RevisionValueType.text, value);
    }
    if (value is Uint8List) {
      return RevisionValue._(RevisionValueType.blob, base64Encode(value));
    }
    if (value is List<int>) {
      return RevisionValue._(RevisionValueType.blob, base64Encode(value));
    }
    throw ArgumentError.value(value, 'value', '不支持的 SQLite 值类型');
  }

  factory RevisionValue.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('版本值不是对象');
    final type = RevisionValueType.fromValue(json['t']! as String);
    final value = json['v'];
    switch (type) {
      case RevisionValueType.nullValue:
        return const RevisionValue._(RevisionValueType.nullValue, null);
      case RevisionValueType.integer:
        if (value is! int) throw const FormatException('整数格式不对');
        return RevisionValue._(RevisionValueType.integer, value);
      case RevisionValueType.real:
        if (value is! num) throw const FormatException('实数格式不对');
        return RevisionValue._(RevisionValueType.real, value.toDouble());
      case RevisionValueType.text:
        if (value is! String) throw const FormatException('文本格式不对');
        return RevisionValue._(RevisionValueType.text, value);
      case RevisionValueType.blob:
        if (value is! String) throw const FormatException('BLOB 格式不对');
        return RevisionValue._(RevisionValueType.blob, value);
    }
  }

  final RevisionValueType type;
  final Object? value;

  bool get isNull => type == RevisionValueType.nullValue;

  Object? get sqliteValue {
    if (type != RevisionValueType.blob) return value;
    final decoded = base64Decode(value! as String);
    return Uint8List.fromList(decoded);
  }

  Map<String, Object?> toJson() => {'t': type.value, 'v': value};

  bool equals(RevisionValue other) {
    if (type != other.type) return false;
    if (type == RevisionValueType.blob) return value == other.value;
    return value == other.value;
  }

  @override
  bool operator ==(Object other) => other is RevisionValue && equals(other);

  @override
  int get hashCode => Object.hash(type, value);

  @override
  String toString() => '${type.value}:$value';
}

/// 行在某个版本里的值，按列名保存 [RevisionValue]。
typedef TypedRow = Map<String, RevisionValue>;

TypedRow typedRow(Map<String, Object?> row, {Set<String>? columns}) {
  final result = <String, RevisionValue>{};
  for (final entry in row.entries) {
    if (columns != null && !columns.contains(entry.key)) continue;
    result[entry.key] = RevisionValue.of(entry.value);
  }
  return result;
}

Map<String, Object?> sqliteRow(TypedRow row) => {
  for (final entry in row.entries) entry.key: entry.value.sqliteValue,
};

String encodeTypedRow(TypedRow row) => jsonEncode(typedRowToJson(row));

Map<String, Object?> typedRowToJson(TypedRow row) => {
  for (final entry in row.entries) entry.key: entry.value.toJson(),
};

TypedRow decodeTypedRow(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('版本行不是对象');
  return {
    for (final entry in decoded.entries)
      entry.key as String: RevisionValue.fromJson(entry.value),
  };
}

bool typedRowsEqual(TypedRow left, TypedRow right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    final other = right[entry.key];
    if (other == null || !entry.value.equals(other)) return false;
  }
  return true;
}

/// 两个版本行的差异列；只比较同时出现的列，新增与删除由调用方处理。
Set<String> changedColumns(TypedRow before, TypedRow after) {
  final keys = <String>{...before.keys, ...after.keys};
  return {
    for (final key in keys)
      if (before[key] == null ||
          after[key] == null ||
          !before[key]!.equals(after[key]!))
        key,
  };
}

/// 把行裁剪到指定列；净变化只保存变化列。
TypedRow projectColumns(TypedRow row, Set<String> columns) => {
  for (final entry in row.entries)
    if (columns.contains(entry.key)) entry.key: entry.value,
};

/// 命名版本名字的规范化：去掉首尾空白。
///
/// 名字的比较口径要求两端一致；客户端不引 Unicode 规范化库，两端都按原样
/// 比较并与服务端同时做 NFC，服务端负责把规范化之后的形状存下来
/// （ADR-0054 决定第 4 条）。
String normalizeRefName(String name) => name.trim();
