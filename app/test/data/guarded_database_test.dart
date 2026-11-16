import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';

import '../support/test_db.dart';

void main() {
  test('提交落库之后回调改到的表，空提交不回调', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final batches = <Set<String>>[];
    rig.db.onCommitted = batches.add;

    await insertRow(rig.db, 'learning_goal', {
      'id': 'goal-committed',
      'title': '复习线代',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    expect(batches, hasLength(1));
    expect(batches.single, contains('learning_goal'));

    // 没有净变化的命令不形成提交，也不回调。
    await rig.db.command((txn) async {}, label: '空写入');
    expect(batches, hasLength(1));
  });
}
