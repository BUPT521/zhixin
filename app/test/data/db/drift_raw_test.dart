import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/drift/drift_raw.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

void main() {
  test('drift 执行器上可以安装版本引擎并形成提交', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);
    final engine = RevisionEngine(clock: () => DateTime(2026, 11, 14, 10));
    await engine.initialize(raw);

    expect(await engine.headId(raw), 0);

    final commitId = await raw.transaction((txn) async {
      final id = await engine.beginCommand(txn);
      await txn.insert('learning_goal', {
        'title': '测试目标',
        'created_at': '2026-11-14 10:00:00',
        'updated_at': '2026-11-14 10:00:00',
      });
      await engine.finishCommand(txn, id, action: '新建目标');
      return id;
    });

    expect(commitId, greaterThan(0));
    expect(await engine.headId(raw), commitId);
    final goals = await raw.query('learning_goal');
    expect(goals.single['title'], '测试目标');

    final changes = await engine.changesFor(raw, commitId);
    expect(changes.single.table, 'learning_goal');
    expect(changes.single.op, 'insert');
  });

  test('drift 执行器的更新、删除与冲突策略可用', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);

    final id = await raw.insert('app_meta', {
      'key': 'schema_version',
      'value': '26',
      'updated_at': '2026-11-14 10:00:00',
    });
    expect(id, greaterThan(0));

    await raw.update(
      'app_meta',
      {'value': '27'},
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    final rows = await raw.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['schema_version'],
    );
    expect(rows.single['value'], '27');

    await raw.insert('app_meta', {
      'key': 'schema_version',
      'value': '28',
      'updated_at': '2026-11-14 10:00:00',
    }, conflictAlgorithm: ConflictAction.replace);
    expect((await raw.query('app_meta')).single['value'], '28');

    expect(
      await raw.delete(
        'app_meta',
        where: 'key = ?',
        whereArgs: ['schema_version'],
      ),
      1,
    );
    expect(await raw.query('app_meta'), isEmpty);
  });
}
