// 数据版本对照 git 的改进方案 3.5（G8，一致性摘要）的同步侧验收用例。
//
// 摘要的纯函数与“增量更新等于整库重算”在 data 层用例里已经覆盖；这里只验行为：
// 推送完成且本机没有待推送提交时最后一条提交带摘要、另一台设备拉取之后比较、
// 一台设备漏掉一条提交之后能发现不一致，以及以本机为准重建云端能清掉状态。
//
// “漏掉一条提交”用直接改库模拟：版本采集只在命令事务里打开（capturing = 1），
// 事务之外执行 SQL 不形成提交，与绕过命令的丢失一致。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/sync_service.dart';

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

  /// 直接插一行，不形成提交：模拟本机独有、云端没有的内容。
  Future<void> insertRowDirectly(
    SyncDevice device,
    String id,
    String content,
  ) => device.rig.raw.execute(
    'INSERT INTO memory (id, kind, content, scope, source_kind, source_id, '
    'valid_until, status, created_at, updated_at) '
    "VALUES (?, 'semantic', ?, NULL, 'user', NULL, NULL, 'active', "
    "'2026-11-17 10:00:00', '2026-11-17 10:00:00')",
    [id, content],
  );

  test('推送完成时最后一条提交带上整库摘要，两台设备同步后摘要相等、不提示', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    final digest = await a.rig.revisions.currentStateDigest();
    expect(
      server.commits[userId]!.last['state_digest'],
      digest,
      reason: '基线推送完成、本机没有待推送提交时，最后一条提交应当带当前摘要',
    );

    final b = await device('a@example.com', deviceId: 'device-b');
    final pulled = await b.sync.syncNow();
    expect(pulled.pulledCommits, greaterThanOrEqualTo(1));
    expect(
      await b.rig.revisions.currentStateDigest(),
      digest,
      reason: '两台设备回放同一条序列之后摘要应当相等',
    );
    expect(
      (await b.sync.status()).digestMismatch,
      isFalse,
      reason: '摘要一致时不该提示本机与云端不一致',
    );
    expect(
      failures.where((failure) => failure.kind == 'cloud_sync_digest'),
      isEmpty,
      reason: '一致时不该写摘要不一致的诊断',
    );

    // 再推一条：新的摘要换到最后一条提交上，另一台设备拉取之后仍然一致。
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    final pushed = server.commits[userId]!.last;
    expect(pushed['state_digest'], await a.rig.revisions.currentStateDigest());
    await b.sync.syncNow();
    expect(
      await b.rig.revisions.currentStateDigest(),
      await a.rig.revisions.currentStateDigest(),
    );
    expect((await b.sync.status()).digestMismatch, isFalse);
  });

  test('一次推两条提交时只有最后一条带摘要', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    final before = server.headOf(userId);

    await insertTestMemory(a.rig, 'm1', content: '第一条');
    await insertTestMemory(a.rig, 'm2', content: '第二条');
    await a.sync.syncNow();

    expect(server.headOf(userId), before + 2, reason: '两条本机提交各推一条');
    final log = server.commits[userId]!;
    expect(
      log[log.length - 2]['state_digest'],
      isNull,
      reason: '不是最后一条提交时不带摘要',
    );
    expect(
      log.last['state_digest'],
      await a.rig.revisions.currentStateDigest(),
      reason: '最后一条提交带推完之后的状态摘要',
    );
  });

  test('另一台设备收到命名版本，显式删除后旧编辑不会恢复名称', () async {
    final a = await device('a@example.com', register: true, deviceId: 'a');
    final b = await device('a@example.com', deviceId: 'b');
    await a.sync.syncNow();
    await insertTestMemory(a.rig, 'named-memory', content: '需要保留的记录');
    final head = await a.rig.engine.headId(a.rig.raw);
    final named = await a.rig.revisions.name(head, label: '期中复习');
    await a.sync.syncNow();
    await b.sync.syncNow();
    final refs = await b.rig.engine.refs(b.rig.raw);
    expect(refs.single.commitUid, named.commitUid);
    expect((await b.rig.engine.refCommitIds(b.rig.raw))['期中复习'], isNotNull);

    final otherHead = await b.rig.engine.headId(b.rig.raw);
    await b.rig.revisions.name(otherHead, label: '期中复习', note: '较早的离线编辑');
    await a.rig.revisions.deleteName('期中复习');
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(await b.rig.engine.refs(b.rig.raw), isEmpty);
    expect(await a.rig.engine.tombstones(a.rig.raw), isEmpty);
  });

  test('以本机为准重建云端：清空服务端序列后整份上传，另一台设备重新上传', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '云端原来的值');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = await userIdOf(a);

    // B 本机改一行、再插一行，都没有形成提交：两边内容不同。
    await b.rig.raw.execute(
      "UPDATE memory SET content = 'B 改过的值', "
      "updated_at = '2026-11-17 10:01:00' WHERE id = 'm1'",
    );
    await insertRowDirectly(b, 'm2', 'B 本机独有的行');
    await insertTestMemory(a.rig, 'm3', content: 'A 新加的一行');
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect((await b.sync.status()).digestMismatch, isTrue);

    final result = await b.sync.rebuildCloudFromLocal(
      password: syncTestPassword,
    );
    expect(server.headOf(userId), greaterThan(0), reason: '清空之后本机内容整份上传');
    expect(result.pushedCommits, greaterThan(0));
    expect((await b.sync.status()).digestMismatch, isFalse);
    expect(await testMemoryContent(b.rig, 'm1'), 'B 改过的值', reason: '重建不改本机内容');
    final rebuiltRows = [
      for (final commit in server.commits[userId]!)
        for (final change in commit['changes']! as List)
          '${(change as Map)['table']}/${change['row_key']}',
    ];
    expect(rebuiltRows, contains('memory/m2'), reason: 'B 本机独有的行随基线一起上传');

    // 另一台设备发现服务端位置回到 0，按首次同步重新上传它本机的内容；两边最后
    // 收敛到同一份摘要。
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm2'), 'B 本机独有的行');
    expect(
      await a.rig.revisions.currentStateDigest(),
      await b.rig.revisions.currentStateDigest(),
    );
    expect((await a.sync.status()).digestMismatch, isFalse);
    expect((await b.sync.status()).digestMismatch, isFalse);
  });

  test('以本机为准重建云端在历史被压缩之后也能用', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '压缩前的记录');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await insertTestMemory(a.rig, 'm2', content: '压缩前的另一条');
    await a.sync.syncNow();
    final snapshotSeq = server.snapshotOf(userId)!.seq;
    server.compactThrough(userId, snapshotSeq);

    // B 落后于保留下界：普通同步要先确认再按快照重建，重建云端不必下载快照。
    await expectLater(b.sync.syncNow(), throwsA(isA<SyncSnapshotProblem>()));
    final result = await b.sync.rebuildCloudFromLocal(
      password: syncTestPassword,
    );
    expect(result.pushedCommits, greaterThan(0));
    expect(server.headOf(userId), greaterThan(0));
    expect((await b.sync.status()).digestMismatch, isFalse);
    expect(await testMemoryContent(b.rig, 'm1'), '压缩前的记录');

    // 另一台设备按首次同步重新对齐，B 再拉一次把 A 补传的行取回来。
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(
      await a.rig.revisions.currentStateDigest(),
      await b.rig.revisions.currentStateDigest(),
    );
  });

  test('先拉取再推送的那一轮也在最后一条提交上带摘要', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '第一条');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    final userId = await userIdOf(a);

    // A 先推一条，B 这一轮会先拉取它、再推自己的一条：本机待推送清零，摘要
    // 应当附在 B 推上去的最后一条提交上（远端提交在它之前，不影响判断）。
    await insertTestMemory(a.rig, 'm2', content: 'A 新增');
    await a.sync.syncNow();
    await insertTestMemory(b.rig, 'm3', content: 'B 新增');
    await b.sync.syncNow();
    final pushed = server.commits[userId]!.last;
    final previous =
        server.commits[userId]![server.commits[userId]!.length - 2];
    // 提交身份改按 `uid`：最后一条是 B 推上去的本机提交，与前一条的 uid 不同。
    expect(pushed['uid'], isNot(previous['uid']), reason: '最后一条是 B 推上去的本机提交');
    expect(
      pushed['state_digest'],
      await b.rig.revisions.currentStateDigest(),
      reason: '拉取之后再推送，推完同样没有待推送提交，要带摘要',
    );

    await a.sync.syncNow();
    expect(
      await a.rig.revisions.currentStateDigest(),
      await b.rig.revisions.currentStateDigest(),
      reason: '两边回放同一条序列之后摘要相等',
    );
    expect((await a.sync.status()).digestMismatch, isFalse);
  });
}
