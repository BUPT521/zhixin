import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/backup/backup_manifest.dart';
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/restore_journal.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/domain/rules/attachments.dart';

/// V7 的恢复用例覆盖同格式重开、恢复失败与中断回滚。
void main() {
  setUpAll(sqfliteFfiInit);

  test('V7：恢复失败时当前库保持可用', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_v7_fail_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final db = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(db.close);
    await db.insert('material', {
      'title': '当前材料',
      'kind': 'book',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:00:00',
    });

    final manifest = BackupManifest(
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      exportedAt: DateTime.now().toUtc().toIso8601String(),
      imageCount: 0,
      images: const {},
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          manifestEntryName,
          utf8.encode(jsonEncode(manifest.toJson())),
        ),
      )
      ..addFile(ArchiveFile.bytes(dbEntryName, Uint8List.fromList([1, 2, 3])));
    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      factory: databaseFactoryFfi,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );

    await expectLater(
      service.restorePackage(
        ZipEncoder().encodeBytes(archive),
        currentDb: db,
        openDb: () =>
            openZhixinDatabase(factory: databaseFactoryFfi, path: path),
      ),
      throwsA(isA<BackupException>()),
    );
    final materials = await db.query('material');
    expect(materials.single['title'], '当前材料');
  });

  test('V7：恢复中断后回到恢复前的数据', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_v7_journal_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';

    final before = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    await before.insert('material', {
      'title': '恢复前',
      'kind': 'book',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:00:00',
    });
    await before.close();

    final rollbackDir = '${dir.path}/.restore-test';
    await Directory(rollbackDir).create(recursive: true);
    await File(path).copy('$rollbackDir/zhixin.db');
    await Directory('$rollbackDir/$questionImagesDirName').create();

    // 模拟已经替换成另一份数据，但还没重新打开完成恢复。
    await File(path).delete();
    final replaced = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    await replaced.insert('material', {
      'title': '恢复后',
      'kind': 'book',
      'created_at': '2026-11-06 10:00:00',
      'updated_at': '2026-11-06 10:00:00',
    });
    await replaced.close();

    await RestoreJournal(dir.path).write(
      RestoreJournalEntry(
        stage: RestoreStage.replacing,
        rollbackDir: rollbackDir,
        startedAt: DateTime.now().toUtc().toIso8601String(),
        manifestSchemaVersion: zhixinSchemaVersion,
      ),
    );

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      factory: databaseFactoryFfi,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    expect(await service.recoverInterruptedRestore(), isTrue);
    final restored = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(restored.close);
    final materials = await restored.query('material');
    expect(materials.single['title'], '恢复前');
    expect(await RestoreJournal(dir.path).read(), isNull);
  });

  test('V7：同一格式重新打开时保留原文、附件与历史', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_v7_format_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final images = Directory('${dir.path}/$questionImagesDirName');
    await images.create(recursive: true);
    await File('${images.path}/m-1.jpg').writeAsBytes([9, 8, 7]);

    final first = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    final materialId = await first.insert('material', {
      'title': '概率论讲义',
      'kind': 'book',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:00:00',
    });
    await first.insert('material_page', {
      'material_id': materialId,
      'page_no': 3,
      'label': '条件概率',
      'content': '条件概率的定义。',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:00:00',
    });
    final conversationId = await first.insert('conversation', {
      'title': '条件概率讨论',
      'material_id': materialId,
      'page_no': 3,
      'entry_kind': 'text_photo',
      'status': 'open',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:05:00',
    });
    await first.insert('message', {
      'conversation_id': conversationId,
      'role': 'user',
      'content': '',
      'image_paths_json': '["m-1.jpg"]',
      'created_at': '2026-11-06 09:05:00',
    });
    await first.close();

    // 正常重启：版本不变，按同一结构打开，数据与附件都还在。
    final reopened = await openZhixinDatabase(
      factory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(reopened.close);
    expect(
      (await reopened.rawQuery('PRAGMA user_version')).first.values.first,
      zhixinSchemaVersion,
    );
    expect(await reopened.query('material'), hasLength(1));
    expect(await reopened.query('material_page'), hasLength(1));
    final messages = await reopened.query('message');
    expect(messages, hasLength(1));
    expect(messages.single['content'], '');
    final stored = jsonDecode(messages.single['image_paths_json']! as String);
    final fileName = (stored as List).single as String;
    final resolved = resolveAttachment(dir.path, fileName);
    expect(await File(resolved).exists(), isTrue);
    expect(await File(resolved).readAsBytes(), [9, 8, 7]);
  });
}
