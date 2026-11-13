import 'dart:convert';
import 'dart:typed_data';

/// 数据版本里的一次提交。
class RevisionCommit {
  const RevisionCommit({
    required this.id,
    required this.parentId,
    required this.generation,
    required this.actor,
    required this.action,
    required this.changeCount,
    required this.createdAt,
    this.requestId,
    this.restoredCommitId,
    this.revertedCommitId,
  });

  factory RevisionCommit.fromRow(Map<String, Object?> row) => RevisionCommit(
    id: row['id']! as int,
    parentId: row['parent_id'] as int?,
    generation: row['generation']! as int,
    actor: row['actor']! as String,
    action: row['action']! as String,
    requestId: row['request_id'] as String?,
    restoredCommitId: row['restored_commit_id'] as int?,
    revertedCommitId: row['reverted_commit_id'] as int?,
    changeCount: row['change_count']! as int,
    createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
  );

  final int id;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final String? requestId;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final int changeCount;
  final DateTime? createdAt;

  bool get isBaseline => id == 0;
  bool get isUndo => revertedCommitId != null;
  bool get isRestore => restoredCommitId != null;

  Map<String, Object?> toRow() => {
    'id': id,
    'parent_id': parentId,
    'generation': generation,
    'actor': actor,
    'action': action,
    'request_id': requestId,
    'restored_commit_id': restoredCommitId,
    'reverted_commit_id': revertedCommitId,
    'change_count': changeCount,
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
    op: row['op']! as String,
    before: decodeTypedRow(row['before_json'] as String?),
    after: decodeTypedRow(row['after_json'] as String?),
  );

  final int commitId;
  final int seq;
  final String table;
  final String rowKey;

  /// `insert` / `update` / `delete`。
  final String op;

  /// 更新只保存变化列；新增时为空，删除时为完整旧行。
  final TypedRow? before;
  final TypedRow? after;

  bool get isInsert => op == 'insert';
  bool get isUpdate => op == 'update';
  bool get isDelete => op == 'delete';

  Map<String, Object?> toRow() => {
    'commit_id': commitId,
    'seq': seq,
    'table_name': table,
    'row_key': rowKey,
    'op': op,
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
    createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
    updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
  );

  static const String headName = 'HEAD';

  final String name;
  final int commitId;
  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isHead => name == headName;
}

/// 检查点：从某一提交重建所需的业务投影与附件清单。
class RevisionCheckpoint {
  const RevisionCheckpoint({
    required this.id,
    required this.kind,
    required this.commitId,
    required this.projectionJson,
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
      projectionJson: row['projection_json']! as String,
      assetHashes: decodeStringList(hashes),
      checksum: row['checksum']! as String,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
    );
  }

  final int id;
  final String kind;
  final int commitId;
  final String projectionJson;
  final List<String> assetHashes;
  final String checksum;
  final DateTime? createdAt;

  bool get isNamed => kind == 'named';
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

  int get insertCount => entries.where((entry) => entry.op == 'insert').length;
  int get updateCount => entries.where((entry) => entry.op == 'update').length;
  int get deleteCount => entries.where((entry) => entry.op == 'delete').length;
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
  final String op;
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
    if (value == null) return const RevisionValue._('null', null);
    if (value is int) return RevisionValue._('integer', value);
    if (value is double) return RevisionValue._('real', value);
    if (value is String) return RevisionValue._('text', value);
    if (value is Uint8List) {
      return RevisionValue._('blob', base64Encode(value));
    }
    if (value is List<int>) {
      return RevisionValue._('blob', base64Encode(value));
    }
    throw ArgumentError.value(value, 'value', '不支持的 SQLite 值类型');
  }

  factory RevisionValue.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('版本值不是对象');
    final type = json['t'];
    final value = json['v'];
    switch (type) {
      case 'null':
        return const RevisionValue._('null', null);
      case 'integer':
        if (value is! int) throw const FormatException('整数格式不对');
        return RevisionValue._('integer', value);
      case 'real':
        if (value is! num) throw const FormatException('实数格式不对');
        return RevisionValue._('real', value.toDouble());
      case 'text':
        if (value is! String) throw const FormatException('文本格式不对');
        return RevisionValue._('text', value);
      case 'blob':
        if (value is! String) throw const FormatException('BLOB 格式不对');
        return RevisionValue._('blob', value);
      default:
        throw FormatException('未知的版本值类型：$type');
    }
  }

  final String type;
  final Object? value;

  bool get isNull => type == 'null';

  Object? get sqliteValue {
    if (type != 'blob') return value;
    final decoded = base64Decode(value! as String);
    return Uint8List.fromList(decoded);
  }

  Map<String, Object?> toJson() => {'t': type, 'v': value};

  bool equals(RevisionValue other) {
    if (type != other.type) return false;
    if (type == 'blob') return value == other.value;
    return value == other.value;
  }

  @override
  bool operator ==(Object other) => other is RevisionValue && equals(other);

  @override
  int get hashCode => Object.hash(type, value);

  @override
  String toString() => '$type:$value';
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
