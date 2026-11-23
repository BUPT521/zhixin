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

/// 读 app_meta 里的一行；没有写过的键返回空。
Future<String?> _meta(TestRig rig, String key) async {
  final rows = await selectRows(
    rig.raw,
    'app_meta',
    where: 'key = ?',
    whereArgs: [key],
  );
  return rows.isEmpty ? null : rows.first['value'] as String?;
}

void main() {
  test('每日截止小时写进 app_meta 的 day_cutoff_hour，再改一次覆盖同一行', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    // 新库没有这一行，读设置时回退到默认的 4 点。
    expect(await _meta(rig, 'day_cutoff_hour'), isNull);
    final service = _settingsService(rig);
    expect(await service.cutoffHour(), 4);

    await rig.db.command((txn) async {
      await SettingsRepository(rig.db).setCutoffHour(6, _fixedNow());
    }, label: '修改每日截止小时');
    expect(await _meta(rig, 'day_cutoff_hour'), '6');
    expect(await service.cutoffHour(), 6);

    await rig.db.command((txn) async {
      await SettingsRepository(rig.db).setCutoffHour(0, _fixedNow());
    }, label: '修改每日截止小时');
    // app_meta 里只有一行，第二次写入按主键覆盖。
    final rows = await selectRows(
      rig.raw,
      'app_meta',
      where: 'key = ?',
      whereArgs: ['day_cutoff_hour'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['value'], '0');
    // 默认值与已写入的值都不影响 schema_version 那一行。
    expect(await _meta(rig, 'schema_version'), '$zhixinSchemaVersion');
  });

  test('app_meta 的写入不形成提交也不通知订阅，设置页在保存之后重读', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _settingsService(rig);
    final values = <SettingsView>[];
    final subscription = service.watchSettings().listen(values.add);
    addTearDown(subscription.cancel);
    await _settle();
    expect(values, hasLength(1), reason: '订阅之后先读一次');
    expect(values.single.cutoffHour, 4);
    expect(values.single.useSystemCamera, isFalse);

    // 截止小时写在 app_meta 里，设置页订阅的就是这一张表。app_meta 不参与版本
    // 采集，写入不形成提交、也不发表通知，订阅因此不重读；设置页拿到新值靠
    // 保存路径在保存之后换一条新流重读。
    await service.saveCutoffHour(6);
    await _settle();
    expect(values, hasLength(1), reason: 'app_meta 的写入不通知订阅');
    expect(await _meta(rig, 'day_cutoff_hour'), '6');
    expect(
      await selectRows(rig.raw, 'revision_commit'),
      hasLength(1),
      reason: '只有基线提交',
    );

    final reread = await service.watchSettings().first;
    expect(reread.cutoffHour, 6);
    expect(reread.useSystemCamera, isFalse);

    // 拍照方式同样写在 app_meta 里，也不经过表通知。
    await service.setUseSystemCamera(true);
    await _settle();
    expect(values, hasLength(1));
    expect((await service.watchSettings().first).useSystemCamera, isTrue);
    expect(await _meta(rig, SettingsService.systemCameraKey), '1');
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
