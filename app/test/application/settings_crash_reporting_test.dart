import 'dart:io';

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
import 'package:zhixin/data/diagnostics/crash_log.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/platform/diagnostics_store.dart';

import '../support/test_db.dart';

/// 安全存储的替身：崩溃报告开关不经过它，这个用例只需要它能构造。
class _MemorySecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

DateTime _fixedNow() => DateTime(2026, 11, 10, 12);

/// 只挂库、时间口径与诊断开关的服务；恢复与清空入口在这里不会被调用。
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
    diagnostics: DiagnosticsStore(rig.filesDir),
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
  late bool previousReporting;

  setUp(() {
    previousReporting = CrashLog.reportEnabled;
  });

  tearDown(() {
    CrashLog.reportEnabled = previousReporting;
  });

  test('保存成功时开关与存储一致', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _settingsService(rig);

    await service.setCrashReporting(false);
    expect(CrashLog.reportEnabled, isFalse);
    expect(await DiagnosticsStore(rig.filesDir).read(fallback: true), isFalse);

    await service.setCrashReporting(true);
    expect(CrashLog.reportEnabled, isTrue);
    expect(await DiagnosticsStore(rig.filesDir).read(fallback: false), isTrue);
  });

  test('存储失败时开关回到原值，异常交给页面', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _settingsService(rig);
    await service.setCrashReporting(true);
    expect(CrashLog.reportEnabled, isTrue);

    // 把开关文件的位置占成目录，改名写入一定失败。
    final path = DiagnosticsStore(rig.filesDir).path;
    if (await File(path).exists()) await File(path).delete();
    await Directory(path).create(recursive: true);

    await expectLater(
      service.setCrashReporting(false),
      throwsA(isA<FileSystemException>()),
    );
    expect(CrashLog.reportEnabled, isTrue);
  });

  test('读开关时同步上报入口，文件读不出来时用默认值', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final service = _settingsService(rig);

    expect(await service.crashReporting(), isTrue);
    expect(CrashLog.reportEnabled, isTrue);

    await Directory(DiagnosticsStore(rig.filesDir).path)
        .create(recursive: true);
    CrashLog.reportEnabled = false;
    expect(await service.crashReporting(), isTrue);
    expect(CrashLog.reportEnabled, isTrue);
  });
}
