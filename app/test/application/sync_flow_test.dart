// 同步的确认顺序与执行只有一份（审查条目 A22）。
//
// 账号页与“我的”页原先各写一遍“先问恢复对齐、再问首次基线、最后问快照重建，
// 取消基线时暂停自动同步”的顺序，提示文案已经分叉。这里直接核对 SyncFlow：
// 确认回调收到的种类、取消与确认的结论，以及取消之后本机与服务端的状态。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/sync_flow.dart';

import '../support/fake_server.dart';
import '../support/sync_rig.dart';
import '../support/test_db.dart';

void main() {
  const email = 'sync-flow@example.com';

  /// 一台登录了 [email]、本机已有一条提交的设备。
  Future<SyncDevice> openDevice(FakeServer server, TestClock clock) async {
    final device = await openSyncDevice(
      server,
      rig: await openTestRig(clock: clock.call),
      email: email,
      register: true,
      deviceId: 'device-a',
      clock: clock,
    );
    await insertTestMemory(device.rig, 'm1', content: '喜欢先看例子');
    return device;
  }

  test('首次同步取消：流程给出取消结论、暂停自动同步且不向服务端上传', () async {
    final server = FakeServer();
    final clock = TestClock();
    final device = await openDevice(server, clock);
    addTearDown(device.close);
    await device.account.setAutoSync(true);
    final asked = <SyncConfirmation>[];

    final result = await device.sync.flow.run(
      confirm: (confirmation) async {
        asked.add(confirmation);
        return false;
      },
    );

    expect(result.cancelled, isTrue);
    expect(result.outcome, SyncOutcome.cancelledBaselineUpload);
    expect(result.result, isNull);
    final confirmation = asked.single;
    expect(confirmation, isA<SyncBaselineUpload>());
    expect((confirmation as SyncBaselineUpload).localCommits, 1);
    expect(await device.account.autoSync(), isFalse, reason: '取消基线会暂停自动同步');
    expect(
      server.commits[server.userIdOf(email)] ?? const [],
      isEmpty,
      reason: '取消之后没有上传任何提交',
    );
  });

  test('首次同步确认：同一流程上传本机提交并返回计数', () async {
    final server = FakeServer();
    final clock = TestClock();
    final device = await openDevice(server, clock);
    addTearDown(device.close);
    final asked = <SyncConfirmation>[];

    final result = await device.sync.flow.run(
      confirm: (confirmation) async {
        asked.add(confirmation);
        return true;
      },
    );

    expect(result.outcome, SyncOutcome.completed);
    expect(result.cancelled, isFalse);
    expect(asked.single, isA<SyncBaselineUpload>());
    expect(result.result!.pushedCommits, 1);
    expect(result.digestMismatch, isFalse);
    expect(server.commits[server.userIdOf(email)], isNotEmpty);
  });

  test('已经同步过的设备再同步一次不问确认，直接完成', () async {
    final server = FakeServer();
    final clock = TestClock();
    final device = await openDevice(server, clock);
    addTearDown(device.close);
    await device.sync.flow.run(confirm: (_) async => true);

    var asked = 0;
    final result = await device.sync.flow.run(
      confirm: (_) async {
        asked += 1;
        return true;
      },
    );

    expect(asked, 0, reason: '没有需要确认的步骤');
    expect(result.outcome, SyncOutcome.completed);
    expect(result.changed, isFalse);
  });
}
