// 数据版本对照 git 的改进方案 3.5（G8，一致性摘要）的同步侧验收用例。
//
// 摘要的纯函数与“增量更新等于整库重算”在 data 层用例里已经覆盖；这里只验行为：
// 推送完成且本机没有待推送提交时最后一条提交带摘要、另一台设备拉取之后比较、
// 一台设备漏掉一条提交之后能发现不一致，以及两个修复入口能清掉状态。
//
// “漏掉一条提交”用直接改库模拟：版本采集只在命令事务里打开（capturing = 1），
// 事务之外执行 SQL 不形成提交，与绕过命令的丢失一致。

import 'package:flutter_test/flutter_test.dart';

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

  /// 直接改库，不形成提交：模拟一次没有到达服务端、也没有留下提交记录的丢写。
  Future<void> deleteRowDirectly(SyncDevice device, String id) =>
      device.rig.raw.execute('DELETE FROM memory WHERE id = ?', [id]);

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

  test('一台设备漏掉一条提交之后，下一次同步发现不一致并写诊断', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = await userIdOf(a);
    expect((await b.sync.status()).digestMismatch, isFalse);

    // B 本机漏掉了 m1 这一行：直接改库，没有形成提交，云端对应的提交仍在。
    await deleteRowDirectly(b, 'm1');
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    failures.clear();

    // 下一次同步拉到 A 的新提交（带摘要），本机没有待推送提交，于是比较摘要。
    await b.sync.syncNow();
    final status = await b.sync.status();
    expect(status.digestMismatch, isTrue, reason: '两边内容不同，应当置为不一致');
    expect(
      failures.map((failure) => failure.kind),
      contains('cloud_sync_digest'),
      reason: '不一致时写一条诊断记录',
    );
    expect(
      await b.rig.revisions.currentStateDigest(),
      isNot(server.commits[userId]!.last['state_digest']),
    );

    // 已知不一致时继续写入并同步：推送只补本机内容，删不掉云端多出来的行，
    // 所以这一轮不对外声明摘要，免得把“推完就一致”的错误结论带给别的设备。
    await insertTestMemory(b.rig, 'm4', content: 'B 新加的一行');
    await b.sync.syncNow();
    expect(
      server.commits[userId]!.last['state_digest'],
      isNull,
      reason: '已知不一致时最后一条提交不带摘要',
    );
    expect((await b.sync.status()).digestMismatch, isTrue);
  });

  test('以云端为准修复：清掉不一致状态，并按云端找回漏掉的内容', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = await userIdOf(a);

    await deleteRowDirectly(b, 'm1');
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect((await b.sync.status()).digestMismatch, isTrue);
    final headBeforeRepair = server.headOf(userId);

    final result = await b.sync.repairFromCloud();
    expect(result.pulledCommits, greaterThanOrEqualTo(1), reason: '按首次基线重新拉取');
    expect(
      await b.rig.revisions.currentStateDigest(),
      await a.rig.revisions.currentStateDigest(),
      reason: '重新拉取之后两边摘要相等',
    );
    expect(
      await testMemoryContent(b.rig, 'm1'),
      '喜欢先看例子',
      reason: '漏掉的行由云端提交重新应用回来',
    );
    expect(
      (await b.sync.status()).digestMismatch,
      isFalse,
      reason: '修复之后清掉不一致状态',
    );
    expect(
      server.headOf(userId),
      headBeforeRepair,
      reason: '以云端为准不新增云端内容（本机没有独有行可补）',
    );
  });

  test('以本机为准修复：补传本机独有的行，并清掉不一致状态', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = await userIdOf(a);

    // B 本机多出一行，直接改库、没有形成提交：云端没有，本机有。
    await insertRowDirectly(b, 'm2', 'B 本机独有的行');
    await insertTestMemory(a.rig, 'm3', content: 'A 新加的一行');
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(
      (await b.sync.status()).digestMismatch,
      isTrue,
      reason: '本机多一行，摘要对不上',
    );
    final headBeforeRepair = server.headOf(userId);

    final result = await b.sync.repairFromLocal();
    expect(result.pushedCommits, 1, reason: '本机独有的 m2 作为一条基线提交补传');
    expect(
      server.headOf(userId),
      headBeforeRepair + 1,
      reason: '补传只增加一条基线提交，不删除云端已有的提交',
    );
    final baseline = server.commits[userId]!.last;
    expect(
      [
        for (final change in baseline['changes']! as List)
          '${(change as Map)['table']}/${change['row_key']}',
      ],
      ['memory/m2'],
      reason: '已经由远端提交表达过的行不重复上传：${baseline['changes']}',
    );
    expect(
      baseline['state_digest'],
      await b.rig.revisions.currentStateDigest(),
      reason: '补传完成且本机没有待推送提交，基线提交带当前摘要',
    );
    expect(
      (await b.sync.status()).digestMismatch,
      isFalse,
      reason: '修复之后清掉不一致状态',
    );

    // 另一台设备同步之后拿到这条本机独有的行。
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm2'), 'B 本机独有的行');
  });

  test('以云端为准修复能重放更新，不只覆盖新增', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = await userIdOf(a);

    await updateTestMemory(a.rig, 'm1', {
      'content': '先看例子再看定义',
      'updated_at': '2026-11-17 10:01:00',
    });
    await a.sync.syncNow();
    // B 本机把另一行改成别的内容，没有形成提交；拉取只覆盖 A 改过的 m1。
    await b.rig.raw.execute(
      'UPDATE memory SET content = ?, updated_at = ? WHERE id = ?',
      ['本机乱改的内容', '2026-11-17 10:02:00', 'm2'],
    );
    await b.sync.syncNow();
    expect(
      (await b.sync.status()).digestMismatch,
      isTrue,
      reason: '本机与云端有一行内容不同',
    );

    await b.sync.repairFromCloud();
    expect(
      await testMemoryContent(b.rig, 'm1'),
      '先看例子再看定义',
      reason: '更新只带变化列，重放时要并进上一条提交留下的整行',
    );
    expect(
      await testMemoryContent(b.rig, 'm2'),
      '晚上效率低',
      reason: '本机被直接改过的行按云端值改回',
    );
    expect((await b.sync.status()).digestMismatch, isFalse);
    expect(
      await b.rig.revisions.currentStateDigest(),
      await a.rig.revisions.currentStateDigest(),
    );
    expect(server.headOf(userId), greaterThan(0));
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
