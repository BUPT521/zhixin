import 'dart:convert';
import 'dart:typed_data';

import '../../domain/rules/coded_enum.dart';
import '../../domain/rules/time_format.dart';

/// 提交类型（01 `revision_commit.kind`）。
///
/// 由写入路径决定，界面按它显示标签与图标；动作文案 [RevisionCommit.action]
/// 只给人看，不参与类型判断（ADR-0039）。
enum RevisionKind implements CodedEnum {
  baseline('baseline', '初始基线'),
  write('write', '写入'),
  undo('undo', '撤销'),
  restore('restore', '恢复版本'),
  import('import', '导入数据'),
  maintenance('maintenance', '维护'),
  remote('remote', '其他设备');

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

/// 数据版本里的一次提交。
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
    this.requestId,
    this.restoredCommitId,
    this.revertedCommitId,
    this.byteLength = 0,
    this.conflictCount = 0,
  });

  factory RevisionCommit.fromRow(Map<String, Object?> row) => RevisionCommit(
    id: row['id']! as int,
    uid: row['uid']! as String,
    parentId: row['parent_id'] as int?,
    generation: row['generation']! as int,
    actor: row['actor']! as String,
    action: row['action']! as String,
    kind: RevisionKind.fromValue(row['kind']! as String),
    requestId: row['request_id'] as String?,
    restoredCommitId: row['restored_commit_id'] as int?,
    revertedCommitId: row['reverted_commit_id'] as int?,
    changeCount: row['change_count']! as int,
    byteLength: row['byte_length'] as int? ?? 0,
    conflictCount: row['conflict_count'] as int? ?? 0,
    createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
  );

  final int id;

  /// 提交身份：全局唯一、永不复用，推送与服务端去重、远端提交的本机去重都按它。
  final String uid;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final RevisionKind kind;

  /// 同一次用户动作的重试编号；只用于两分钟内的重试去重，不再是提交身份。
  final String? requestId;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final int changeCount;

  /// 这条提交变更明细的字节数；按容量裁剪用它估算每条提交占用的空间。
  final int byteLength;

  /// 应用远端提交时记下的冲突条数。
  final int conflictCount;
  final DateTime? createdAt;

  bool get isBaseline => id == 0;
  bool get isUndo => kind == RevisionKind.undo;

  Map<String, Object?> toRow() => {
    'id': id,
    'uid': uid,
    'parent_id': parentId,
    'generation': generation,
    'actor': actor,
    'action': action,
    'kind': kind.value,
    'request_id': requestId,
    'restored_commit_id': restoredCommitId,
    'reverted_commit_id': revertedCommitId,
    'change_count': changeCount,
    'byte_length': byteLength,
    'conflict_count': conflictCount,
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

/// 命名版本或 `HEAD` 的指向。
class RevisionRef {
  const RevisionRef({
    required this.name,
    required this.commitId,
    this.note,
    this.createdAt,
    this.updatedAt,
  });

  factory RevisionRef.fromRow(Map<String, Object?> row) => RevisionRef(
    name: row['name']! as String,
    commitId: row['commit_id']! as int,
    note: row['note'] as String?,
    createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
    updatedAt: optionalDateTime(row['updated_at'] as String? ?? ''),
  );

  static const String headName = 'HEAD';

  final String name;
  final int commitId;
  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

/// 检查点：从某一提交重建所需的业务投影与附件清单。
class RevisionCheckpoint {
  const RevisionCheckpoint({
    required this.id,
    required this.kind,
    required this.commitId,
    required this.payload,
    required this.encoding,
    required this.rawBytes,
    required this.assetHashes,
    required this.checksum,
    required this.createdAt,
  });

  factory RevisionCheckpoint.fromRow(Map<String, Object?> row) {
    final hashes = (row['asset_hashes_json'] as String? ?? '[]');
    return RevisionCheckpoint(
      id: row['id']! as int,
      kind: row['kind']! as String,
      commitId: row['commit_id']! as int,
      payload: row['payload']! as Uint8List,
      encoding: row['encoding']! as String,
      rawBytes: row['raw_bytes']! as int,
      assetHashes: decodeStringList(hashes),
      checksum: row['checksum']! as String,
      createdAt: optionalDateTime(row['created_at'] as String? ?? ''),
    );
  }

  final int id;
  final String kind;
  final int commitId;

  /// 业务投影的字节：`json` 是 UTF-8 原文，`json+gzip` 是它的 gzip 压缩。
  final Uint8List payload;
  final String encoding;

  /// 压缩之前的字节数。
  final int rawBytes;
  final List<String> assetHashes;

  /// 按解压后的原文计算，与 [encoding] 无关。
  final String checksum;
  final DateTime? createdAt;
}

/// 历史的下游读者在库里登记读到哪里。
///
/// 会丢数据的读者（同步推送）把 [blocking] 置 1，裁剪与清理历史不能越过它的
/// [position]；只会退回全量重建的读者（索引）只登记位置，不阻止裁剪。
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

List<String> decodeStringList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList(growable: false);
  } catch (_) {
    return const [];
  }
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
