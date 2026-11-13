import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/asset_store.dart' show AttachmentCache;

void main() {
  late Directory filesDir;

  setUp(() async {
    filesDir = await Directory.systemTemp.createTemp(
      'zhixin-attachment-cache-',
    );
  });

  tearDown(() async {
    if (await filesDir.exists()) await filesDir.delete(recursive: true);
  });

  test('平时启动不补建，只按标记与缓存目录判断', () async {
    final cache = AttachmentCache(filesDir: () => filesDir.path);
    final images = Directory(cache.directory());
    await images.create(recursive: true);
    await File('${images.path}/cached').writeAsString('x');

    expect(cache.pendingRebuild, isFalse);
    expect(await cache.needsRebuild, isFalse);
  });

  test('还原或导入之前写入标记，补建成功之后删除', () async {
    final cache = AttachmentCache(filesDir: () => filesDir.path);
    await Directory(cache.directory()).create(recursive: true);

    await cache.markPendingRebuild();
    expect(cache.pendingRebuild, isTrue);
    expect(await cache.needsRebuild, isTrue);

    await cache.clearPendingRebuild();
    expect(cache.pendingRebuild, isFalse);
  });

  test('缓存目录被系统清空时补建一次，不至于一直缺图', () async {
    final cache = AttachmentCache(filesDir: () => filesDir.path);
    expect(await cache.needsRebuild, isTrue);

    await Directory(cache.directory()).create(recursive: true);
    expect(await cache.needsRebuild, isTrue);

    await File('${cache.directory()}/cached').writeAsString('x');
    expect(await cache.needsRebuild, isFalse);
  });
}
