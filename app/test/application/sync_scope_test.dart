// 数据版本对照 git 的改进方案（G4、G6）的验收用例。
//
// 退出登录与清除云端只清掉偏好，库里“已经推送到哪里”的读取位置仍在且仍然
// 阻塞清理历史；同一账号重新登录时又按首次同步整份重传一次基线。这两条在
// 阶段 1 的 3.3、3.6 落地之前应当失败。

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
    final rig = await openTestRig(clock: clock.call);
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

  /// 退出登录：账号页先退出会话，再把同步偏好清掉；库里的同步位置留着。
  Future<void> signOut(SyncDevice device) async {
    await device.account.logout();
    await device.sync.clearState();
    final status = await device.sync.status();
    expect(status.signedIn, isFalse, reason: '准备阶段：退出之后应当处于未登录状态');
  }

  test('退出登录后“清理历史”不再被拒（G4）', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await a.sync.syncNow(confirmBaseline: true);
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow();
    // 退出之前还有一次没有同步的写入：推送位置因此落在 HEAD 之后。
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');

    await signOut(a);

    final blockers = await a.rig.revisions.historyBlockers(clearing: true);
    expect(blockers, isEmpty, reason: '退出登录之后仍然有阻塞的同步位置：$blockers');
    await expectLater(
      a.rig.revisions.clearHistory(),
      completes,
      reason: '退出登录之后“清理历史”被拒绝了',
    );
    expect(
      await a.rig.revisions.historyBlockers(clearing: true),
      isEmpty,
      reason: '清理历史之后不应当再有阻塞的读取位置',
    );
  });

  test('同一账号重新登录后只推送退出期间的新提交，服务端序列不多一份基线（G4/G6）', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await a.sync.syncNow(confirmBaseline: true);
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;
    final headBeforeLogout = server.headOf(userId);
    expect(
      server.commits[userId]!.last['action'],
      '新增记忆',
      reason: '准备阶段：新增记忆推上去之后服务端最后一条是这次写入',
    );

    await signOut(a);
    await insertTestMemory(a.rig, 'm2', content: '退出期间新增');
    await a.account.login(
      identifier: 'a@example.com',
      password: syncTestPassword,
    );

    final result = await a.sync.syncNow();
    expect(result.pulledCommits, 0, reason: '退出期间服务端没有新提交，重新登录后这一轮不应当拉取');
    expect(
      server.headOf(userId),
      headBeforeLogout + 1,
      reason:
          '重新登录后没有按原位置增量同步：服务端现在有 ${server.headOf(userId)} 条'
          '提交，期望 ${headBeforeLogout + 1} 条（退出前 $headBeforeLogout 条，'
          '退出期间新增 1 条）',
    );
    final baselineCount = server.commits[userId]!
        .where((commit) => commit['action'] == '首次同步基线')
        .length;
    expect(
      baselineCount,
      1,
      reason:
          '重新登录又上传了一份基线：服务端有 $baselineCount 条基线，'
          '期望只有首次同步时那 1 条',
    );
    expect(
      server.commits[userId]!.last['action'],
      '新增记忆',
      reason:
          '服务端最后一条提交应当是退出期间的那次写入，'
          '实际是 ${server.commits[userId]!.last['action']}',
    );
  });
}
