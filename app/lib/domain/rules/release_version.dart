/// 发布清单与当前应用的版本比较：版本名按 `x.y.z` 解析，构建号按整数比较。
///
/// 服务端只原样给出清单，不判断是否需要更新（ADR-0025），比较规则因此只有这
/// 一份。版本名带 `-dev` 这类后缀时忽略后缀；版本名不同时按三段数字比较，只有
/// 前三段相同才比较构建号。
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  /// 版本名字段允许数字三段加可选后缀；后缀只用于开发包与预发布，不参与比较。
  static final RegExp _namePattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$',
  );

  /// 解析清单里的一项版本；版本名不是 `x.y.z` 时返回 null，调用方按不提示处理。
  static ReleaseVersion? tryParse(String name, int build) {
    final match = _namePattern.firstMatch(name.trim());
    if (match == null) return null;
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      build,
    );
  }

  /// 解析应用自身的版本串，例如 `0.1.1-dev+2`：`+` 之后是构建号。
  ///
  /// 构建元数据缺失时（如 `unknown+2`）返回 null，本次不提示更新。
  static ReleaseVersion? parseAppVersion(String value) {
    final input = value.trim();
    final plus = input.lastIndexOf('+');
    if (plus <= 0) return null;
    final build = int.tryParse(input.substring(plus + 1).trim());
    if (build == null) return null;
    return tryParse(input.substring(0, plus), build);
  }

  /// 是否比 [other] 更新；相同版本名与构建号时不更新。
  bool isNewerThan(ReleaseVersion other) => compareTo(other) > 0;

  @override
  int compareTo(ReleaseVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  /// 去掉后缀与构建号的版本名，用于界面提示。
  String get name => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => '$name+$build';
}
