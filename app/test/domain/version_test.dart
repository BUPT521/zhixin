import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/version.dart';

void main() {
  test('点分版本按数字段逐段比较，缺少的段按 0 补', () {
    expect(compareVersions('0.2.0', '0.1.9'), greaterThan(0));
    expect(compareVersions('0.1.1', '0.1.1'), 0);
    expect(compareVersions('0.1', '0.1.0'), 0);
    expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('0.0.1', '0.0.10'), lessThan(0));
  });

  test('忽略 v 前缀、预览后缀与构建信息', () {
    expect(compareVersions('v0.2.0', '0.2'), 0);
    expect(compareVersions('0.1.1-dev', '0.1.1'), 0);
    expect(compareVersions('0.2.0+12', '0.2.0+34'), 0);
  });

  test('不是版本号的片段按 0 处理，不抛异常', () {
    expect(compareVersions('', '0.0.0'), 0);
    expect(compareVersions('v', '0'), 0);
    expect(compareVersions('0.x.1', '0.0.1'), 0);
  });

  test('版本相同再比构建号', () {
    expect(
      isReleaseNewer(
        version: '0.2.0',
        build: 3,
        currentVersion: '0.1.1',
        currentBuild: 2,
      ),
      isTrue,
    );
    expect(
      isReleaseNewer(
        version: '0.1.1',
        build: 2,
        currentVersion: '0.1.1',
        currentBuild: 2,
      ),
      isFalse,
    );
    expect(
      isReleaseNewer(
        version: '0.1.1',
        build: 3,
        currentVersion: '0.1.1',
        currentBuild: 2,
      ),
      isTrue,
    );
    expect(
      isReleaseNewer(
        version: '0.1.0',
        build: 9,
        currentVersion: '0.1.1',
        currentBuild: 2,
      ),
      isFalse,
    );
  });

  test('低于最低版本才算必须更新，空最低版本不限制', () {
    expect(isBelowMinimumVersion('0.1.1', '0.2.0'), isTrue);
    expect(isBelowMinimumVersion('0.2.0', '0.2.0'), isFalse);
    expect(isBelowMinimumVersion('0.3.0', '0.2.0'), isFalse);
    expect(isBelowMinimumVersion('0.1.1', '  '), isFalse);
    expect(isBelowMinimumVersion('0.1.1-dev', '0.2.0'), isTrue);
  });
}
