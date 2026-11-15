import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/db/raw_executor.dart';

import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

class _FailingCache extends AttachmentCache {
  _FailingCache(String filesDir) : super(filesDir: () => filesDir);

  @override
  Future<void> rebuild(RawExecutor executor, AssetStore assets) async {
    throw StateError('模拟图片缓存写入失败');
  }
}

void main() {
  test('恢复期间排队的生成查询读取替换后的连接', () async {
    final original = await openTestDb();
    final replacement = await openTestDb();
    addTearDown(replacement.close);
    await updateRow(replacement, 'profile', {'day_cutoff_hour': 6});

    final gate = DatabaseGate();
    var active = original;
    final repository = SettingsRepository(
      GuardedDatabase(gate: gate, resolve: () => active),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final swap = gate.exclusive(() async {
      entered.complete();
      await release.future;
      await original.close();
      active = replacement;
    });
    await entered.future;
    final read = repository.cutoffHour();
    release.complete();

    await swap;
    expect(await read, 6);
  });

  test('版本已经恢复后，图片缓存失败不把恢复报成失败', () async {
    var dataChanges = 0;
    final cacheDir = await Directory.systemTemp.createTemp('zhixin_cache_');
    addTearDown(() => cacheDir.delete(recursive: true));
    final cache = _FailingCache(cacheDir.path);
    final rig = await openTestRig(
      cache: cache,
      onDataChanged: () async => dataChanges++,
    );
    addTearDown(rig.close);

    final goal = await insertRow(rig.db, 'learning_goal', {
      'title': '恢复前',
      'status': 'active',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
    final target = await rig.engine.headId(rig.raw.rawDb);
    await updateRow(
      rig.db,
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
    expect(cache.pendingRebuild, isTrue);
    // 数据事务已经提交，代次推进仍然执行；界面不能提示“当前数据没有改动”。
    expect(dataChanges, 1);
    expect(
      (await selectRows(
        rig.raw,
        'learning_goal',
        where: 'id = ?',
        whereArgs: [goal],
      )).single['title'],
      '恢复前',
    );
  });
}
