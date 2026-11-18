import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/release_version.dart';

/// 版本比较只做一件事：清单里的版本高于当前才提示更新。
///
/// 版本名按 `x.y.z` 三段数字比较，前三段相同才比较构建号；版本名不同时构建号
/// 不改变结论。开发包的 `-dev` 后缀不参与比较。
void main() {
  test('版本名按三段数字解析，构建号按整数解析', () {
    final version = ReleaseVersion.tryParse('1.2.3', 47);
    expect(version, isNotNull);
    expect(version!.major, 1);
    expect(version.minor, 2);
    expect(version.patch, 3);
    expect(version.build, 47);
    expect(version.name, '1.2.3');
  });

  test('应用自身的版本串从 + 之后取构建号', () {
    final version = ReleaseVersion.parseAppVersion('0.1.1-dev+2');
    expect(version, isNotNull);
    expect(version!.name, '0.1.1');
    expect(version.build, 2);

    final release = ReleaseVersion.parseAppVersion('2.10.0+31');
    expect(release!.name, '2.10.0');
    expect(release.build, 31);
  });

  test('版本名或构建号缺失时不参与比较', () {
    expect(ReleaseVersion.parseAppVersion('unknown+unknown'), isNull);
    expect(ReleaseVersion.parseAppVersion('0.1.1'), isNull);
    expect(ReleaseVersion.tryParse('v0.1.1', 2), isNull);
    expect(ReleaseVersion.tryParse('0.1', 2), isNull);
    expect(ReleaseVersion.tryParse('0.1.1.2', 2), isNull);
  });

  test('版本名更高时提示，构建号高低不改变结论', () {
    final current = ReleaseVersion.parseAppVersion('0.1.1-dev+2')!;
    expect(ReleaseVersion.tryParse('0.1.2', 0)!.isNewerThan(current), isTrue);
    expect(ReleaseVersion.tryParse('0.2.0', 0)!.isNewerThan(current), isTrue);
    expect(ReleaseVersion.tryParse('1.0.0', 0)!.isNewerThan(current), isTrue);
    // 版本名降到 0.1.0 时，构建号再高也不算更新。
    expect(ReleaseVersion.tryParse('0.1.0', 99)!.isNewerThan(current), isFalse);
  });

  test('版本名相同时只比较构建号', () {
    final current = ReleaseVersion.parseAppVersion('0.1.1-dev+2')!;
    expect(ReleaseVersion.tryParse('0.1.1', 3)!.isNewerThan(current), isTrue);
    expect(ReleaseVersion.tryParse('0.1.1', 2)!.isNewerThan(current), isFalse);
    expect(ReleaseVersion.tryParse('0.1.1', 1)!.isNewerThan(current), isFalse);
  });

  test('相同版本名与构建号相等，比较结果为零', () {
    final current = ReleaseVersion.parseAppVersion('0.1.1-dev+2')!;
    final same = ReleaseVersion.tryParse('0.1.1', 2)!;
    expect(same.compareTo(current), 0);
    expect(same == current, isTrue);
    expect(current.isNewerThan(same), isFalse);
  });
}
