// 撤销一条撤销提交（重做）之后的同步验收（方案 3.11）。
//
// 重做形成一条普通的本机提交（类型仍是 undo、回指被重做的那条撤销），同步
// 照常推送；另一台设备拉到之后看到的是重做后的内容。

import 'package:flutter_test/flutter_test.dart';

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

  Future<SyncDevice> device(
    String email, {
    bool register = false,
    required String deviceId,
  }) async {
    final rig = await openTestRigWithUndoRules(clock: clock.call);
    final opened = await openSyncDevice(
      server,
      rig: rig,
      email: email,
      register: register,
      deviceId: deviceId,
      clock: clock,
    );
    devices.add(opened);
    return opened;
  }

  test('撤销之后重做，另一台设备同步能看到重新写入的内容', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;

    await insertTestMemory(a.rig, 'm1', content: '先看例子');
    final added = await a.rig.engine.headId(a.rig.raw);
    await a.sync.syncNow();
    expect(await testMemoryContent(a.rig, 'm1'), '先看例子');

    // 撤销新增：本机删除这条记忆。
    final undone = await a.rig.revisions.undoCommit(added);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await testMemory(a.rig, 'm1'), isNull);

    // 重做：把撤销掉的内容重新写入，形成一条回指撤销提交的新提交。
    final redone = await a.rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isTrue, reason: redone.message);
    expect(redone.commit!.revertedCommitId, undone.commit!.id);
    expect(await testMemoryContent(a.rig, 'm1'), '先看例子');
    await a.sync.syncNow();
    expect(
      server.commits[userId]!.length,
      greaterThan(0),
      reason: '重做之后应当把撤销与重做两条提交推上去：${serverActions(server, userId)}',
    );

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    expect(
      await testMemoryContent(b.rig, 'm1'),
      '先看例子',
      reason:
          '重做没有同步到另一台设备：期望 m1 的正文是先看例子，实际为空；'
          '服务端序列 ${serverActions(server, userId)}',
    );
  });
}
