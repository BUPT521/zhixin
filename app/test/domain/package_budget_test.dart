import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/package_budget.dart';

void main() {
  test('数据包上限与服务端的备份上限一致', () {
    expect(dataPackageMaxBytes, 256 * 1024 * 1024);
  });

  test('超过上限的说明写清实际大小与上限', () {
    final message = dataPackageTooLargeMessage(300 * 1024 * 1024);
    expect(message, contains('300.0 MB'));
    expect(message, contains('256 MiB'));
    expect(message, contains('没有读取'));
  });

  test('大小写法按 B、KB、MB 给出', () {
    expect(formatPackageSize(512), '512 B');
    expect(formatPackageSize(2048), '2 KB');
    expect(formatPackageSize(5 * 1024 * 1024), '5.0 MB');
    expect(formatPackageSize(3 * 1024 * 1024 * 1024), '3.0 GB');
  });
}
