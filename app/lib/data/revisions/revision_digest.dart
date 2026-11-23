/// 一致性摘要的规范化与计算（改进方案 3.5、ADR-0045、ADR-0054）。
///
/// 这里只放纯函数：输入是投影或变更明细，输出是十六进制的摘要，不读写库、不
/// 依赖时间，所以“增量更新”和“整库重算”必须得到同一个值这件事可以在测试里
/// 直接证明。两条路径共用同一个行的规范形式 [canonicalRevisionRow]：表名、
/// 主键、按列名升序排列的整行，每个值是 `{"t": 类型, "v": 内容}`，与版本明细里
/// 保存的值格式相同。因为列按名字排序，读表的顺序、列的声明顺序和变更明细的
/// 记录顺序都不影响结果。
///
/// 摘要按表分别累加，总摘要恒等于各表值之和（ADR-0054 决定第 1 条）：分表值
/// 用来指出哪几张表不一致，总摘要仍是对外比较与同步的唯一值。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'revision_engine.dart' show versionedTableNames;
import 'revision_models.dart';

/// 摘要的模：2^256，等于 SHA-256 的输出空间。
final BigInt revisionDigestModulus = BigInt.one << 256;

/// 各行摘要按 2^256 取模相加。
BigInt revisionDigestSum(Iterable<BigInt> values) {
  var sum = BigInt.zero;
  for (final value in values) {
    sum = (sum + value) % revisionDigestModulus;
  }
  return sum;
}

/// 各表摘要之和；没有列出表的一侧按零处理。
BigInt revisionTableDigestsSum(Map<String, String> digests) =>
    revisionDigestSum([
      for (final value in digests.values) BigInt.parse(value, radix: 16),
    ]);

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

/// 每张表一个值的摘要映射，键是全部参与采集的表名。
///
/// 没有行的表写 64 个 `0`，两端按同一组键比较；各表值之和等于总摘要
/// （ADR-0054 决定第 1 条）。表顺序按外键依赖排列，写入 JSON 之后两端逐字节
/// 一致。
Map<String, String> revisionTableDigests(Projection projection) => {
  for (final table in versionedTableNames)
    table: revisionStateDigestHex(
      revisionDigestSum([
        for (final row
            in (projection[table] ?? const <String, TypedRow>{}).entries)
          revisionRowHashValue(table, row.key, row.value),
      ]),
    ),
};

/// 空投影的分表摘要：全部表写零。
Map<String, String> revisionEmptyTableDigests() => {
  for (final table in versionedTableNames)
    table: revisionStateDigestHex(BigInt.zero),
};

/// 各表摘要之和是否等于 [digest]。
bool revisionTableDigestsMatch(Map<String, String> digests, String digest) =>
    revisionStateDigestHex(revisionTableDigestsSum(digests)) == digest;

/// 全部业务行的多重集哈希：每一行按“表名、主键、规范化整行”做 SHA-256，再按
/// 2^256 取模求和（方案 3.5）。整库重算用这一条，结果恒等于分表值之和。
BigInt revisionStateDigestValue(Projection projection) => revisionDigestSum([
  for (final table in projection.entries)
    for (final row in table.value.entries)
      revisionRowHashValue(table.key, row.key, row.value),
]);

/// 摘要的十六进制小写表示，固定 64 位；空投影为全零。
String revisionStateDigestHex(BigInt value) =>
    value.toRadixString(16).padLeft(64, '0');

/// 投影的一致性摘要，十六进制小写；整库重算用这一条。
String revisionStateDigest(Projection projection) =>
    revisionStateDigestHex(revisionStateDigestValue(projection));

/// 数据完整性检查的结果，供诊断入口与界面展示（ADR-0054 与审查 S1）。
class RevisionIntegrityReport {
  const RevisionIntegrityReport({
    required this.commitId,
    required this.checkedCommits,
    required this.problems,
  });

  /// 检查时的 `HEAD`；没有提交记录时为 0。
  final int commitId;

  /// 从检查点重放到 `HEAD` 时经过的提交条数。
  final int checkedCommits;

  /// 发现的问题，中文说明；为空表示重放结果与 `HEAD`、当前表都一致。
  final List<String> problems;

  bool get isClean => problems.isEmpty;

  String get summary =>
      isClean ? '重放结果与当前数据一致，共核对 $checkedCommits 条提交' : problems.join('；');

  @override
  String toString() => summary;
}

/// 一行的规范列编码：列按名字升序，值与版本明细同一份格式。
String _canonicalColumns(TypedRow row) {
  final columns = row.keys.toList()..sort();
  return jsonEncode({
    for (final column in columns) column: row[column]!.toJson(),
  });
}
