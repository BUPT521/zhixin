import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:zhixin/data/attachment_store.dart';
import 'package:zhixin/data/db/raw_executor.dart';

import '../support/test_db.dart';

void main() {
  late Database db;
  late Directory root;

  setUp(() async {
    db = await openTestDb();
    root = await Directory.systemTemp.createTemp('zhixin-attachment-store-');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('启动清理仅删除数据库不再引用的图片', () async {
    final conversationId = await db.insert('conversation', {
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-08 09:00:00',
      'updated_at': '2026-11-08 09:00:00',
    });
    await db.insert('message', {
      'conversation_id': conversationId,
      'role': 'user',
      'content': '',
      'image_paths_json': '["kept.jpg"]',
      'created_at': '2026-11-08 09:00:00',
    });
    final images = Directory('${root.path}/question_images');
    await images.create(recursive: true);
    final kept = File('${images.path}/kept.jpg');
    final orphan = File('${images.path}/orphan.jpg');
    await kept.writeAsBytes([1]);
    await orphan.writeAsBytes([2]);

    await AttachmentStore(filesDir: root.path).cleanupUnreferenced(db.raw);

    expect(await kept.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
  });

  test('候选回收保留仍被引用的图片且不扫描其他文件', () async {
    final conversationId = await db.insert('conversation', {
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-08 09:00:00',
      'updated_at': '2026-11-08 09:00:00',
    });
    await db.insert('message', {
      'conversation_id': conversationId,
      'role': 'user',
      'content': '',
      'image_paths_json': '["shared.jpg"]',
      'created_at': '2026-11-08 09:00:00',
    });
    final images = Directory('${root.path}/question_images');
    await images.create(recursive: true);
    final shared = File('${images.path}/shared.jpg');
    final orphan = File('${images.path}/orphan.jpg');
    final unrelated = File('${images.path}/unrelated.jpg');
    await shared.writeAsBytes([1]);
    await orphan.writeAsBytes([2]);
    await unrelated.writeAsBytes([3]);

    await AttachmentStore(filesDir: root.path)
        .cleanupCandidates(db.raw, ['shared.jpg', 'orphan.jpg']);

    expect(await shared.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
  });
}
