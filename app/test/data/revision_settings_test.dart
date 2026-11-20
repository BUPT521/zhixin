import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_config_store.dart';
import 'package:zhixin/application/service_runtime.dart';
import 'package:zhixin/application/settings_service.dart';
import 'package:zhixin/application/time_policy_controller.dart';
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/data_version_service.dart';
import 'package:zhixin/data/backup/restore_point_store.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

/// 安全存储的替身：设置服务只在保存模型配置时用到它，这个用例用不到。
class _MemorySecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// 固定时钟：截止小时与提交时间都落在这个时刻。
DateTime _fixedNow() => DateTime(2026, 11, 10, 12);

/// 只挂库与时间口径的设置服务；恢复与清空入口在这个用例里不会被调用。
SettingsService _settingsService(TestRig rig) {
  final settings = SettingsRepository(rig.db);
  final llmStore = LlmConfigStore(_MemorySecrets());
  return SettingsService(
    settings: settings,
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
    llmStore: llmStore,
    ai: AiChatService(store: llmStore),
    runtime: ServiceRuntime(
      policySource: () => TimePolicy(clock: _fixedNow),
      filesDirSource: () => rig.filesDir,
      live: rig.db.live,
    ),
    timePolicy: TimePolicyController(
      settings: settings,
      clock: _fixedNow,
      onChanged: () {},
    ),
    dataVersions: DataVersionService(
      gate: rig.db.gate,
      revisions: rig.revisions,
      revisionPackages: RevisionPackageService(
        engine: rig.engine,
        assets: rig.engine.assets,
        schemaVersion: zhixinSchemaVersion,
        appVersion: 'test',
      ),
      dataPackages: DataPackageService(
        filesDir: rig.filesDir,
        dbPath: p.join(rig.filesDir, zhixinDbFileName),
        appVersion: 'test',
        schemaVersion: zhixinSchemaVersion,
      ),
      restorePointStore: RestorePointStore(filesDir: rig.filesDir),
      engine: rig.engine,
      cache: AttachmentCache(filesDir: () => rig.filesDir),
      connection: () => rig.raw,
      database: () => rig.db,
      reopen: () async => rig.raw,
      resetStudyData: () async {},
      markPendingWorkInvalidated: () {},
      notifyDataChanged: () {},
      recordFailure: (error, stack, {required kind}) {},
    ),
  );
}

void main() {
  test('每日截止小时更新形成提交，撤销后恢复原值', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final before = (await selectRows(rig.raw, 'profile')).single;
    final hourBefore = before['day_cutoff_hour'];
    final updatedBefore = before['updated_at'];

    await rig.db.command((txn) async {
      await updateRow(txn, 'profile', {
        'day_cutoff_hour': 6,
        'updated_at': '2026-11-10T12:00:00',
      }, where: 'id = 1');
    }, label: changeCutoffHourAction);

    final commitId = await rig.engine.headId(rig.raw);
    final history = await rig.revisions.history();
    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[commitId], isNull);

    final startedAt = DateTime.now();
    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    final after = (await selectRows(rig.raw, 'profile')).single;
    expect(after['day_cutoff_hour'], hourBefore);
    // 维护列不写回旧值，写成撤销时刻：撤销之后这一行是“现在改过”的。
    expect(after['updated_at'], isNot(updatedBefore));
    expect(
      DateTime.parse(after['updated_at']! as String)
          .isBefore(startedAt.subtract(const Duration(seconds: 1))),
      isFalse,
    );
  });

  test('截止小时被再次修改后不能撤销更早的一次', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);

    Future<int> setHour(int hour, String at) async {
      await rig.db.command((txn) async {
        await updateRow(txn, 'profile', {
          'day_cutoff_hour': hour,
          'updated_at': at,
        }, where: 'id = 1');
      }, label: changeCutoffHourAction);
      return rig.engine.headId(rig.raw);
    }

    final first = await setHour(6, '2026-11-10T12:00:00');
    await setHour(0, '2026-11-10T13:00:00');

    final undone = await rig.revisions.undoCommit(first);
    expect(undone.applied, isFalse);
    expect(undone.message, contains('同一项内容又被修改过'));
    expect((await selectRows(rig.raw, 'profile')).single['day_cutoff_hour'], 0);
  });

  test('设置页读到的设置项随 profile 的提交更新，app_meta 写入不通知订阅', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _settingsService(rig);
    final values = <SettingsView>[];
    var subscription = service.watchSettings().listen(values.add);
    addTearDown(() => subscription.cancel());
    await _settle();
    expect(values, hasLength(1), reason: '订阅之后先读一次');
    expect(values.single.cutoffHour, 4);
    expect(values.single.useSystemCamera, isFalse);

    // 截止小时写成一条提交，提交收尾通知 profile，设置页随之重读。
    await service.saveCutoffHour(6);
    await _settle();
    expect(values, hasLength(2));
    expect(values.last.cutoffHour, 6);

    // 拍照方式写在 app_meta 里，不形成提交、也没有表通知。
    await service.setUseSystemCamera(true);
    await _settle();
    expect(values, hasLength(2), reason: 'app_meta 的写入不通知订阅');

    // 页面在保存之后换一条新流，读到刚写进去的值。
    await subscription.cancel();
    subscription = service.watchSettings().listen(values.add);
    await _settle();
    expect(values.last.useSystemCamera, isTrue);
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
