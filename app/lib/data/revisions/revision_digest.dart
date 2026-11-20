/// 一致性摘要与提交哈希的规范化与计算（改进方案 3.5、3.10）。
///
/// 这里只放纯函数：输入是投影或变更明细，输出是十六进制的摘要与哈希，不读写
/// 库、不依赖时间，所以“增量更新”和“整库重算”必须得到同一个值这件事可以在
/// 测试里直接证明。两条路径共用同一个行的规范形式 [canonicalRevisionRow]：
/// 表名、主键、按列名升序排列的整行，每个值是 `{"t": 类型, "v": 内容}`，与版本
/// 明细里保存的值格式相同。因为列按名字排序，读表的顺序、列的声明顺序和变更
/// 明细的记录顺序都不影响结果。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'revision_models.dart';

/// 摘要的模：2^256，等于 SHA-256 的输出空间。
final BigInt revisionDigestModulus = BigInt.one << 256;

/// 一行的规范形式：表名、主键、整行，三段各占一行。
String canonicalRevisionRow(String table, String rowKey, TypedRow row) =>
    '${jsonEncode(table)}\n${jsonEncode(rowKey)}\n${_canonicalColumns(row)}';

/// 一行的哈希，十六进制小写。
String revisionRowHash(String table, String rowKey, TypedRow row) => sha256
    .convert(utf8.encode(canonicalRevisionRow(table, rowKey, row)))
    .toString();

/// 一行的哈希值，用于多重集求和。
BigInt revisionRowHashValue(String table, String rowKey, TypedRow row) =>
    BigInt.parse(revisionRowHash(table, rowKey, row), radix: 16);

/// 全部业务行的多重集哈希：每一行按“表名、主键、规范化整行”做 SHA-256，再把
/// 这些 256 位整数按 2^256 取模求和（方案 3.5）。
///
/// 求和与顺序无关，所以增量更新按“减去旧行哈希、加上新行哈希”累加就能得到与
/// 整库重算相同的值；删除一行减一次、新增一行加一次、修改一行先减再加。
BigInt revisionStateDigestValue(Projection projection) {
  var sum = BigInt.zero;
  for (final table in projection.entries) {
    for (final row in table.value.entries) {
      sum =
          (sum + revisionRowHashValue(table.key, row.key, row.value)) %
          revisionDigestModulus;
    }
  }
  return sum;
}

/// 摘要的十六进制小写表示，固定 64 位；空投影为全零。
String revisionStateDigestHex(BigInt value) =>
    value.toRadixString(16).padLeft(64, '0');

/// 投影的一致性摘要，十六进制小写；整库重算用这一条。
String revisionStateDigest(Projection projection) =>
    revisionStateDigestHex(revisionStateDigestValue(projection));

/// 一条净变化的规范形式，用于提交哈希。
///
/// 变更明细里更新的 `before`、`after` 只含变化列，新增与删除的一侧是整行；这里
/// 按库里的样子规范化，所以从库里读回来重新计算与落库时算出的哈希一致。缺失的
/// 一侧写成 `-`：库里读回来的空行是空映射，落库时是 null，两者按同一侧处理。
String canonicalRevisionChange(RevisionChange change) {
  final before = _canonicalSide(change.before);
  final after = _canonicalSide(change.after);
  return '${change.seq}\n${change.op.value}\n'
      '${jsonEncode(change.table)}\n${jsonEncode(change.rowKey)}\n'
      '$before\n$after';
}

/// 变化的一侧：缺失与空映射都写成 `-`，其余按列名排序后编码。
String _canonicalSide(TypedRow? row) =>
    row == null || row.isEmpty ? '-' : _canonicalColumns(row);

/// 一条提交的哈希：`sha256(parent_hash, uid, kind, 规范化变更明细)`（方案 3.10）。
///
/// 父哈希把提交串成链，裁剪之后最早的保留提交带着被删父提交的哈希，成为链的
/// 锚点；`uid` 与 `kind` 也在哈希输入里，改动它们同样能被发现。
String revisionCommitHash({
  required String parentHash,
  required String uid,
  required RevisionKind kind,
  required List<RevisionChange> changes,
}) {
  final buffer = StringBuffer()
    ..writeln('parent:${jsonEncode(parentHash)}')
    ..writeln('uid:${jsonEncode(uid)}')
    ..writeln('kind:${kind.value}')
    ..writeln('changes:${changes.length}');
  for (final change in changes) {
    buffer.writeln(canonicalRevisionChange(change));
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

/// 数据完整性检查的结果，供 `fsck` 入口与界面展示（方案 3.10）。
class RevisionIntegrityReport {
  const RevisionIntegrityReport({
    required this.commitId,
    required this.checkedCommits,
    required this.problems,
  });

  /// 检查时的 `HEAD`；没有提交记录时为 0。
  final int commitId;

  /// 核对了哈希链的提交条数。
  final int checkedCommits;

  /// 发现的问题，中文说明；为空表示数据和哈希链一致。
  final List<String> problems;

  bool get isClean => problems.isEmpty;

  String get summary =>
      isClean ? '哈希链与当前摘要一致，共核对 $checkedCommits 条提交' : problems.join('；');

  @override
  String toString() => summary;
}

String _canonicalColumns(TypedRow row) {
  final columns = row.keys.toList()..sort();
  return jsonEncode({
    for (final column in columns) column: row[column]!.toJson(),
  });
}
