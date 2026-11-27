import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/schema.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

void main() {
  test('新库是 v33，12 张业务表与版本元数据就位', () async {
    final db = await openTestDb();
    addTearDown(db.close);

    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, zhixinSchemaVersion);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final names = {for (final row in tables) row['name']! as String};
    expect(names, containsAll(schemaTableNames()));
    // 暂存表不进业务表计数，也不参与版本采集；旧版关键词索引表已删除。
    final businessNames = names.where((name) => !name.startsWith('rev_stage_'));
    expect(businessNames.length, schemaTableNames().length);
    expect(
      names.where((name) => name.endsWith('_fts')),
      isEmpty,
      reason: '关键词检索并入索引之后业务库不再有 FTS5 表（ADR-0024）',
    );
    expect(
      versionedTableNames,
      hasLength(12),
      reason: '采集表 12 张：记忆使用统计 memory_usage 参与采集，local_memory_use 是本机缓冲',
    );
    expect(schemaTableNames(), hasLength(26), reason: 'schema 33 共 26 张表');
    final classified = {
      ...versionedTableNames,
      ...revisionMetadataTables,
      ...nonVersionedPersistentTables,
    };
    for (final table in businessNames) {
      expect(classified, contains(table), reason: '表 $table 没有登记版本分类');
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
    // 这一版删掉的三张表：个人资料并进 app_meta，单行状态与 HEAD 合进
    // revision_state（ADR-0054 决定第 4 条）。
    expect(names, isNot(contains('profile')));
    expect(names, isNot(contains('revision_context')));
    expect(names, isNot(contains('revision_sequence')));
    expect(
      names,
      containsAll([
        'revision_state',
        'revision_ref_tombstone',
        'memory_usage',
        'local_memory_use',
      ]),
    );
    expect(names, isNot(contains('memory_use')), reason: '使用记录改为本机缓冲表');

    // 每日截止小时并进 app_meta，键名 day_cutoff_hour；新库还没有写过，读取时
    // 由 SettingsRepository 回退到默认值。
    expect(await selectRows(db, 'app_meta'), hasLength(1));
    expect(
      await selectRows(
        db,
        'app_meta',
        where: 'key = ?',
        whereArgs: ['day_cutoff_hour'],
      ),
      isEmpty,
    );

    final meta = await selectRows(
      db,
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
      ]),
    );
    // 讨论是否结束由 ended_at 推出，status 恒等于 ended_at IS NOT NULL（审查 S20）。
    expect(await columns('conversation'), isNot(contains('status')));
    expect(await columns('conversation'), contains('ended_at'));
    // 最后消息时间不再存列：会话列表按消息表现数。
    expect(await columns('conversation'), isNot(contains('last_message_at')));
    expect(await columns('study_session'), contains('conversation_id'));
    expect(await columns('attempt'), contains('redo_of_attempt_id'));
    expect(await columns('attempt'), contains('solution'));
    expect(
      await columns('material_page'),
      containsAll(['material_id', 'page_no', 'content']),
    );
    // 计划当前页由 plan_item 算出，不再写在计划行里。
    expect(await columns('study_plan'), containsAll(['material_id', 'status']));
    expect(await columns('study_plan'), isNot(contains('current_page')));
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
    // 完整性只认整库摘要一个原语：提交没有哈希链与现存的条数列，冲突条数与
    // 变更条数读取时现数（ADR-0054 与审查 S1）。
    expect(
      await columns('revision_commit'),
      containsAll([
        'uid',
        'state_digest',
        'server_seq',
        'origin_device',
        'authored_at',
      ]),
    );
    expect(
      await columns('revision_commit'),
      isNot(
        contains(
          anyOf([
            'hash',
            'parent_hash',
            'conflict_count',
            'change_count',
            'request_id',
          ]),
        ),
      ),
    );
    expect(
      await columns('revision_state'),
      containsAll([
        'active_commit',
        'capturing',
        'suppress',
        'next_commit',
        'head_commit_id',
        'table_digests_json',
      ]),
    );
    expect(
      await columns('revision_ref'),
      containsAll(['name', 'commit_uid', 'sync_state', 'note']),
    );
    expect(
      await columns('revision_ref'),
      isNot(contains(anyOf(['commit_id', 'head_name']))),
    );
    expect(
      await columns('revision_ref_tombstone'),
      containsAll(['name', 'deleted_at']),
    );
    expect(await columns('revision_checkpoint'), contains('state_digest'));
    expect(
      await columns('revision_checkpoint'),
      isNot(contains(anyOf(['asset_hashes_json', 'checksum', 'encoding']))),
    );
    expect(await columns('revision_cursor'), isNot(contains('scope')));
    expect(
      await columns('memory'),
      containsAll(['kind', 'status', 'search_terms', 'reviewed_at']),
    );
    expect(
      await columns('memory_usage'),
      containsAll([
        'id',
        'memory_id',
        'device_id',
        'recall_count',
        'search_count',
        'last_recalled_at',
        'last_searched_at',
        'updated_at',
      ]),
    );
    // 冲刷与应用在同一事务里完成，不再需要记录“已经数到哪一刻”的水位（审查 S16）。
    expect(await columns('memory_usage'), isNot(contains('first_seen_at')));
    expect(
      await columns('local_memory_use'),
      containsAll(['id', 'memory_id', 'kind', 'used_at']),
    );
    expect(
      await columns('local_memory_use'),
      isNot(contains(anyOf(['device_id', 'acquired_at']))),
    );
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
    expect(await columns('message'), isNot(contains('answer_version')));
    // 图片列存的是附件哈希，列名跟着改成 image_hashes_json（审查 S17）。
    expect(await columns('message'), contains('image_hashes_json'));
    expect(await columns('message'), isNot(contains('image_paths_json')));
    // 提交编号由 next_commit 预留、两处插入都显式给出，不再用 AUTOINCREMENT
    // 另维护一份 sqlite_sequence（审查 S22）。
    final commitSql =
        (await selectRows(
              db,
              'sqlite_master',
              where: "type = 'table' AND name = 'revision_commit'",
            )).first['sql']!
            as String;
    expect(commitSql.toUpperCase(), isNot(contains('AUTOINCREMENT')));
    expect(await columns('assessment'), isNot(contains('source_json')));
    expect(await columns('memory'), isNot(contains('valid_from')));
    final assessmentSql =
        (await selectRows(
              db,
              'sqlite_master',
              where: "type = 'table' AND name = 'assessment'",
            )).first['sql']!
            as String;
    expect(assessmentSql, isNot(contains("'self'")));
    await expectLater(
      insertRow(db, 'attempt', {
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
      await insertRow(old, 'knowledge_node', {'name': '极限'});
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
      await insertRow(old, 'conversation', {
        'title': '旧讨论',
        'created_at': '2026-11-06 09:00:00',
        'updated_at': '2026-11-06 09:00:00',
      });
    } finally {
      legacy.close();
    }

    final rebuilt = await openZhixinDatabase(path: path);
    addTearDown(rebuilt.close);

    expect(await selectRows(rebuilt, 'conversation'), isEmpty);
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
      final goalId = await insertRow(old, 'learning_goal', {
        'title': '暂缓的目标',
        'status': 'deferred',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final planId = await insertRow(old, 'study_plan', {
        'title': '旧计划',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final itemId = await insertRow(old, 'plan_item', {
        'goal_id': goalId,
        'study_plan_id': planId,
        'title': '暂缓的事项',
        'status': 'moved',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await insertRow(old, 'schedule_block', {
        'plan_item_id': itemId,
        'start_at': '2026-11-08 09:00:00',
        'end_at': '2026-11-08 10:00:00',
        'status': 'moved',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final questionId = await insertRow(old, 'question', {
        'stem': '从照片识别的题目',
        'origin': 'ocr',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await insertRow(old, 'attempt', {
        'question_id': questionId,
        'created_at': stamp,
        'updated_at': stamp,
      });
      await insertRow(old, 'memory', {
        'kind': 'episodic',
        'content': '旧的场次困难',
        'source_kind': 'session',
      });
      await insertRow(old, 'study_step', {
        'plan_id': planId,
        'seq': 1,
        'title': '旧的步骤',
        'created_at': stamp,
        'updated_at': stamp,
      });
      await insertRow(old, 'app_meta', {
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
    final meta = await selectRows(
      rebuilt,
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(meta.first['value'], '$zhixinSchemaVersion');
    // 个人资料表已删除，截止小时并进 app_meta，重建之后同样没有这一行。
    expect(await selectRows(rebuilt, 'app_meta'), hasLength(1));

    // 旧库的数据不迁移：题目、作答、事项、时间块、记忆与旧步骤都随重建丢弃。
    for (final table in [
      'learning_goal',
      'conversation',
      'study_plan',
      'plan_item',
      'attempt',
      'memory',
    ]) {
      expect(
        await selectRows(rebuilt, table),
        isEmpty,
        reason: '$table 的旧数据应当随重建丢弃',
      );
    }
    expect(
      await rebuilt.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name IN ('schedule_block', 'timetable_entry')",
      ),
      isEmpty,
    );
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

  test('打开旧库时删除关键词索引留下的派生表与触发器', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    // 关键词检索并入索引之前的派生对象；新库不再创建，打开时清理。
    await db.execute('CREATE TABLE material_page_fts (idx TEXT)');
    await db.execute(
      'CREATE TRIGGER fts_message_fts_ai AFTER INSERT ON message '
      'BEGIN SELECT 1; END',
    );

    await RevisionEngine().initialize(db);

    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name = 'material_page_fts' "
      "OR name = 'fts_message_fts_ai'",
    );
    expect(rows, isEmpty);
    expect(await db.rawQuery('PRAGMA integrity_check'), isNotEmpty);
  });

  test('每个外键列都有前导索引，索引不与主键或唯一约束重复', () async {
    final db = await openTestDb();
    addTearDown(db.close);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'rev_stage_%'",
    );
    for (final row in tables) {
      final table = row['name']! as String;
      final info = await db.rawQuery('PRAGMA table_info("$table")');
      final primary = [
        for (final column in info)
          if ((column['pk'] as int? ?? 0) > 0) column['name']! as String,
      ];
      final explicit = <String, List<String>>{};
      final declared = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = ? AND sql IS NOT NULL",
        [table],
      );
      for (final index in declared) {
        final name = index['name']! as String;
        explicit[name] = [
          for (final column in await db.rawQuery('PRAGMA index_info("$name")'))
            column['name']! as String,
        ];
      }
      final uniqueConstraints = <List<String>>[];
      for (final index in await db.rawQuery('PRAGMA index_list("$table")')) {
        if (index['origin'] != 'u') continue;
        final name = index['name']! as String;
        uniqueConstraints.add([
          for (final column in await db.rawQuery('PRAGMA index_info("$name")'))
            column['name']! as String,
        ]);
      }
      final leading = <String>{
        if (primary.isNotEmpty) primary.first,
        for (final columns in explicit.values) columns.first,
        for (final columns in uniqueConstraints) columns.first,
      };
      final foreignKeys = await db.rawQuery(
        'PRAGMA foreign_key_list("$table")',
      );
      for (final foreignKey in foreignKeys) {
        final column = foreignKey['from']! as String;
        expect(
          leading,
          contains(column),
          reason: '$table.$column 是外键，但没有以它开头的索引',
        );
      }
      for (final entry in explicit.entries) {
        final columns = entry.value;
        expect(
          columns == primary,
          isFalse,
          reason: '索引 ${entry.key} 与 $table 的主键列完全相同',
        );
        for (final unique in uniqueConstraints) {
          expect(
            columns == unique,
            isFalse,
            reason: '索引 ${entry.key} 与 $table 的唯一约束列完全相同',
          );
        }
      }
    }
  });
}
