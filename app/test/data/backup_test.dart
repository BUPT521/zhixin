import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/rules/attachments.dart';
import 'package:zhixin/data/backup/backup_manifest.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/restore_journal.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/study.dart';

import 'package:zhixin/data/db/sql.dart';

/// 造一条有作答的学习记录，用作导出与恢复的数据标记。
Future<String> _captureRecord(
  RawDatabase db,
  String stem, {
  String? sourceRef,
}) async {
  final conversations = ConversationRepository(db);
  final id = await conversations.create(sourceRef: sourceRef);
  await conversations.append(id, role: MessageRole.user, content: stem);
  await AttemptRepository(db).ensureOpenAttempt(id);
  return id;
}

Future<String?> _recordStem(RawDatabase db, String id) async =>
    (await ConversationRepository(db).question(id))?.stem;

/// 按旧格式造一份数据包：清单、库文件与被引用的图片。
Future<Uint8List> _packageBytes(
  String dbPath,
  Map<String, List<int>> images,
) async {
  final manifest = BackupManifest(
    schemaVersion: zhixinSchemaVersion,
    appVersion: 'test',
    exportedAt: DateTime.utc(2026, 11, 6).toIso8601String(),
    imageCount: images.length,
    images: {
      for (final entry in images.entries)
        '$questionImagesDirName/${entry.key}': sha256
            .convert(entry.value)
            .toString(),
    },
  );
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        manifestEntryName,
        utf8.encode(jsonEncode(manifest.toJson())),
      ),
    )
    ..addFile(ArchiveFile.bytes(dbEntryName, await File(dbPath).readAsBytes()));
  for (final entry in images.entries) {
    archive.addFile(
      ArchiveFile.bytes(
        '$questionImagesDirName/${entry.key}',
        Uint8List.fromList(entry.value),
      ),
    );
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

void main() {
  test('旧格式数据包能在新目录恢复，讨论与归属一起带回', () async {
    final dir1 = await Directory.systemTemp.createTemp('zhixin_export_');
    final dir2 = await Directory.systemTemp.createTemp('zhixin_restore_');
    addTearDown(() async {
      await dir1.delete(recursive: true);
      await dir2.delete(recursive: true);
    });

    final path1 = '${dir1.path}/zhixin.db';
    final db1 = await openZhixinDatabase(path: path1);
    final recordId = await _captureRecord(db1, '导出前的题目', sourceRef: '第 1 页');
    final goalId = 'goal-1';
    await insertRow(db1, 'learning_goal', {
      'id': goalId,
      'title': '概率论期末',
      'status': 'active',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:00:00',
    });
    final materialId = 'mat-1';
    await insertRow(db1, 'material', {
      'id': materialId,
      'title': '概率论课件',
      'kind': 'slides',
      'source_ref': '第 12 讲',
      'goal_id': goalId,
      'created_at': '2026-11-06 08:00:00',
      'updated_at': '2026-11-06 08:00:00',
    });
    await insertRow(db1, 'material_page', {
      'id': 'page-1',
      'material_id': materialId,
      'page_no': 12,
      'label': '条件概率',
      'content': '条件概率的定义与乘法公式。',
      'created_at': '2026-11-06 08:00:00',
      'updated_at': '2026-11-06 08:00:00',
    });
    final conversationId = 'conv-1';
    await insertRow(db1, 'conversation', {
      'id': conversationId,
      'title': '为什么这里需要独立性',
      'goal_id': goalId,
      'material_id': materialId,
      'page_no': 12,
      'entry_kind': 'text',
      'status': 'open',
      'created_at': '2026-11-06 09:00:00',
      'updated_at': '2026-11-06 09:05:00',
      'last_message_at': '2026-11-06 09:05:00',
    });
    await insertRow(db1, 'message', {
      'id': 'msg-1',
      'conversation_id': conversationId,
      'role': 'user',
      'content': '为什么这里需要独立性',
      'image_paths_json': '["m-1.jpg"]',
      'created_at': '2026-11-06 09:00:00',
    });
    await insertRow(db1, 'plan_item', {
      'id': 'item-1',
      'goal_id': goalId,
      'conversation_id': conversationId,
      'title': '重做第 8 题',
      'status': 'todo',
      'source': 'ai',
      'created_at': '2026-11-06 09:06:00',
      'updated_at': '2026-11-06 09:06:00',
    });
    final images = Directory('${dir1.path}/question_images');
    await images.create(recursive: true);
    await File('${images.path}/m-1.jpg').writeAsBytes([4, 5, 6]);
    await File('${images.path}/orphan.jpg').writeAsBytes([9, 9, 9]);

    final service1 = DataPackageService(
      filesDir: dir1.path,
      dbPath: path1,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    await db1.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    final bytes = await _packageBytes(path1, {
      'm-1.jpg': [4, 5, 6],
    });
    final inspection = await service1.inspectPackage(bytes);
    expect(inspection.schemaVersion, zhixinSchemaVersion);
    expect(inspection.exportedAt, isNotEmpty);
    expect(inspection.rowCount, greaterThan(0));
    await db1.close();

    final path2 = '${dir2.path}/zhixin.db';
    final db2 = await openZhixinDatabase(path: path2);
    final service2 = DataPackageService(
      filesDir: dir2.path,
      dbPath: path2,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    final restored = await service2.restorePackage(
      bytes,
      currentDb: db2,
      openDb: () => openZhixinDatabase(path: path2),
    );
    addTearDown(restored.close);

    final record = await ConversationRepository(restored).question(recordId);
    expect(record!.stem, '导出前的题目');
    expect(record.sourceRef, '第 1 页');

    final conversations = await selectRows(restored, 'conversation');
    expect(conversations, hasLength(2));
    final discussion = conversations.firstWhere(
      (row) => row['id'] == conversationId,
    );
    expect(discussion['title'], '为什么这里需要独立性');
    expect(discussion['goal_id'], goalId);
    expect(discussion['material_id'], materialId);
    expect(discussion['page_no'], 12);

    final pages = await selectRows(restored, 'material_page');
    expect(pages, hasLength(1));
    expect(pages.first['content'], '条件概率的定义与乘法公式。');

    final messages = await selectRows(restored, 'message');
    expect(messages, hasLength(2));
    final imageMessage = messages.firstWhere(
      (row) => row['conversation_id'] == conversationId,
    );

    // 附件随包恢复，数据库里仍只存文件名。
    final restoredImage = File('${dir2.path}/question_images/m-1.jpg');
    expect(await restoredImage.exists(), isTrue);
    expect(await restoredImage.readAsBytes(), [4, 5, 6]);
    expect(imageMessage['image_paths_json'], '["m-1.jpg"]');

    final tasks = TaskRepository(restored);
    expect((await tasks.goalById(goalId))?.status, LearningGoalStatus.active);
    final items = await tasks.items();
    expect(items, hasLength(1));
    expect(items.single.conversationId, conversationId);
    expect(items.single.status, PlanItemStatus.todo);
  });

  test('恢复中断后按阶段记录回到恢复前的库', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_interrupt_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final db = await openZhixinDatabase(path: path);
    final recordId = await _captureRecord(db, '恢复前的题目');
    await db.close();

    // 模拟“替换之后进程结束”：正式库已经是包里的另一份数据，
    // 回滚目录里留着恢复前的库，阶段记录停在 replacing。
    final snapshotDir = Directory('${dir.path}/.restore-1');
    await snapshotDir.create(recursive: true);
    await File(path).copy('${snapshotDir.path}/$dbEntryName');
    await Directory('${snapshotDir.path}/$questionImagesDirName')
        .create(recursive: true);

    final incomingDb = await openZhixinDatabase(
      path: '${dir.path}/incoming.db',
    );
    await _captureRecord(incomingDb, '替换后的题目');
    await incomingDb.close();
    await File('${dir.path}/incoming.db').copy(path);

    // 半成品文件也留一个，启动时应当被清掉。
    await File('${dir.path}/incoming.db').copy('$path.incoming');

    await File('${dir.path}/.restore-journal.json').writeAsString(
      jsonEncode({
        'stage': 'replacing',
        'rollback_dir': snapshotDir.path,
        'started_at': '2026-11-07T00:00:00Z',
        'manifest_schema_version': zhixinSchemaVersion,
      }),
    );

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    final rolledBack = await service.recoverInterruptedRestore();
    expect(rolledBack, isTrue);
    expect(await File('${dir.path}/.restore-journal.json').exists(), isFalse);
    expect(await snapshotDir.exists(), isFalse);
    expect(await File('$path.incoming').exists(), isFalse);

    final recovered = await openZhixinDatabase(path: path);
    addTearDown(recovered.close);
    expect(await _recordStem(recovered, recordId), '恢复前的题目');
  });

  test('阶段记录尚未创建就中断时清掉半成品，不动正式库', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_stale_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final db = await openZhixinDatabase(path: path);
    final recordId = await _captureRecord(db, '中断前的题目');
    await db.close();

    // 初始阶段记录尚未创建，正式库还没有进入替换阶段。
    await Directory('${dir.path}/.restore-1').create(recursive: true);
    await File('${dir.path}/.restore-1/zhixin.db').writeAsBytes([1, 2, 3]);
    await File('$path.incoming').writeAsBytes([4, 5, 6]);

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    expect(await service.recoverInterruptedRestore(), isFalse);
    expect(await File('${dir.path}/.restore-journal.json').exists(), isFalse);
    expect(await Directory('${dir.path}/.restore-1').exists(), isFalse);
    expect(await File('$path.incoming').exists(), isFalse);

    final reopened = await openZhixinDatabase(path: path);
    addTearDown(reopened.close);
    expect(await _recordStem(reopened, recordId), '中断前的题目');
  });

  test('恢复日志损坏时保留当前数据与回滚副本', () async {
    final dir = await Directory.systemTemp.createTemp(
      'zhixin_corrupt_journal_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final db = await openZhixinDatabase(path: path);
    final recordId = await _captureRecord(db, '当前正式数据');
    await db.close();

    final snapshot = Directory('${dir.path}/.restore-keep');
    await snapshot.create(recursive: true);
    await File(path).copy('${snapshot.path}/$dbEntryName');
    await Directory('${snapshot.path}/$questionImagesDirName').create();
    await File('${dir.path}/.restore-journal.json').writeAsString('{');
    await File('$path.incoming').writeAsBytes([1, 2, 3]);

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    await expectLater(
      service.recoverInterruptedRestore(),
      throwsA(isA<BackupException>()),
    );
    expect(await snapshot.exists(), isTrue);
    expect(await File('${dir.path}/.restore-journal.json').exists(), isTrue);
    expect(await File('$path.incoming').exists(), isTrue);

    final reopened = await openZhixinDatabase(path: path);
    addTearDown(reopened.close);
    expect(await _recordStem(reopened, recordId), '当前正式数据');
  });

  test('回滚快照缺少数据库时保留正式图片与阶段记录', () async {
    final dir = await Directory.systemTemp.createTemp(
      'zhixin_incomplete_snapshot_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final images = Directory('${dir.path}/$questionImagesDirName');
    await images.create(recursive: true);
    final image = File('${images.path}/current.jpg');
    await image.writeAsBytes([7, 8, 9]);
    final db = await openZhixinDatabase(path: path);
    await _captureRecord(db, '当前正式数据');
    await db.close();

    final rollbackDir = '${dir.path}/.restore-incomplete';
    await Directory(rollbackDir).create(recursive: true);
    await Directory('$rollbackDir/$questionImagesDirName').create();
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
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );

    await expectLater(
      service.recoverInterruptedRestore(),
      throwsA(isA<BackupException>()),
    );
    expect(await image.exists(), isTrue);
    expect(await image.readAsBytes(), [7, 8, 9]);
    expect(await RestoreJournal(dir.path).read(), isNotNull);
    expect(await Directory(rollbackDir).exists(), isTrue);
  });

  test('已提交阶段中断后只清理回滚副本，不回滚新数据', () async {
    final dir = await Directory.systemTemp.createTemp(
      'zhixin_committed_journal_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final current = await openZhixinDatabase(path: path);
    final recordId = await _captureRecord(current, '已提交的新数据');
    await current.close();

    final rollbackDir = '${dir.path}/.restore-committed';
    await Directory(rollbackDir).create(recursive: true);
    final old = await openZhixinDatabase(path: '${dir.path}/old.db');
    await _captureRecord(old, '旧数据');
    await old.close();
    await File('${dir.path}/old.db').copy('$rollbackDir/$dbEntryName');
    await Directory('$rollbackDir/$questionImagesDirName').create();
    await RestoreJournal(dir.path).write(
      RestoreJournalEntry(
        stage: RestoreStage.committed,
        rollbackDir: rollbackDir,
        startedAt: DateTime.now().toUtc().toIso8601String(),
        manifestSchemaVersion: zhixinSchemaVersion,
      ),
    );

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );
    expect(await service.recoverInterruptedRestore(), isFalse);
    expect(await Directory(rollbackDir).exists(), isFalse);
    final reopened = await openZhixinDatabase(path: path);
    addTearDown(reopened.close);
    expect(await _recordStem(reopened, recordId), '已提交的新数据');
  });

  test('其他版本的备份都在恢复入口拒绝，且不碰当前库', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_old_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/zhixin.db';
    final db = await openZhixinDatabase(path: path);
    addTearDown(db.close);

    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: path,
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );

    for (final oldVersion in [11, 12, 16, 17, 18, 19, 21]) {
      final manifest = BackupManifest(
        schemaVersion: oldVersion,
        appVersion: 'old',
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
        ..addFile(
          ArchiveFile.bytes(dbEntryName, Uint8List.fromList([1, 2, 3])),
        );
      await expectLater(
        service.restorePackage(
          ZipEncoder().encodeBytes(archive),
          currentDb: db,
          openDb: () => openZhixinDatabase(path: path),
        ),
        throwsA(isA<BackupException>()),
        reason: 'v$oldVersion 的包应当在替换前被拒绝',
      );
    }
    expect(await selectRows(db, 'conversation'), isEmpty);
    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, zhixinSchemaVersion);
  });

  test('数据包预检拒绝版本不一致与图片校验失败的包', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_inspect_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final service = DataPackageService(
      filesDir: dir.path,
      dbPath: '${dir.path}/zhixin.db',
      appVersion: 'test',
      schemaVersion: zhixinSchemaVersion,
    );

    Uint8List packageOf(int schemaVersion) {
      final manifest = BackupManifest(
        schemaVersion: schemaVersion,
        appVersion: 'test',
        exportedAt: DateTime.now().toUtc().toIso8601String(),
        imageCount: 1,
        images: {'question_images/a.jpg': List.filled(64, '0').join()},
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            manifestEntryName,
            utf8.encode(jsonEncode(manifest.toJson())),
          ),
        )
        ..addFile(ArchiveFile.bytes(dbEntryName, Uint8List.fromList([1, 2, 3])))
        ..addFile(
          ArchiveFile.bytes(
            'question_images/a.jpg',
            Uint8List.fromList([1, 2, 3]),
          ),
        );
      return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    }

    await expectLater(
      service.inspectPackage(packageOf(zhixinSchemaVersion - 1)),
      throwsA(
        isA<BackupException>().having(
          (error) => error.message,
          'message',
          contains('schema'),
        ),
      ),
    );
    await expectLater(
      service.inspectPackage(packageOf(zhixinSchemaVersion)),
      throwsA(
        isA<BackupException>().having(
          (error) => error.message,
          'message',
          contains('图片校验失败'),
        ),
      ),
    );
  });
}
