// 数据版本对照 git 的改进方案 3.1（G1，提交身份拆开）的两条验收用例。
//
// 3.1 的四条验收里，“同参数‘暂停 → 恢复 → 暂停’之后目标处于暂停状态”与
// “撤销后重做同一动作、另一台设备拉取后能看到重做”已经在
// `app/test/application/sync_rebase_test.dart` 覆盖；这里补其余两条：
//
// ① 两台设备离线各加一条同内容记忆，同步后两边行集合一致。G1③ 的成因是
//    拉取按 `request_id` 判断远端提交是否已经应用、推送靠服务端对 `request_id`
//    的永久去重：两台设备用同样的参数各做一次新增时编号相同，一条被当成重复
//    跳过，两边各留一份不同的行。改用提交身份（uid）之后两条提交身份不同，
//    两条记忆都应该在两边与服务端序列里。
// ② 恢复旧备份后的新提交能推到服务端。G1② 的成因是整库恢复让提交编号回到
//    备份那一刻，旧实现按“设备编号前缀 + 提交编号”生成的回退编号会撞上恢复
//    之前已经推上去的编号，被服务端当成重复丢掉。用例在文件库上走真实的
//    整库恢复（替换库文件），恢复之后再写一条新记忆，核对它进了服务端序列、
//    另一台设备拉得到。
//     `sync_restore_test.dart` 只覆盖到“恢复之后同步一次，本机保持恢复后的
//    内容、另一台设备看到同样的内容”（恢复这一步本身推上去了），没有覆盖
//    “恢复之后新写下的提交能不能推上去”。
//
// 用例只依赖对外行为：两台设备各自的业务行、服务端序列与同步结果，不碰内部
// 实现。

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
import '../support/sync_rig.dart';
import '../support/test_db.dart';

