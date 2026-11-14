import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/fts.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/schema.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

void main() {
  test('新库是 v26，15 张业务表与版本元数据就位', () async {
    final db = await openTestDb();
    addTearDown(db.close);

    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, zhixinSchemaVersion);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final names = {for (final row in tables) row['name']! as String};
    expect(names, containsAll(schemaTableNames()));
    // 关键词索引表与影子表不进业务表计数，也不参与版本采集。
    final businessNames = names.where(
      (name) =>
          !name.startsWith('rev_stage_') && !ftsTableNames().contains(name),
    );
    expect(businessNames.length, schemaTableNames().length);
    expect(names, containsAll(ftsTableNames()));
    final classified = {
      ...versionedTableNames,
      ...revisionMetadataTables,
      ...nonVersionedPersistentTables,
    };
    for (final table in businessNames) {
      expect(classified, contains(table), reason: '表 $table 没有登记版本分类');
    }
    for (final table in versionedTableNames) {
      expect(
        ftsTableNames(),
        isNot(contains(table)),
        reason: '关键词索引表 $table 不能登记为业务表',
      );
    }
    final triggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    );
    final triggerNames = {for (final row in triggers) row['name']! as String};
    expect(triggerNames, contains('rev_capture_message_insert'));
    for (final table in versionedTableNames) {
      for (final operation in ['insert', 'update', 'delete']) {
        expect(triggerNames, contains('rev_capture_${table}_$operation'));
      }
    }
    expect(names, isNot(contains('study_step')));
    expect(names, isNot(contains('correction')));
    expect(names, isNot(contains('question')));
    expect(names, isNot(contains('operation_log')));

    final profile = await db.query('profile');
    expect(profile, hasLength(1));
    expect(profile.first['day_cutoff_hour'], 4);

    final meta = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(meta.first['value'], '$zhixinSchemaVersion');

    Future<Set<String>> columns(String table) async {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      return {for (final row in info) row['name']! as String};
    }

    expect(
      await columns('conversation'),
      containsAll([
        'material_id',
        'page_no',
        'source_ref',
        'context_text',
        'goal_id',
        'question_message_id',
        'status',
      ]),
    );
    expect(await columns('study_session'), contains('conversation_id'));
    expect(await columns('attempt'), contains('redo_of_attempt_id'));
    expect(await columns('attempt'), contains('solution'));
    expect(
      await columns('material_page'),
      containsAll(['material_id', 'page_no', 'content']),
    );
    expect(
      await columns('study_plan'),
      containsAll(['material_id', 'current_page', 'status']),
    );
    final scheduleColumns = await columns('schedule_block');
    expect(scheduleColumns, contains('locked'));
    expect(scheduleColumns, isNot(contains('authorized')));
    expect(await columns('attempt'), contains('delayed'));
    expect(
      await columns('plan_item'),
      containsAll([
        'priority',
        'study_plan_id',
        'seq',
        'page_from',
        'page_to',
        'note',
      ]),
    );
    expect(await columns('assessment'), contains('kind'));
    expect(await columns('assessment'), isNot(contains('verified')));
    final attemptColumns = await columns('attempt');
    expect(attemptColumns, contains('conversation_id'));
    expect(attemptColumns, isNot(contains('hint_used')));
    expect(attemptColumns, isNot(contains('question_id')));
    expect(attemptColumns, isNot(contains('help_count')));
    expect(attemptColumns, isNot(contains('analysis_json')));
    final planColumns = await columns('plan_item');
    expect(planColumns, isNot(contains('action')));
    expect(planColumns, isNot(contains('end_condition')));
    expect(await columns('memory'), isNot(contains('confidence')));
    final profileColumns = await columns('profile');
    expect(profileColumns, isNot(contains('nickname')));
    expect(profileColumns, isNot(contains('daily_target_minutes')));
    expect(profileColumns, isNot(contains('preferences_json')));
    expect(await columns('message'), isNot(contains('answer_version')));
    expect(await columns('assessment'), isNot(contains('source_json')));
    expect(await columns('memory'), isNot(contains('valid_from')));
    final assessmentSql =
        (await db.query(
              'sqlite_master',
              where: "type = 'table' AND name = 'assessment'",
            )).first['sql']!
            as String;
    expect(assessmentSql, isNot(contains("'self'")));
    await expectLater(
      db.insert('attempt', {
        'created_at': '2026-11-07 09:00:00',
        'updated_at': '2026-11-07 09:00:00',
      }),
      throwsA(anything),
    );
  });

  test('库版本不一致时清空旧表并重建', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_schema_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';

    final legacy = sqlite3.sqlite3.open(path);
    try {
      legacy.execute('PRAGMA user_version = 9');
      final old = SqliteRawDatabase(legacy);
      await old.execute(
        'CREATE TABLE knowledge_node (id INTEGER PRIMARY KEY, name TEXT)',
      );
      await old.execute(
        'CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT)',
      );
      await old.insert('knowledge_node', {'name': '极限'});
    } finally {
      legacy.close();
    }

    final upgraded = await openZhixinDatabase(path: path);
    addTearDown(upgraded.close);

    final removed = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_node'",
    );
    expect(removed, isEmpty);
    expect(
      await upgraded
          .rawQuery('PRAGMA user_version')
          .then((rows) => rows.first.values.first),
      zhixinSchemaVersion,
    );
    final attempts = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'attempt'",
    );
    expect(attempts, isNotEmpty);
  });

  test('v11 开发库按新结构重建，不保留旧材料结构', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_v11_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';

    final legacy = sqlite3.sqlite3.open(path);
    try {
      legacy.execute('PRAGMA user_version = 11');
      final old = SqliteRawDatabase(legacy);
      await old.execute(
        'CREATE TABLE conversation ('
        'id INTEGER PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT)',
      );
      await old.execute(
        'CREATE TABLE material (id INTEGER PRIMARY KEY, title TEXT)',
      );
      await old.insert('conversation', {
        'title': '旧讨论',
        'created_at': '2026-11-06 09:00:00',
        'updated_at': '2026-11-06 09:00:00',
      });
    } finally {
      legacy.close();
    }

    final rebuilt = await openZhixinDatabase(path: path);
    addTearDown(rebuilt.close);

    expect(await rebuilt.query('conversation'), isEmpty);
    final info = await rebuilt.rawQuery('PRAGMA table_info(conversation)');
    final columns = {for (final row in info) row['name']! as String};
    expect(columns, containsAll(['material_id', 'page_no', 'entry_kind']));
    final materialInfo = await rebuilt.rawQuery('PRAGMA table_info(material)');
    expect({
      for (final row in materialInfo) row['name']! as String,
    }, containsAll(['kind', 'source_ref', 'goal_id']));
    final pages = await rebuilt.rawQuery('PRAGMA table_info(material_page)');
    expect(pages, isNotEmpty);
  });

  test('旧库按当前结构重建，不迁移旧步骤与旧状态', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_v16_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';

    final legacy = sqlite3.sqlite3.open(path);
    try {
      legacy.execute('PRAGMA user_version = 16');
      final old = SqliteRawDatabase(legacy);
      await old.execute('''
            CREATE TABLE app_meta (
              key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL
            )
          ''');
      await old.execute(
        'CREATE TABLE learning_goal ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, '
        'status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
      );
      await old.execute(
        'CREATE TABLE conversation ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, '
        'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
      );
      await old.execute(
        'CREATE TABLE study_plan ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, '
        'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
      );
      await old.execute('''
            CREATE TABLE plan_item (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              goal_id INTEGER REFERENCES learning_goal(id) ON DELETE SET NULL,
              conversation_id INTEGER REFERENCES conversation(id) ON DELETE SET NULL,
              study_plan_id INTEGER REFERENCES study_plan(id) ON DELETE CASCADE,
              title TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
      await old.execute('''
            CREATE TABLE schedule_block (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              plan_item_id INTEGER NOT NULL REFERENCES plan_item(id) ON DELETE CASCADE,
              start_at TEXT NOT NULL,
              end_at TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
      await old.execute(
        'CREATE TABLE question ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, stem TEXT NOT NULL, '
        'origin TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
      );
      await old.execute('''
            CREATE TABLE attempt (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              question_id INTEGER NOT NULL REFERENCES question(id) ON DELETE CASCADE,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
      await old.execute(
        'CREATE TABLE memory ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, '
        'content TEXT NOT NULL, scope TEXT, source_kind TEXT NOT NULL)',
      );
      await old.execute(
        'CREATE TABLE study_step ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, plan_id INTEGER NOT NULL, '
        'seq INTEGER NOT NULL, title TEXT NOT NULL, '
        'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
      );
      const stamp = '2026-11-07 09:00:00';
      final goalId = await old.insert('learning_goal', {
        'title': '暂缓的目标',
        'status': 'deferred',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final planId = await old.insert('study_plan', {
        'title': '旧计划',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final itemId = await old.insert('plan_item', {
        'goal_id': goalId,
        'study_plan_id': planId,
        'title': '暂缓的事项',
        'status': 'moved',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await old.insert('schedule_block', {
        'plan_item_id': itemId,
        'start_at': '2026-11-08 09:00:00',
        'end_at': '2026-11-08 10:00:00',
        'status': 'moved',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final questionId = await old.insert('question', {
        'stem': '从照片识别的题目',
        'origin': 'ocr',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await old.insert('attempt', {
        'question_id': questionId,
        'created_at': stamp,
        'updated_at': stamp,
      });
      await old.insert('memory', {
        'kind': 'difficulty',
        'content': '旧的场次困难',
        'source_kind': 'session',
      });
      await old.insert('study_step', {
        'plan_id': planId,
        'seq': 1,
        'title': '旧的步骤',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await old.insert('app_meta', {
        'key': 'schema_version',
        'value': '16',
        'updated_at': stamp,
      });
    } finally {
      legacy.close();
    }

    final rebuilt = await openZhixinDatabase(path: path);
    addTearDown(rebuilt.close);

    final version = await rebuilt.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, zhixinSchemaVersion);
    final meta = await rebuilt.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(meta.first['value'], '$zhixinSchemaVersion');
    expect(await rebuilt.query('profile'), hasLength(1));

    // 旧库的数据不迁移：题目、作答、事项、时间块、记忆与旧步骤都随重建丢弃。
    for (final table in [
      'learning_goal',
      'conversation',
      'study_plan',
      'plan_item',
      'schedule_block',
      'attempt',
      'memory',
    ]) {
      expect(await rebuilt.query(table), isEmpty, reason: '$table 的旧数据应当随重建丢弃');
    }
    final legacyStep = await rebuilt.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'study_step'",
    );
    expect(legacyStep, isEmpty);
    final legacyQuestion = await rebuilt.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'question'",
    );
    expect(legacyQuestion, isEmpty);

    // 重建后的结构是当前版本：作答直接指向学习记录。
    final attemptColumns = {
      for (final row in await rebuilt.rawQuery('PRAGMA table_info(attempt)'))
        row['name']! as String,
    };
    expect(attemptColumns, contains('conversation_id'));
    expect(attemptColumns, isNot(contains('question_id')));
    expect(await rebuilt.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}
