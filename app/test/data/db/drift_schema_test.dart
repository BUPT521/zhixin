import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/schema.dart'
    show requiredColumns, schemaIndexStatements, schemaTableNames;

void main() {
  test('drift 建出的库覆盖 schema 26 的全部表与必需列', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    final names = rows.map((row) => row.read<String>('name')).toSet();
    expect(names, containsAll(schemaTableNames()));

    for (final entry in requiredColumns.entries) {
      final info = await db
          .customSelect('PRAGMA table_info("${entry.key}")')
          .get();
      final columns = info.map((row) => row.read<String>('name')).toSet();
      expect(columns, containsAll(entry.value), reason: entry.key);
    }
  });

  test('外键动作与复合主键与 DDL 一致', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final messageFks = await db
        .customSelect('PRAGMA foreign_key_list("message")')
        .get();
    final conversation = messageFks.firstWhere(
      (row) => row.read<String>('table') == 'conversation',
    );
    expect(conversation.read<String>('on_delete'), 'CASCADE');

    final materialFks = await db
        .customSelect('PRAGMA foreign_key_list("material_page")')
        .get();
    final material = materialFks.firstWhere(
      (row) => row.read<String>('table') == 'material',
    );
    expect(material.read<String>('on_delete'), 'CASCADE');

    final changePk = await db
        .customSelect('PRAGMA table_info("revision_change")')
        .get();
    final primary = changePk
        .where((row) => row.read<int>('pk') > 0)
        .map((row) => row.read<String>('name'))
        .toList();
    expect(primary, ['commit_id', 'seq']);

    final chunkPk = await db
        .customSelect('PRAGMA table_info("asset_chunk")')
        .get();
    final chunkPrimary = chunkPk
        .where((row) => row.read<int>('pk') > 0)
        .map((row) => row.read<String>('name'))
        .toList();
    expect(chunkPrimary, ['hash', 'seq']);
  });

  test('打开后版本与外键开关就位', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 26);

    final foreignKeys = await db
        .customSelect('PRAGMA foreign_keys')
        .getSingle();
    expect(foreignKeys.read<int>('foreign_keys'), 1);
  });

  test('新库建立全部业务索引并开启 WAL', () async {
    final temp = await Directory.systemTemp.createTemp('zhixin_drift_schema');
    addTearDown(() => temp.delete(recursive: true));
    final db = AppDatabase(
      NativeDatabase(File(p.join(temp.path, 'zhixin.db'))),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final names =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master "
                  "WHERE type = 'index' AND name LIKE 'idx_%'",
                )
                .get())
            .map((row) => row.read<String>('name'))
            .toSet();
    for (final statement in schemaIndexStatements()) {
      final match = RegExp(r'INDEX\s+IF NOT EXISTS\s+(\w+)')
          .firstMatch(statement);
      expect(match, isNotNull, reason: statement);
      expect(names, contains(match!.group(1)), reason: statement);
    }

    final mode = await db.customSelect('PRAGMA journal_mode').getSingle();
    expect(mode.read<String>('journal_mode'), 'wal');
  });
}