void main() {
  late FakeServer server;
  late TestClock clock;
  final devices = <SyncDevice>[];

  setUp(() {
    server = FakeServer();
    clock = TestClock();
    devices.clear();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
  });

  Future<SyncDevice> openDevice(
    String email, {
    bool register = false,
    required String deviceId,
    TestRig? rig,
  }) async {
    final opened = await openSyncDevice(
      server,
      rig: rig ?? await openTestRig(clock: clock.call),
      email: email,
      register: register,
      deviceId: deviceId,
      clock: clock,
    );
    devices.add(opened);
    return opened;
  }

  /// 一台设备上全部记忆的“主键 | 正文”，按主键排序；比较两边行集合时用它。
  List<String> describeMemories(List<Map<String, Object?>> rows) => [
    for (final row in rows) '${row['id']}|${row['content']}',
  ];

  /// 按列写一条记忆；`MemoryService.add` 写的类别值与库里的三分类对不上。
  ///
  /// [uid] 是这个动作的提交身份：界面在动作开始时另起一个 UUIDv7，两台设备各写
  /// 各的，所以这里也由用例显式给出（ADR-0053 决定第 3 条）。
  Future<int> addMemory(
    TestRig rig, {
    required String id,
    required String content,
    required String uid,
  }) async {
    await rig.db.command(
      (txn) async {
        await insertRow(txn, 'memory', {
          'id': id,
          'kind': 'semantic',
          'content': content,
          'source_kind': 'user',
          'status': 'active',
          'created_at': clock(),
          'updated_at': clock(),
        });
      },
      label: '新增记忆',
      uid: uid,
    );
    return rig.engine.headId(rig.raw);
  }

  test('两台设备离线各加一条同内容记忆，同步后两边行集合一致、服务端两条都在（3.1）', () async {
    // 两台设备先同步到同一份数据，各自建立同步位置：之后的离线新增才是普通
    // 本机提交，而不是首次同步的基线。
    final a = await openDevice(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    final startedCommit = await addMemory(
      a.rig,
      id: 'memory-start',
      content: '共同起点',
      uid: 'uid-start',
    );
    expect(startedCommit, isPositive, reason: '准备阶段：A 新增共同起点的记忆应当形成提交');
    await a.sync.syncNow(confirmBaseline: true);

    final b = await openDevice('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;
    expect(
      server.headOf(userId),
      greaterThan(0),
      reason: '准备阶段：A 首次同步应当把数据推上去',
    );

    // 两台设备各自离线新增：动作与参数完全相同、内容也相同；身份在各自动作
    // 开始时生成，所以两条提交的 uid 不同，两台设备各生成自己的行主键。
    clock.advance(const Duration(minutes: 1));
    final commitAId = await addMemory(
      a.rig,
      id: 'memory-a',
      content: '同一条内容',
      uid: 'uid-offline-a',
    );
    final commitBId = await addMemory(
      b.rig,
      id: 'memory-b',
      content: '同一条内容',
      uid: 'uid-offline-b',
    );
    final commitA = (await a.rig.engine.commitById(a.rig.raw, commitAId))!;
    final commitB = (await b.rig.engine.commitById(b.rig.raw, commitBId))!;
    expect(
      commitA.uid,
      isNot(commitB.uid),
      reason:
          '准备阶段：两台设备这次新增的参数相同，但身份在各自动作开始时生成，必须'
          '不同，否则服务端的永久去重会丢掉一条（A ${commitA.uid}，B ${commitB.uid}）',
    );

    // 同步：A 先推、B 拉自己的同时推、A 再把 B 的拉回来。
    await a.sync.syncNow();
    await b.sync.syncNow();
    await a.sync.syncNow();

    final rowsA = await testMemories(a.rig);
    final rowsB = await testMemories(b.rig);
    expect(
      describeMemories(rowsB),
      describeMemories(rowsA),
      reason:
          '两台设备各加一条同内容记忆之后行集合对不上：A 是 ${describeMemories(rowsA)}，'
          'B 是 ${describeMemories(rowsB)}（服务端序列 ${serverActions(server, userId)}）',
    );
    expect(
      rowsA,
      hasLength(3),
      reason:
          '两边都应当有共同起点加两条同内容记忆：实际 ${describeMemories(rowsA)}'
          '（服务端序列 ${serverActions(server, userId)}）',
    );

    final sameContent = [
      for (final row in rowsA)
        if (row['content'] == '同一条内容') row,
    ];
    expect(
      sameContent,
      hasLength(2),
      reason:
          '两条同内容记忆互相顶掉了：期望两条正文为“同一条内容”的行，'
          '实际 ${describeMemories(rowsA)}',
    );
    expect(
      {for (final row in sameContent) row['id']},
      hasLength(2),
      reason: '两条同内容记忆应当是两条不同的行：${describeMemories(sameContent)}',
    );

    // 服务端序列里两条提交都在，而且身份不同：第二条不能被当成第一条的重复。
    final sameRowKeys = {for (final row in sameContent) row['id']! as String};
    final coveredRows = <String>{};
    final uids = <String>{};
    for (final commit in server.commits[userId] ?? const []) {
      for (final change in commit['changes']! as List) {
        final rowKey = (change as Map)['row_key'] as String;
        if (!sameRowKeys.contains(rowKey)) continue;
        coveredRows.add(rowKey);
        uids.add(commit['uid']! as String);
      }
    }
    expect(
      coveredRows,
      sameRowKeys,
      reason:
          '服务端序列里缺少同内容记忆的提交：期望覆盖 $sameRowKeys，实际 $coveredRows'
          '（服务端序列 ${serverActions(server, userId)}）',
    );
    expect(uids, hasLength(2), reason: '两条提交在服务端用了同一个身份，第二条会被当成重复丢掉：$uids');
  });

  test('整库恢复旧备份之后新写下的提交能推到服务端，另一台设备看得到（3.1）', () async {
    final home = await Directory.systemTemp.createTemp(
      'zhixin_sync_uid_restore',
    );
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

    // 全新库：首次同步建立同步状态，再写一条记忆推上去，作为备份里的内容。
    await device.sync.syncNow(confirmBaseline: true);
    await addMemory('m1', '喜欢先看例子');
    await device.sync.syncNow();
    final userId = (await device.account.snapshot()).session!.userId;
    final backupPath = p.join(home.path, 'backup.zip');
    await dataVersions.backupRepository(backupPath);
    final backup = await File(backupPath).readAsBytes();

    // 备份之后又同步了一条记忆：服务端与库里的提交编号都前进了一条。
    await addMemory('m2', '备份之后才有的记忆');
    await device.sync.syncNow();
    final pushedAfterBackup = await engine.headId(raw);
    final serverHeadBeforeRestore = server.headOf(userId);
    expect(
      server.commits[userId]!.last['action'],
      '新增记忆',
      reason: '准备阶段：备份之后的写入推到了服务端',
    );
    expect(await memoryIds(), ['m1', 'm2'], reason: '准备阶段：本机有两条记忆');

    // 整库恢复旧备份：库与提交编号一起回到备份那一刻。
    final restored = await dataVersions.restore(backup);
    expect(
      restored,
      isA<Success<String?>>(),
      reason: '准备阶段：版本库备份应当能恢复：${restored.failureOrNull?.message}',
    );
    expect(await memoryIds(), ['m1'], reason: '准备阶段：恢复之后本机只有备份里的 m1');
    final restoreCommitId = await engine.headId(raw);
    expect(
      restoreCommitId,
      pushedAfterBackup,
      reason:
          '准备阶段：整库恢复把提交编号带回备份时刻，恢复提交复用了备份之后那条提交的编号'
          '（G1② 的撞号前提）：恢复提交 $restoreCommitId，备份之后那条 $pushedAfterBackup',
    );

    // 恢复之后的第一轮同步：确认“云端会改成恢复后的内容”，把恢复这一步推上去。
    await syncAfterRestore(device.sync);
    final serverHeadAfterRestore = server.headOf(userId);
    expect(
      serverHeadAfterRestore,
      serverHeadBeforeRestore + 1,
      reason:
          '恢复这一步没有推上去：服务端现在 ${server.headOf(userId)} 条，'
          '期望 ${serverHeadBeforeRestore + 1} 条（服务端序列 '
          '${serverActions(server, userId)}）',
    );

    // 恢复之后再写一条新记忆：它的编号接着被复用的编号往下排，旧实现会把
    // 回退编号撞上服务端已经见过的编号、被当成重复丢掉。
    await addMemory('m3', '恢复之后新写的一条');
    final pushed = await device.sync.syncNow();
    expect(
      pushed.pushedCommits,
      greaterThanOrEqualTo(1),
      reason: '恢复之后新写的提交没有推送：这一轮推了 ${pushed.pushedCommits} 条',
    );
    expect(
      server.headOf(userId),
      serverHeadAfterRestore + 1,
      reason:
          '恢复之后新写的提交没有进服务端序列：服务端现在 ${server.headOf(userId)} 条，'
          '期望 ${serverHeadAfterRestore + 1} 条（服务端序列 '
          '${serverActions(server, userId)}）',
    );
    final serverRowKeys = [
      for (final commit in server.commits[userId]!)
        for (final change in commit['changes']! as List)
          ((change as Map)['row_key']) as String,
    ];
    expect(
      serverRowKeys,
      contains('m3'),
      reason:
          '恢复之后新写的 m3 没进服务端序列：序列里的行 $serverRowKeys'
          '（服务端序列 ${serverActions(server, userId)}）',
    );

    // 另一台设备同步之后看到的是恢复后的内容：m1 加上恢复之后新写的 m3。
    final b = await openDevice('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    final onB = [for (final row in await testMemories(b.rig)) row['id']];
    expect(
      onB,
      ['m1', 'm3'],
      reason:
          '另一台设备没有拿到恢复之后新写的记忆：实际 $onB，期望 [m1, m3]'
          '（服务端序列 ${serverActions(server, userId)}）',
    );
  });
}

/// 恢复之后的第一轮同步：先向用户确认“云端会改成恢复后的内容”。
///
/// 复用首次基线的确认异常，只是文案不同；用例按现有
/// [BaselineConfirmationRequired] 处理，不需要确认时一轮就够。
Future<void> syncAfterRestore(SyncService sync) async {
  try {
    await sync.syncNow();
  } on BaselineConfirmationRequired {
    await sync.syncNow(confirmBaseline: true);
  }
}
