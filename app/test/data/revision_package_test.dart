import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/domain/models/revision_models.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/models/backup_error.dart';
import 'package:zhixin/domain/rules/package_budget.dart';

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
        'image_hashes_json': '["$hash"]',
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
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    final missingHash = 'a' * 64;
    await insertRow(db, 'message', {
      'id': 'msg-1',
      'conversation_id': conversation,
      'role': 'user',
      'content': '',
      'image_hashes_json': '["$missingHash"]',
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
    final inspection = await packages.inspectRepository(
      await File(path).readAsBytes(),
    );
    expect(inspection, isNotNull);
    expect(inspection!.head, head);
    expect(inspection.commitCount, 3);
    expect(inspection.namedCount, 1);
    expect(inspection.exportedAt, isNotEmpty);
    expect(inspection.databaseBytes, isNotEmpty);
    expect(inspection.expectedRows.values.fold(0, (sum, n) => sum + n), 1);
    final broken = await File(path).readAsBytes();
    broken[broken.length ~/ 2] ^= 0xff;
    await expectLater(packages.inspectRepository(broken), throwsA(anything));
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
        isA<BackupException>().having(
          (error) => error.message,
          'message',
          contains('触发器'),
        ),
      ),
    );
  });

  test('版本库预检按当前结构核对表，恢复入口不再重跑校验', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_missing_table');
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

    // 只删掉一张业务表：对象白名单、完整性与外键仍然通过，只有按当前结构打开
    // 之后的表核对会发现它。预检必须在这里拒绝，恢复入口才不会重跑一遍校验。
    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final originalDb = archive.findFile('zhixin.db')!.content as List<int>;
    final damagedPath = '${dir.path}/damaged.db';
    await File(damagedPath).writeAsBytes(originalDb);
    final damaged = sqlite3.sqlite3.open(damagedPath);
    damaged.execute('DROP TABLE plan_item');
    damaged.close();
    final damagedBytes = await File(damagedPath).readAsBytes();
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content as List<int>),
    ) as Map<String, Object?>;
    manifest['database_sha256'] = sha256.convert(damagedBytes).toString();
    final damagedZip = '${dir.path}/damaged.zip';
    final encoder = ZipFileEncoder()..create(damagedZip);
    encoder.addArchiveFile(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      ),
    );
    encoder.addArchiveFile(ArchiveFile.bytes('zhixin.db', damagedBytes));
    await encoder.close();

    await expectLater(
      packages.inspectRepository(await File(damagedZip).readAsBytes()),
      throwsA(isA<BackupException>()),
      reason: '预检一次做完完整性、对象与表结构核对，恢复只写入已经通过的字节',
    );
  });

  test('当前数据包导入超预算时拒绝，当前库不动', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_package_budget');
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
    const conversation = 'conv-budget';
    await insertRow(db, 'conversation', {
      'id': conversation,
      'title': '预算检查前',
      'entry_kind': 'text',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    final path = '${dir.path}/current.zip';
    await packages.exportCurrent(db, path);
    final bytes = await File(path).readAsBytes();
    await deleteRows(
      db,
      'conversation',
      where: 'id = ?',
      whereArgs: [conversation],
    );
    final head = await engine.headId(raw);
    final commitsBefore = await selectRows(raw, 'revision_commit');

    // 包里有 manifest.json 与 data.json 两个条目。
    final strict = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      budget: const PackageBudget(maxEntries: 1),
      clock: () => DateTime(2026, 11, 10, 10),
    );
    await expectLater(
      strict.importCurrent(raw, bytes, expectedHead: head),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('条目'), contains('没有读取')),
        ),
      ),
    );

    expect(await selectRows(raw, 'conversation'), isEmpty);
    expect(await engine.headId(raw), head);
    expect(
      await selectRows(raw, 'revision_commit'),
      hasLength(commitsBefore.length),
    );
  });

  test('版本库备份超预算时预检拒绝，当前库不动', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_repo_budget');
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
    await insertRow(raw, 'learning_goal', {
      'id': 'goal-budget',
      'title': '预算检查前',
      'status': 'active',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    final path = '${dir.path}/repository.zip';
    await packages.backupRepository(raw, path);
    final bytes = await File(path).readAsBytes();
    final head = await engine.headId(raw);
    final goalsBefore = await selectRows(raw, 'learning_goal');

    final strict = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      budget: const PackageBudget(maxDatabaseBytes: 1024),
      clock: () => DateTime(2026, 11, 10, 10),
    );
    await expectLater(
      strict.inspectRepository(bytes),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('zhixin.db'), contains('没有读取')),
        ),
      ),
    );

    expect(await engine.headId(raw), head);
    expect(
      await selectRows(raw, 'learning_goal'),
      hasLength(goalsBefore.length),
    );
    expect((await selectRows(raw, 'learning_goal')).single['title'], '预算检查前');
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
    final bytes = await File(path).readAsBytes();

    expect(await packages.inspectRepository(bytes), isNull);

    // 当前数据包的 kind 不是 repository，即使预算小到必然超限也返回 null：
    // 恢复入口据此继续走旧数据包预检，预算检查不能把这个分支变成异常。
    final strict = RevisionPackageService(
      engine: engine,
      assets: engine.assets,
      schemaVersion: zhixinSchemaVersion,
      appVersion: 'test',
      budget: const PackageBudget(maxEntries: 0, maxPackageBytes: 1),
      clock: () => DateTime(2026, 11, 10, 10),
    );
    expect(await strict.inspectRepository(bytes), isNull);
  });

  test('笔记正文与编号列里形如哈希的文本不算附件引用', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_hex_text');
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
    // 笔记正文就是一个完整的 SHA-256；旧口径会把它当成缺失的附件（审查 S17）。
    final hashLike = 'a' * 64;
    const memoryId = 'memory-hex';
    await insertRow(db, 'memory', {
      'id': memoryId,
      'kind': 'semantic',
      'content': hashLike,
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    // `memory_usage.id` 曾经由内容哈希生成，形状也是 64 位十六进制；它在声明之外，
    // 同样不算附件引用。
    await insertRow(db, 'memory_usage', {
      'id': hashLike,
      'memory_id': memoryId,
      'device_id': 'device-1',
      'updated_at': '2026-11-10T10:00:00',
    });

    final path = '${dir.path}/current.zip';
    await packages.exportCurrent(db, path);

    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    expect(archive.findFile('assets/$hashLike'), isNull);
    expect(await selectRows(db, 'memory'), hasLength(1));
  });

  test('投影与版本明细只把声明过的列算作附件引用', () {
    final single = 'b' * 64;
    final array = 'c' * 64;
    final ignored = 'd' * 64;
    final Projection projection = {
      'material': {
        'mat-1': typedRow({'id': 'mat-1', 'source_file_hash': single}),
      },
      'message': {
        'msg-1': typedRow({'id': 'msg-1', 'image_hashes_json': '["$array"]'}),
      },
      'memory': {
        'mem-1': typedRow({'id': 'mem-1', 'content': ignored}),
      },
    };
    expect(
      AssetStore.hashesInProjection(projection),
      unorderedEquals([single, array]),
    );

    final changes = [
      RevisionChange(
        commitId: 1,
        seq: 1,
        table: 'material',
        rowKey: 'mat-1',
        op: ChangeOp.insert,
        after: typedRow({'id': 'mat-1', 'source_file_hash': single}),
      ),
      RevisionChange(
        commitId: 1,
        seq: 2,
        table: 'message',
        rowKey: 'msg-1',
        op: ChangeOp.insert,
        after: typedRow({'id': 'msg-1', 'image_hashes_json': '["$array"]'}),
      ),
      RevisionChange(
        commitId: 1,
        seq: 3,
        table: 'memory',
        rowKey: 'mem-1',
        op: ChangeOp.insert,
        after: typedRow({'id': 'mem-1', 'content': ignored}),
      ),
    ];
    expect(
      AssetStore.hashesInChanges(changes),
      unorderedEquals([single, array]),
    );
  });
}
