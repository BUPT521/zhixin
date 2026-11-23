import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/platform/legacy_layout.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zhixin_legacy_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('删除旧布局的库、图片、索引、恢复点与临时包，保留设备级文件', () async {
    const legacy = [
      'zhixin.db',
      'zhixin.db-wal',
      'question_images/a.jpg',
      'vector_index/text/page',
      'memory_index/note',
      'restore_points/backup.zip',
      'data_versions/old',
      '.restore-1/old.db',
      '.restore-journal.json',
      'cloud_backup_1.zip',
      'cloud_download_2.zip',
    ];
    const kept = [
      'cloud.json',
      'diagnostics.json',
      'diagnostics_reporting',
      'telemetry.json',
      'active_space',
      'spaces/local/zhixin.db',
    ];
    for (final item in legacy) {
      await _write(p.join(root.path, item));
    }
    for (final item in kept) {
      await _write(p.join(root.path, item));
    }

    final removed = await deleteLegacyLayoutData(root.path);

    expect(removed, {
      'zhixin.db',
      'zhixin.db-wal',
      'question_images',
      'vector_index',
      'memory_index',
      'restore_points',
      'data_versions',
      '.restore-1',
      '.restore-journal.json',
      'cloud_backup_1.zip',
      'cloud_download_2.zip',
    });
    for (final item in legacy) {
      expect(
        FileSystemEntity.typeSync(p.join(root.path, item), followLinks: false),
        FileSystemEntityType.notFound,
        reason: '$item 应当删除',
      );
    }
    for (final item in kept) {
      expect(
        FileSystemEntity.typeSync(p.join(root.path, item), followLinks: false),
        isNot(FileSystemEntityType.notFound),
        reason: '$item 属于设备级状态，不能删除',
      );
    }
  });

  test('重复调用不再删除任何条目', () async {
    await _write(p.join(root.path, 'zhixin.db'));
    await _write(p.join(root.path, 'cloud_backup_1.zip'));

    expect(await deleteLegacyLayoutData(root.path), hasLength(2));
    expect(await deleteLegacyLayoutData(root.path), isEmpty);
  });

  test('目录不存在时直接返回', () async {
    expect(await deleteLegacyLayoutData(p.join(root.path, 'missing')), isEmpty);
  });
}

Future<void> _write(String path) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString('old');
}
