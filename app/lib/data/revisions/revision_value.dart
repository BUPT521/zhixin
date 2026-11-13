import 'dart:convert';
import 'dart:typed_data';

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
