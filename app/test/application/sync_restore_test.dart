// 数据版本对照 git 的改进方案（G5）的验收用例。
//
// 整库恢复旧备份会把库里的同步位置一起带回备份那一刻，账号偏好却仍然有效；
// 下一次同步从旧位置拉取，本设备在备份之后推送的提交又被当成远端提交重新
// 应用，恢复的效果被同步撤回。用例在文件库上走真实的恢复流程（替换库文件），
// 阶段 1 的 3.4 短期修复落地之前应当失败。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/data_version_service.dart';
import 'package:zhixin/data/backup/restore_point_store.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/domain/rules/schema_version.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/domain/models/result.dart';

import '../support/fake_server.dart';
import '../support/restore_helpers.dart';
import '../support/sync_rig.dart';
import '../support/test_db.dart';

void main() {
  test('开着同步恢复一份旧备份后再同步一次，本机保持恢复后的内容，另一台设备得到同样内容'
      '（G5）', () async {
    final server = FakeServer();
    final clock = TestClock();
    final home = await Directory.systemTemp.createTemp('zhixin_sync_restore');
    final filesDir = p.join(home.path, 'files');
    await Directory(filesDir).create(recursive: true);
    final dbPath = p.join(home.path, zhixinDbFileName);

    var raw = await openZhixinDatabase(path: dbPath, clock: clock.call);
    final engine = RevisionEngine(clock: clock.call);
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final revisions = RevisionService(
      db: db,
      raw: () => raw,
      engine: engine,
      clock: clock.call,
      cache: AttachmentCache(filesDir: () => filesDir),
    );

    // 与生产一致：换库之后重新打开连接，并按全部表补发一次重读通知。
    Future<RawDatabase> reopen() async {
      raw = await openZhixinDatabase(path: dbPath, clock: clock.call);
      db.connectionReplaced();
      return raw;
    }

    final device = await openSyncDevice(
      server,
      rig: TestRig(
        raw: raw,
        db: db,
        engine: engine,
        revisions: revisions,
        filesDir: filesDir,
      ),
      email: 'a@example.com',
      register: true,
      deviceId: 'device-a',
      clock: clock,
      home: Directory(filesDir),
    );
    final dataVersions = DataVersionService(
      gate: db.gate,
      revisions: revisions,
      revisionPackages: RevisionPackageService(
        engine: engine,
        assets: engine.assets,
        schemaVersion: zhixinSchemaVersion,
        appVersion: 'test',
        clock: clock.call,
      ),
      dataPackages: DataPackageService(
        filesDir: filesDir,
        dbPath: dbPath,
        appVersion: 'test',
        schemaVersion: zhixinSchemaVersion,
        clock: clock.call,
      ),
      restorePointStore: RestorePointStore(
        filesDir: filesDir,
        clock: clock.call,
      ),
      engine: engine,
      cache: AttachmentCache(filesDir: () => filesDir),
      connection: () => raw,
      database: () => db,
      reopen: reopen,
      resetStudyData: () async {},
      markPendingWorkInvalidated: () {},
      notifyDataChanged: () {},
      recordFailure: (error, stack, {required kind}) {},
    );

    addTearDown(() async {
      device.sync.dispose();
      device.account.dispose();
      await raw.close();
      if (await home.exists()) await home.delete(recursive: true);
    });

    Future<void> addMemory(String id, String content) =>
        db.command((txn) async {
          await insertRow(txn, 'memory', {
            'id': id,
            'kind': 'semantic',
            'content': content,
            'scope': null,
            'source_kind': 'user',
            'source_id': null,
            'valid_until': null,
            'status': 'active',
            'created_at': '2026-11-17 10:00:00',
            'updated_at': '2026-11-17 10:00:00',
          });
        }, label: '新增记忆');

    Future<List<Object?>> memoryIds() async => [
      for (final row in await raw.rawQuery('SELECT id FROM memory ORDER BY id'))
        row['id'],
    ];

    // 全新库：首次同步把库里的初始设置作为基线上传，同步状态就此建立。
    await device.sync.syncNow(confirmBaseline: true);
    await addMemory('m1', '喜欢先看例子');
    await device.sync.syncNow();
    final userId = (await device.account.snapshot()).session!.userId;
    final headAfterFirstPush = server.headOf(userId);
    expect(
      server.commits[userId]!.last['action'],
      '新增记忆',
      reason: '准备阶段：一条记忆推上去之后服务端最后一条是这次写入',
    );

    // 备份一份“只有 m1”的旧数据：备份里也有当时的同步位置。
    final backupPath = p.join(home.path, 'backup.zip');
    await dataVersions.backupRepository(backupPath);
    final backup = await File(backupPath).readAsBytes();

    // 备份之后又同步了一条记忆：服务端与库里的同步位置都前进了一条。
    await addMemory('m2', '备份之后才有的记忆');
    await device.sync.syncNow();
    expect(
      server.headOf(userId),
      headAfterFirstPush + 1,
      reason: '准备阶段：备份之后的写入也推到了服务端',
    );
    expect(await memoryIds(), ['m1', 'm2'], reason: '准备阶段：备份之后本机有两条记忆');

    // 整库恢复旧备份：本机数据与同步位置一起回到备份那一刻，比服务端落后一步。
    final restored = await restoreFromBytes(dataVersions, backup);
    expect(
      restored,
      isA<Success<String?>>(),
      reason: '准备阶段：版本库备份应当能恢复：${restored.failureOrNull?.message}',
    );
    expect(await memoryIds(), ['m1'], reason: '准备阶段：恢复之后本机只有备份里的 m1');

    // 开着同步再同步一次：不能从旧位置把恢复之前的 m2 拉回来。
    await syncAfterRestore(device.sync);
    final afterSync = await memoryIds();
    expect(
      afterSync,
      ['m1'],
      reason:
          '恢复之后同步又把备份之后的改动拉了回来：本机现在是 $afterSync，'
          '期望只有 m1（服务端序列 ${server.headOf(userId)} 条，'
          '库里同步位置 ${await syncPositions(raw)}）',
    );

    // 另一台设备同步之后应当拿到同样的内容。
    final bRig = await openTestRig(clock: clock.call);
    final b = await openSyncDevice(
      server,
      rig: bRig,
      email: 'a@example.com',
      register: false,
      deviceId: 'device-b',
      clock: clock,
    );
    addTearDown(b.close);
    await b.sync.syncNow();
    final onB = [for (final row in await testMemories(b.rig)) row['id']];
    expect(
      onB,
      ['m1'],
      reason:
          '另一台设备同步之后应当只有恢复后的 m1：实际 $onB（本机 ${await memoryIds()}，'
          '服务端序列 ${server.headOf(userId)} 条）',
    );
  });
}

/// 恢复之后的第一轮同步：可能要用户确认“云端会改成恢复后的内容”。
///
/// 3.4 的短期修复要求先向用户说明，再只上传差异；这一条确认与首次基线的确认
/// 是同一件事，用例按现有的 `BaselineConfirmationRequired` 处理，不要确认时
/// 直接一次同步就够。
Future<void> syncAfterRestore(SyncService sync) async {
  try {
    await sync.syncNow();
  } on BaselineConfirmationRequired {
    await sync.syncNow(confirmBaseline: true);
  }
}

/// 库里两个同步位置的一行说明；失败信息里用它说清“从哪个位置拉取”。
Future<String> syncPositions(RawDatabase raw) async {
  final rows = await raw.rawQuery(
    'SELECT name, position, blocking FROM revision_cursor ORDER BY name',
  );
  return rows.isEmpty
      ? '（没有同步位置）'
      : rows
            .map(
              (row) =>
                  '${row['name']}=${row['position']}'
                  '(blocking=${row['blocking']})',
            )
            .join('，');
}
