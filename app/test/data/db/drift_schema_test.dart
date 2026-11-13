import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/schema.dart';

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
}
