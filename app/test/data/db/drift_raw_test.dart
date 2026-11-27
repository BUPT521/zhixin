import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/drift/drift_raw.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

void main() {
  test('drift 执行器上可以安装版本引擎并形成提交', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);
    final engine = RevisionEngine(clock: () => DateTime(2026, 11, 14, 10));
    await engine.initialize(raw);

    expect(await engine.headId(raw), 0);

    final commitId = await raw.transaction((txn) async {
      await engine.beginCommand(txn);
      await insertRow(txn, 'learning_goal', {
        'id': 'goal-1',
        'title': '测试目标',
        'created_at': '2026-11-14 10:00:00',
        'updated_at': '2026-11-14 10:00:00',
      });
      final commit = await engine.finishCommand(txn, action: '新建目标');
      return commit!.id;
    });

    expect(commitId, greaterThan(0));
    expect(await engine.headId(raw), commitId);
    final goals = await selectRows(raw, 'learning_goal');
    expect(goals.single['title'], '测试目标');

    final changes = await engine.changesFor(raw, commitId);
    expect(changes.single.table, 'learning_goal');
    expect(changes.single.op, ChangeOp.insert);
  });

  test('drift 执行器的更新、删除与冲突策略可用', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);

    final id = await insertRow(raw, 'app_meta', {
      'key': 'schema_version',
      'value': '26',
      'updated_at': '2026-11-14 10:00:00',
    });
    expect(id, greaterThan(0));

    await updateRow(
      raw,
      'app_meta',
      {'value': '27'},
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    final rows = await selectRows(
      raw,
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(rows.single['value'], '27');

    await insertRow(raw, 'app_meta', {
      'key': 'schema_version',
      'value': '28',
      'updated_at': '2026-11-14 10:00:00',
    }, replace: true);
    expect((await selectRows(raw, 'app_meta')).single['value'], '28');

    await deleteRows(
      raw,
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(await selectRows(raw, 'app_meta'), isEmpty);
  });

  test('插入返回新行号，更新与删除返回受影响的行数', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);

    expect(
      await raw.execute(
        "INSERT INTO app_meta (key, value, updated_at) VALUES ('schema_version', "
        "'26', '2026-11-14 10:00:00')",
      ),
      greaterThan(0),
    );
    // 更新命中一行返回 1，一行都没命中返回 0，而不是上一条插入的行号。
    expect(
      await raw.execute(
        "UPDATE app_meta SET value = '27' WHERE key = 'schema_version'",
      ),
      1,
    );
    expect(
      await raw.execute("UPDATE app_meta SET value = '27' WHERE key = '没有这一行'"),
      0,
    );
    // 删除不存在的行返回 0；删到一行返回 1。
    expect(await raw.execute("DELETE FROM app_meta WHERE key = '没有这一行'"), 0);
    expect(
      await raw.execute("DELETE FROM app_meta WHERE key = 'schema_version'"),
      1,
    );
    // 建表这类语句没有行数概念，返回 0。
    expect(await raw.execute('CREATE TABLE raw_executor_extra (id TEXT)'), 0);
    expect(await raw.execute('DROP TABLE raw_executor_extra'), 0);
  });

  test('只读副本背后的 sqlite3 执行器使用同一套返回值语义', () async {
    final directory = await Directory.systemTemp.createTemp('zhixin_raw_exec');
    addTearDown(() => directory.delete(recursive: true));
    final database = SqliteRawDatabase(
      sqlite.sqlite3.open(p.join(directory.path, 'raw.db')),
    );
    addTearDown(database.close);

    expect(
      await database.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)',
      ),
      0,
    );
    expect(
      await database.execute("INSERT INTO t (value) VALUES ('a')"),
      greaterThan(0),
    );
    expect(await database.execute("UPDATE t SET value = 'b' WHERE id = 1"), 1);
    expect(await database.execute("UPDATE t SET value = 'b' WHERE id = 99"), 0);
    expect(await database.execute('DELETE FROM t WHERE id = 99'), 0);
    expect(await database.execute('DELETE FROM t WHERE id = 1'), 1);
    // 上一条删除返回 0 之后，DDL 不会把上一次更新或删除的行数带出来。
    expect(await database.execute('DROP TABLE t'), 0);
  });
}
