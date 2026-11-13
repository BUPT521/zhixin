import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/db/raw_executor.dart';

import '../support/test_db.dart';

class _FailingCache extends AttachmentCache {
  _FailingCache() : super(filesDir: () => '.');

  @override
  Future<void> rebuild(RawExecutor executor, AssetStore assets) async {
    throw StateError('模拟图片缓存写入失败');
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('版本已经恢复后，图片缓存失败不把恢复报成失败', () async {
    var dataChanges = 0;
    final rig = await openTestRig(
      cache: _FailingCache(),
      onDataChanged: () async => dataChanges++,
    );
    addTearDown(rig.close);

    final goal = await rig.db.insert('learning_goal', {
      'title': '恢复前',
      'status': 'active',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
    final target = await rig.engine.headId(rig.raw.rawDb);
    await rig.db.update(
      'learning_goal',
      {'title': '恢复后'},
      where: 'id = ?',
      whereArgs: [goal],
    );

    final result = await rig.revisions.restore(
      target,
      expectedHead: await rig.engine.headId(rig.raw.rawDb),
    );

    expect(result.commit.action, contains('恢复'));
    expect(result.cacheWarning, isNotNull);
    // 数据事务已经提交，代次推进仍然执行；界面不能提示“当前数据没有改动”。
    expect(dataChanges, 1);
    expect(
      (await rig.raw.query(
        'learning_goal',
        where: 'id = ?',
        whereArgs: [goal],
      )).single['title'],
      '恢复前',
    );
  });
}
