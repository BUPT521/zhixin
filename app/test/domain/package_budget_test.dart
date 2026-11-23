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

  // 小上限下的一组合法条目：数据库 400、附件 200、其他 100，共 700。
  const databaseEntry = PackageBudgetEntry(
    name: 'zhixin.db',
    uncompressedBytes: 400,
    isDirectory: false,
  );
  const attachmentEntry = PackageBudgetEntry(
    name: 'assets/a.jpg',
    uncompressedBytes: 200,
    isDirectory: false,
  );
  const otherEntry = PackageBudgetEntry(
    name: 'data.json',
    uncompressedBytes: 100,
    isDirectory: false,
  );

  PackageBudget smallBudget({
    int maxPackageBytes = 1000,
    int maxEntries = 3,
    int maxDatabaseBytes = 400,
    int maxAttachmentBytes = 200,
    int maxUncompressedBytes = 700,
    int maxCompressionRatio = 100,
  }) => PackageBudget(
    maxPackageBytes: maxPackageBytes,
    maxEntries: maxEntries,
    maxDatabaseBytes: maxDatabaseBytes,
    maxAttachmentBytes: maxAttachmentBytes,
    maxUncompressedBytes: maxUncompressedBytes,
    maxCompressionRatio: maxCompressionRatio,
  );

  test('压缩包本身超过上限时拒绝，并写清上限', () {
    final problem = smallBudget().problem(
      packageBytes: 1001,
      entries: const [databaseEntry, attachmentEntry, otherEntry],
    );
    expect(problem, contains('数据包'));
    expect(problem, contains('1000 B'));
    expect(problem, contains('没有读取'));
  });

  test('条目数超过上限时拒绝', () {
    final problem = smallBudget().problem(
      packageBytes: 900,
      entries: const [
        PackageBudgetEntry(
          name: 'zhixin.db',
          uncompressedBytes: 10,
          isDirectory: false,
        ),
        PackageBudgetEntry(
          name: 'assets/a.jpg',
          uncompressedBytes: 10,
          isDirectory: false,
        ),
        PackageBudgetEntry(
          name: 'data.json',
          uncompressedBytes: 10,
          isDirectory: false,
        ),
        PackageBudgetEntry(
          name: 'manifest.json',
          uncompressedBytes: 10,
          isDirectory: false,
        ),
      ],
    );
    expect(problem, contains('4 个条目'));
    expect(problem, contains('条目数上限 3'));
    expect(problem, contains('没有读取'));
  });

  test('数据库超过上限时拒绝', () {
    final problem = smallBudget().problem(
      packageBytes: 900,
      entries: const [
        PackageBudgetEntry(
          name: 'zhixin.db',
          uncompressedBytes: 401,
          isDirectory: false,
        ),
        otherEntry,
      ],
    );
    expect(problem, contains('zhixin.db'));
    expect(problem, contains('数据库上限'));
    expect(problem, contains('没有读取'));
  });

  test('单个附件超过上限时拒绝，当前数据包与旧格式备份的前缀都算', () {
    for (final name in ['assets/a.jpg', 'question_images/a.jpg']) {
      final problem = smallBudget().problem(
        packageBytes: 900,
        entries: [
          const PackageBudgetEntry(
            name: 'data.json',
            uncompressedBytes: 100,
            isDirectory: false,
          ),
          PackageBudgetEntry(
            name: name,
            uncompressedBytes: 201,
            isDirectory: false,
          ),
        ],
      );
      expect(problem, contains('附件'));
      expect(problem, contains('单附件上限'));
      expect(problem, contains('没有读取'), reason: name);
    }
  });

  test('累计解压大小超过上限时拒绝', () {
    final problem = smallBudget().problem(
      packageBytes: 900,
      entries: const [
        databaseEntry,
        attachmentEntry,
        PackageBudgetEntry(
          name: 'data.json',
          uncompressedBytes: 101,
          isDirectory: false,
        ),
      ],
    );
    expect(problem, contains('累计解压上限'));
    expect(problem, contains('没有读取'));
  });

  test('压缩比超过上限时拒绝', () {
    final problem = smallBudget().problem(
      packageBytes: 5,
      entries: const [databaseEntry, attachmentEntry, otherEntry],
    );
    expect(problem, contains('压缩比'));
    expect(problem, contains('没有读取'));
  });

  test('刚好等于各项上限时不报错，目录条目不计入解压总量', () {
    final problem = smallBudget(maxEntries: 4).problem(
      packageBytes: 1000,
      entries: const [
        databaseEntry,
        attachmentEntry,
        otherEntry,
        PackageBudgetEntry(
          name: 'assets/sparse.bin',
          uncompressedBytes: 1024 * 1024 * 1024,
          isDirectory: true,
        ),
      ],
    );
    expect(problem, isNull);
  });

  test('压缩包字节数为 0 时不判断压缩比', () {
    final problem = smallBudget().problem(
      packageBytes: 0,
      entries: const [databaseEntry, attachmentEntry, otherEntry],
    );
    expect(problem, isNull);
  });
}
