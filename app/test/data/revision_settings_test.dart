import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/db/raw_executor.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('每日截止小时更新形成提交，撤销后恢复原值', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final before = (await rig.raw.query('profile')).single;
    final hourBefore = before['day_cutoff_hour'];
    final updatedBefore = before['updated_at'];

    await rig.db.command((txn) async {
      await txn.update('profile', {
        'day_cutoff_hour': 6,
        'updated_at': '2026-11-10T12:00:00',
      }, where: 'id = 1');
    }, label: changeCutoffHourAction);

    final commitId = await rig.engine.headId(rig.raw.rawDb);
    final history = await rig.revisions.history();
    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[commitId], isNull);

    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    final after = (await rig.raw.query('profile')).single;
    expect(after['day_cutoff_hour'], hourBefore);
    expect(after['updated_at'], updatedBefore);
  });

  test('截止小时被再次修改后不能撤销更早的一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    Future<int> setHour(int hour, String at) async {
      await rig.db.command((txn) async {
        await txn.update('profile', {
          'day_cutoff_hour': hour,
          'updated_at': at,
        }, where: 'id = 1');
      }, label: changeCutoffHourAction);
      return rig.engine.headId(rig.raw.rawDb);
    }

    final first = await setHour(6, '2026-11-10T12:00:00');
    await setHour(0, '2026-11-10T13:00:00');

    final undone = await rig.revisions.undoCommit(first);
    expect(undone.applied, isFalse);
    expect(undone.message, contains('同一项内容又被修改过'));
    expect((await rig.raw.query('profile')).single['day_cutoff_hour'], 0);
  });

  test('撤销成功后通知应用根重新读取设置，失败时不通知', () async {
    var refreshed = 0;
    final rig = await openTestRig(onUndoApplied: () async => refreshed++);
    addTearDown(rig.close);

    await rig.db.insert('memory', {
      'kind': 'preference',
      'content': '晚上学习',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final commitId = await rig.engine.headId(rig.raw.rawDb);

    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(refreshed, 1);

    final again = await rig.revisions.undoCommit(commitId);
    expect(again.applied, isFalse);
    expect(refreshed, 1);
  });
}
