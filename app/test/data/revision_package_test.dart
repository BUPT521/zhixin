import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_package.dart';

import 'package:zhixin/data/db/sql.dart';

void main() {
  test('当前数据包导出与导入只含业务投影和附件', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_package');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = await openZhixinDatabase(path: '${dir.path}/zhixin.db');
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final packages = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      clock: () => DateTime(2026, 11, 10, 10),
    );
    final bytes = Uint8List.fromList(List<int>.generate(500, (i) => i % 251));
    final hash = AssetStore.hashBytes(bytes);
    const conversation = 'conv-1';
    await insertRow(db, 'conversation', {
      'id': conversation,
      'title': '带图',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    await db.transaction((txn) async {
      await engine.assets.putBytes(txn, hash, bytes);
      await insertRow(txn, 'message', {
        'id': 'msg-1',
        'conversation_id': conversation,
        'role': 'user',
        'content': '',
        'image_paths_json': '["$hash"]',
        'created_at': '2026-11-10T10:00:00',
      });
    });
    final before = await engine.headId(raw);
    final path = '${dir.path}/current.zip';
    await packages.exportCurrent(db, path);

    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
    );
    expect(manifest['kind'], 'current_data');
    expect(manifest['asset_count'], 1);
    expect(archive.findFile('assets/$hash'), isNotNull);
    expect(
      (archive.files.map((file) => file.name))
          .where((name) => name.startsWith('revision_')),
      isEmpty,
    );

    await deleteRows(
      db,
      'conversation',
      where: 'id = ?',
      whereArgs: [conversation],
    );
    expect(await selectRows(raw, 'message'), isEmpty);
    final current = await engine.headId(raw);
    final commit = await packages.importCurrent(
      raw,
      await File(path).readAsBytes(),
      expectedHead: current,
    );
    expect(commit.action, '导入数据');
    expect(commit.generation, 1);
    expect(await selectRows(raw, 'conversation'), hasLength(1));
    expect(await selectRows(raw, 'message'), hasLength(1));
    expect(await engine.assets.verify(raw, hash), isTrue);
    expect(await engine.headId(raw), greaterThan(before));
  });

  test('导出前核对数据库引用与附件，缺图时中止并列出缺项', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_missing_asset');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = await openZhixinDatabase(path: '${dir.path}/zhixin.db');
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final packages = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      clock: () => DateTime(2026, 11, 10, 10),
    );
    const conversation = 'conv-1';
    await insertRow(db, 'conversation', {
      'id': conversation,
      'title': '缺图',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    final missingHash = 'a' * 64;
    await insertRow(db, 'message', {
      'id': 'msg-1',
      'conversation_id': conversation,
      'role': 'user',
      'content': '',
      'image_paths_json': '["$missingHash"]',
      'created_at': '2026-11-10T10:00:00',
    });

    final current = '${dir.path}/current.zip';
    await expectLater(
      packages.exportCurrent(db, current),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('附件'), contains(missingHash)),
        ),
      ),
    );
    expect(await File(current).exists(), isFalse);

    final repository = '${dir.path}/repository.zip';
    await expectLater(
      packages.backupRepository(raw, repository),
      throwsA(anything),
    );
    expect(await File(repository).exists(), isFalse);
  });

  test('版本库备份包含 HEAD、历史与附件', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_repository');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = await openZhixinDatabase(path: '${dir.path}/zhixin.db');
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final packages = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      clock: () => DateTime(2026, 11, 10, 10),
    );
    const goal = 'goal-1';
    await insertRow(db, 'learning_goal', {
      'id': goal,
      'title': '备份目标',
      'status': 'active',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    await updateRow(
      db,
      'learning_goal',
      {'title': '备份目标二'},
      where: 'id = ?',
      whereArgs: [goal],
    );
    await engine.nameCommit(raw, await engine.headId(raw), name: '命名');
    final head = await engine.headId(raw);
    final path = '${dir.path}/repository.zip';
    await packages.backupRepository(raw, path);

    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
    );
    expect(manifest['kind'], 'repository');
    expect(manifest['head'], head);
    final dbFile = archive.findFile('zhixin.db');
    expect(dbFile, isNotNull);
    final extracted = '${dir.path}/restored.db';
    await File(extracted).writeAsBytes(dbFile!.content as List<int>);
    final restored = await openZhixinDatabase(path: extracted);
    addTearDown(restored.close);
    expect(await engine.headId(restored), head);
    expect(await selectRows(restored, 'revision_commit'), hasLength(3));
    expect(
      await selectRows(
        restored,
        'revision_ref',
        where: 'name = ?',
        whereArgs: ['命名'],
      ),
      hasLength(1),
    );
    expect(
      (await selectRows(restored, 'learning_goal')).single['title'],
      '备份目标二',
    );
    expect(
      await packages.validateRepositoryBytes(await File(path).readAsBytes()),
      isTrue,
    );
    final inspection = await packages.inspectRepository(
      await File(path).readAsBytes(),
    );
    expect(inspection, isNotNull);
    expect(inspection!.head, head);
    expect(inspection.commitCount, 3);
    expect(inspection.namedCount, 1);
    expect(inspection.exportedAt, isNotEmpty);
    final broken = await File(path).readAsBytes();
    broken[broken.length ~/ 2] ^= 0xff;
    await expectLater(
      packages.validateRepositoryBytes(broken),
      throwsA(anything),
    );
  });

  test('版本库备份拒绝数据库里额外的触发器，预检也不接受改过的包', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_trigger_guard');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = await openZhixinDatabase(path: '${dir.path}/zhixin.db');
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final packages = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      clock: () => DateTime(2026, 11, 10, 10),
    );
    final path = '${dir.path}/repository.zip';
    await packages.backupRepository(raw, path);

    // 备份完成后往库里加一条不属于本程序的触发器；备份与预检都不能把它带走。
    await raw.execute(
      'CREATE TRIGGER evil_after_insert AFTER INSERT ON learning_goal '
      'BEGIN UPDATE app_meta SET value = value; END',
    );
    await expectLater(
      packages.backupRepository(raw, '${dir.path}/with-trigger.zip'),
      throwsA(anything),
    );
    expect(await File('${dir.path}/with-trigger.zip').exists(), isFalse);

    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final originalDb = archive.findFile('zhixin.db')!.content as List<int>;
    final tamperedPath = '${dir.path}/tampered.db';
    await File(tamperedPath).writeAsBytes(originalDb);
    final tampered = sqlite3.sqlite3.open(tamperedPath);
    tampered.execute(
      'CREATE TRIGGER evil_on_insert AFTER INSERT ON learning_goal '
      'BEGIN UPDATE app_meta SET value = value; END',
    );
    tampered.close();
    final tamperedBytes = await File(tamperedPath).readAsBytes();
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
    ) as Map<String, Object?>;
    manifest['database_sha256'] = sha256.convert(tamperedBytes).toString();
    final tamperedZip = '${dir.path}/tampered.zip';
    final encoder = ZipFileEncoder()..create(tamperedZip);
    encoder.addArchiveFile(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      ),
    );
    encoder.addArchiveFile(ArchiveFile.bytes('zhixin.db', tamperedBytes));
    await encoder.close();

    await expectLater(
      packages.inspectRepository(await File(tamperedZip).readAsBytes()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('触发器'),
        ),
      ),
    );
  });

  test('当前数据包不是版本库备份，预检返回 null', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_package_kind');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = await openZhixinDatabase(path: '${dir.path}/zhixin.db');
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final packages = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      clock: () => DateTime(2026, 11, 10, 10),
    );
    final path = '${dir.path}/current.zip';
    await packages.exportCurrent(db, path);

    expect(
      await packages.inspectRepository(await File(path).readAsBytes()),
      isNull,
    );
  });
}
