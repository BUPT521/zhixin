// 数据版本对照 git 的改进方案 3.7（快照与浅克隆）的客户端侧验收用例。
//
// 服务端一侧已经实现（ADR-0043）：账号可以登记”序列 N 的快照是附件 X、整库摘要
// 是 D“，服务端按保留期压缩快照之前的提交，head 与 pull 返回 `earliest_seq` 与
// `snapshot`，after 落在已删除区间时返回 410 `history_compacted`。
//
// 这里验证客户端的行为：
// - 新设备首次同步只下载快照与快照之后的提交，服务端序列长度不变；
// - 位置落在压缩区间的设备收到 410 之后按快照重建，本机未推送的提交重放；
// - 空闲时登记快照，409 与失败路径不阻塞同步；
// - 3.5 的“以云端为准修复”在历史被压缩时走快照重新克隆；
// - 服务端没有可用快照时给明确说明，不静默清空本机数据。
//
// 快照的字节由客户端按检查点格式压缩（`encodeSnapshotBytes`），用例直接解码核对
// 内容，不假设服务端解析过它。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/fake_server.dart';
import '../support/sync_rig.dart';
import '../support/test_db.dart';

void main() {
  late FakeServer server;
  late TestClock clock;
  final devices = <SyncDevice>[];
  final failures = <({String kind, String message})>[];

  setUp(() {
    server = FakeServer();
    clock = TestClock();
    devices.clear();
    failures.clear();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
  });

  Future<SyncDevice> device(
    String email, {
    bool register = false,
    required String deviceId,
  }) async {
    final rig = await openTestRig(clock: clock.call);
    final opened = await openSyncDevice(
      server,
      rig: rig,
      email: email,
      register: register,
      deviceId: deviceId,
      clock: clock,
      recordFailure: (error, stack, {required kind}) {
        failures.add((kind: kind, message: '$error'));
      },
    );
    devices.add(opened);
    return opened;
  }

  Future<String> userIdOf(SyncDevice device) async =>
      (await device.account.snapshot()).session!.userId;

  /// 直接改库、不形成提交：模拟绕过命令的写入。
  Future<void> deleteRowDirectly(SyncDevice device, String id) =>
      device.rig.raw.execute('DELETE FROM memory WHERE id = ?', [id]);

  /// 服务端的快照附件解出来的投影原文，用来核对登记的内容就是当时的投影。
  String snapshotProjectionOf(String userId) {
    final pointer = server.snapshotOf(userId)!;
    final bytes = server.blobs[userId]![pointer.sha256]!;
    return encodeProjection(decodeSnapshotBytes(bytes));
  }

  test('新设备首次同步只下载快照与之后的提交，服务端序列长度不变', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    // 登记由同步收尾的空闲登记完成：位置是当时的最新序列，内容是当时的投影。
    final registered = server.snapshotOf(userId);
    expect(registered, isNotNull, reason: '同步完成、没有待推送提交时应当登记快照');
    expect(registered!.seq, server.headOf(userId));
    expect(
      registered.digest,
      await a.rig.revisions.currentStateDigest(),
      reason: '登记的摘要用 3.5 的整库摘要',
    );
    expect(
      snapshotProjectionOf(userId),
      encodeProjection(await a.rig.engine.readProjection(a.rig.raw)),
      reason: '快照字节按检查点格式压缩，解出来应当等于当时的投影',
    );

    // 另一台设备接着推一条提交，快照停在原来的位置（这里强制登记返回 409，
    // 模拟服务端已有更新的快照，快照指针因此不会跟着每一轮同步往前挪）。
    server.snapshotAlwaysConflicts = true;
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await insertTestMemory(b.rig, 'm2', content: '晚上效率低');
    await b.sync.syncNow();
    expect(server.snapshotOf(userId)!.seq, registered.seq);
    final headBeforeCompact = server.headOf(userId);
    expect(headBeforeCompact, registered.seq + 1);

    // 保留期到达之后服务端删掉快照之前的提交：新设备只能从快照开始。
    server.compactThrough(userId, registered.seq);
    final c = await device('a@example.com', deviceId: 'device-c');
    final result = await c.sync.syncNow();

    expect(result.pulledCommits, 1, reason: '只拉快照之后的那一条提交');
    expect(result.pushedCommits, 0, reason: '快照内容由快照表达，不上传基线');
    expect(server.headOf(userId), headBeforeCompact, reason: '服务端序列长度不变');
    expect(await testMemoryContent(c.rig, 'm1'), '喜欢先看例子');
    expect(await testMemoryContent(c.rig, 'm2'), '晚上效率低');

    // 本机历史里有一条来自云端快照的基线提交，之后照常追加远端提交。
    final history = await c.rig.revisions.history();
    expect(
      history.commits.where((commit) => commit.action == '从云端快照重建'),
      isNotEmpty,
      reason: '快照导入写成一条本机提交：${history.commits.map((c) => c.action)}',
    );
    final status = await c.sync.status();
    expect(status.serverHead, server.headOf(userId));
    expect(status.pendingCommits, 0);

    // 导入之后还能继续追加提交与同步：写一条再同步，另一台设备能看到。
    await insertTestMemory(c.rig, 'm3', content: 'C 新加的一行');
    await c.sync.syncNow();
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm3'), 'C 新加的一行');
  });

  test('410 之后按快照重建，本机未推送的提交重放并推送', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    // A 再推一条：快照推进到当前位置，B 的位置落后于它。
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    final snapshotSeq = server.snapshotOf(userId)!.seq;
    expect(snapshotSeq, server.headOf(userId));
    server.compactThrough(userId, snapshotSeq);
    final beforeReclone = await b.rig.engine.headId(b.rig.raw);

    // B 本机有一条还没有推送的修改：拉取会撞上 410，重建要先说明再确认。
    await updateTestMemory(b.rig, 'm1', {
      'content': 'B 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    });
    await expectLater(
      b.sync.syncNow(),
      throwsA(
        isA<SyncSnapshotProblem>().having(
          (problem) => problem.code,
          'code',
          SyncSnapshotCode.confirmationRequired,
        ),
      ),
      reason: '本机已有数据时重建不能静默替换',
    );
    expect(await testMemoryContent(b.rig, 'm1'), 'B 的新内容');
    expect(server.headOf(userId), snapshotSeq, reason: '确认之前不向服务端写');

    final result = await b.sync.syncNow(confirmReclone: true);
    expect(result.pushedCommits, 1, reason: '重放出来的本机改动按普通推送发上去');
    expect(server.headOf(userId), snapshotSeq + 1);
    expect(
      await testMemoryContent(b.rig, 'm2'),
      '晚上效率低',
      reason: '快照里的内容要装进本机',
    );
    expect(
      await testMemoryContent(b.rig, 'm1'),
      'B 的新内容',
      reason: '本机未推送的修改在快照之上重放，不能被快照盖掉',
    );
    final replayed = server.commits[userId]!.last;
    expect(replayed['action'], '修改记忆', reason: '重放保留原提交的动作文案');
    expect((replayed['changes']! as List).length, 1, reason: '一条重放提交只带这一行变化');
    expect(
      await b.rig.engine.headId(b.rig.raw),
      greaterThan(beforeReclone),
      reason: '重放写成本机新提交',
    );

    // 另一台设备同步之后看到 B 的改动，两边内容一致。
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm1'), 'B 的新内容');
    expect((await b.sync.status()).digestMismatch, isFalse);
  });

  test('服务端没有打开压缩时不上传也不登记快照', () async {
    server.compact = false;
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    final uploads = server.blobUploadAttempts;
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    expect(server.headOf(userId), greaterThan(0));
    expect(server.snapshotRegistrations, 0, reason: '压缩关闭时登记只写指针，客户端不必登记');
    expect(server.snapshotOf(userId), isNull, reason: '没有登记就没有快照指针');
    expect(server.blobUploadAttempts, uploads, reason: '快照附件也不上传，避免白占附件配额');

    // 服务端打开之后，下一轮同步照常补登记。
    server.compact = true;
    await a.sync.syncNow();
    expect(server.snapshotOf(userId), isNotNull);
    expect(server.snapshotRegistrations, 1);
  });

  test('空闲登记：成功之后重复同步不再登记，409 与失败都不阻塞同步', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    final first = server.snapshotOf(userId)!;
    expect(server.snapshotRegistrations, 1);

    // 同一位置、同一份内容再同步一次：不重复上传也不重复登记。
    final uploads = server.blobUploadAttempts;
    await a.sync.syncNow();
    expect(server.snapshotRegistrations, 1, reason: '已登记的位置不重复登记');
    expect(server.blobUploadAttempts, uploads, reason: '内容没变不重复上传快照');

    // 409：服务端已有更新的快照，放弃本次，同步本身照常完成。
    server.snapshotAlwaysConflicts = true;
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    final conflicted = failures.length;
    final result = await a.sync.syncNow();
    expect(result.pushedCommits, 1);
    expect(server.snapshotOf(userId)!.seq, first.seq, reason: '409 时快照指针不动');
    expect(
      failures.length,
      conflicted,
      reason: '409 表示已有更新的快照，不算失败：${failures.map((f) => f.kind)}',
    );

    // 登记失败只记诊断，不阻塞这一轮同步；下一轮补齐。
    server.snapshotAlwaysConflicts = false;
    server.snapshotFailures = 1;
    await insertTestMemory(a.rig, 'm3', content: '下午效率更高');
    final failed = await a.sync.syncNow();
    expect(failed.pushedCommits, 1, reason: '登记失败不影响推送');
    expect(
      failures.map((failure) => failure.kind),
      contains('cloud_sync_snapshot'),
      reason: '登记失败写一条诊断',
    );
    expect(server.snapshotOf(userId)!.seq, first.seq);
    await a.sync.syncNow();
    expect(
      server.snapshotOf(userId)!.seq,
      server.headOf(userId),
      reason: '下一轮同步把快照补登记到最新位置',
    );
  });

  test('以云端为准修复：历史被压缩时走快照重新克隆', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    // B 本机删掉一行、没有形成提交：两边内容不一致。
    await deleteRowDirectly(b, 'm1');
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    final headBeforeRepair = server.headOf(userId);
    await b.sync.syncNow();
    expect((await b.sync.status()).digestMismatch, isTrue);

    // 快照之前的提交被压缩掉：差异重放读不到第 1 条，修复改走快照。
    server.compactThrough(userId, server.snapshotOf(userId)!.seq);
    final repaired = await b.sync.repairFromCloud();
    expect(repaired.pulledCommits, greaterThanOrEqualTo(0));
    expect(
      await testMemoryContent(b.rig, 'm1'),
      '喜欢先看例子',
      reason: '快照里的行按云端内容装回本机',
    );
    expect(await testMemoryContent(b.rig, 'm2'), '晚上效率低');
    expect(
      (await b.sync.status()).digestMismatch,
      isFalse,
      reason: '以云端为准修复之后清掉不一致状态',
    );
    expect(
      server.headOf(userId),
      headBeforeRepair,
      reason: '本机没有独有行可补传时服务端序列不变',
    );
    expect(
      await b.rig.revisions.currentStateDigest(),
      await a.rig.revisions.currentStateDigest(),
    );
  });

  test('重建时按 3.2 的剩余部分重放：被云端覆盖的格子不再推回去', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    // A 改一次并同步：快照推进到这一条，B 的位置落后于它。
    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 改的内容',
      'updated_at': '2026-11-17 10:02:00',
    });
    await a.sync.syncNow();
    final snapshotSeq = server.snapshotOf(userId)!.seq;
    // 之后 A 再改一次同一行，但没有登记新快照（快照停在 snapshotSeq）。
    server.snapshotAlwaysConflicts = true;
    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 又改的内容',
      'updated_at': '2026-11-17 10:03:00',
    });
    await a.sync.syncNow();
    final headBeforeReclone = server.headOf(userId);
    server.compactThrough(userId, snapshotSeq);

    // B 本机还改过同一行、没有推送：快照之后的远端提交已经覆盖了这些格子，
    // 重放时应当整条去掉，不把旧值推回服务端（ADR-0040 的按格变基）。
    await updateTestMemory(b.rig, 'm1', {
      'content': 'B 的修改',
      'updated_at': '2026-11-17 10:04:00',
    });
    await expectLater(
      b.sync.syncNow(),
      throwsA(
        isA<SyncSnapshotProblem>().having(
          (problem) => problem.code,
          'code',
          SyncSnapshotCode.confirmationRequired,
        ),
      ),
    );
    final result = await b.sync.syncNow(confirmReclone: true);

    expect(result.pushedCommits, 0, reason: '被云端覆盖的格子整条不推');
    expect(server.headOf(userId), headBeforeReclone);
    expect(
      await testMemoryContent(b.rig, 'm1'),
      'A 又改的内容',
      reason: '快照与之后的远端提交是较晚到达的值，本机旧改动不再覆盖它',
    );
    expect((await b.sync.status()).pendingCommits, 0);
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm1'), 'A 又改的内容');
  });

  test('本机已有数据的设备首次同步遇到压缩时先确认，再按快照重建并重放本机记录', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: 'A 先有的记录');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    server.compactThrough(userId, server.headOf(userId));

    // B 在首次同步之前已经有自己的记录，账号还从没同步过。
    final b = await device('a@example.com', deviceId: 'device-b');
    await insertTestMemory(b.rig, 'm2', content: 'B 先有的记录');
    await expectLater(
      b.sync.syncNow(),
      throwsA(isA<BaselineConfirmationRequired>()),
      reason: '本机有记录时首次同步仍要先确认一次',
    );
    await expectLater(
      b.sync.syncNow(confirmBaseline: true),
      throwsA(
        isA<SyncSnapshotProblem>().having(
          (problem) => problem.code,
          'code',
          SyncSnapshotCode.confirmationRequired,
        ),
      ),
      reason: '云端历史已压缩，替换本机历史之前还要确认一次',
    );
    expect(
      await testMemoryContent(b.rig, 'm2'),
      'B 先有的记录',
      reason: '两次确认之前都不改动本机数据',
    );

    final result = await b.sync.syncNow(
      confirmBaseline: true,
      confirmReclone: true,
    );
    expect(result.pushedCommits, 1, reason: '本机的记录重放之后按普通提交推上去');
    expect(await testMemoryContent(b.rig, 'm1'), 'A 先有的记录');
    expect(await testMemoryContent(b.rig, 'm2'), 'B 先有的记录');
    final history = await b.rig.revisions.history();
    expect(
      history.commits.where((commit) => commit.action == '从云端快照重建'),
      isNotEmpty,
      reason: '重建写成一条本机提交',
    );
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm2'), 'B 先有的记录');
    expect((await b.sync.status()).pendingCommits, 0);
  });

  test('云端历史已压缩且没有可用快照时给明确说明，本机数据不动', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    final snapshotSeq = server.snapshotOf(userId)!.seq;
    server.compactThrough(userId, snapshotSeq);
    // 服务端没有可用快照（例如刚升级、或者快照附件丢失）。
    server.snapshots.remove(userId);
    final headBefore = await b.rig.engine.headId(b.rig.raw);

    await expectLater(
      b.sync.syncNow(),
      throwsA(
        isA<SyncSnapshotProblem>().having(
          (error) => error.message,
          'message',
          contains('缺少可用快照'),
        ),
      ),
    );
    expect(
      await b.rig.engine.headId(b.rig.raw),
      headBefore,
      reason: '不能自动重建时本机历史保持不变',
    );
    expect(await testMemoryContent(b.rig, 'm1'), '喜欢先看例子');
    expect(
      await testMemoryContent(b.rig, 'm2'),
      isNull,
      reason: '没有重建就没有拉到快照之后的内容',
    );
    expect((await b.sync.status()).lastError, contains('缺少可用快照'));
  });
}
