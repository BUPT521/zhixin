/// 比较点分的版本号：返回负数、0 或正数，分别表示 [a] 低于、等于或高于 [b]。
///
/// 只比较数字段：忽略开头的 `v`、`-dev` 之类的预览后缀与 `+build` 构建信息，
/// 缺少的段按 0 补；出现非数字段时按 0 处理，不抛异常。发布清单与当前版本都
/// 是这种写法（例如 `0.2.0`）。
int compareVersions(String a, String b) {
  final left = _segments(a);
  final right = _segments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final leftValue = index < left.length ? left[index] : 0;
    final rightValue = index < right.length ? right[index] : 0;
    if (leftValue != rightValue) return leftValue.compareTo(rightValue);
  }
  return 0;
}

/// 发布清单里的版本比当前版本新：先比版本号，相同时比构建号。
bool isReleaseNewer({
  required String version,
  required int build,
  required String currentVersion,
  required int currentBuild,
}) {
  final byVersion = compareVersions(version, currentVersion);
  if (byVersion != 0) return byVersion > 0;
  return build > currentBuild;
}

/// 当前版本低于清单要求的最低版本：这时应提示必须更新。
bool isBelowMinimumVersion(String currentVersion, String minimumVersion) {
  final minimum = minimumVersion.trim();
  if (minimum.isEmpty) return false;
  return compareVersions(currentVersion, minimum) < 0;
}

List<int> _segments(String value) {
  var text = value.trim();
  if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
  final plus = text.indexOf('+');
  if (plus >= 0) text = text.substring(0, plus);
  final dash = text.indexOf('-');
  if (dash >= 0) text = text.substring(0, dash);
  if (text.isEmpty) return const [0];
  return [
    for (final part in text.split('.'))
      int.tryParse(RegExp(r'^\d+').stringMatch(part.trim()) ?? '') ?? 0,
  ];
}
