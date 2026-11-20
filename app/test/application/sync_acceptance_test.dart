// 数据版本对照 git 的改进方案 3.2（G2、G3，按格变基）第一条验收的另一半。
//
// 3.2 的四条验收里，三条（一条提交改两行其中一行被覆盖、拉取后推送失败再同步、
// 同步过程中新写的修改照常推送）由 `sync_rebase_test.dart` 完整覆盖；第一条
// “A 改记忆内容、B 改同一条记忆的状态，双向同步后两边内容与状态都是各自的新值，
// 且没有冲突记录”只覆盖到前半句与“没有 updated_at 噪音”：现有用例逐列
// `singleWhere(column == 'content')` 取冲突、只断言 `updated_at` 不进冲突列表，
// 没有断言整张冲突列表为空。同一行的不同列各自被改时，用户不该看到任何冲突
// 记录（方案 3.2 把 updated_at 按维护列处理之后，冲突记录只剩用户能看懂的内容
// 列，而这次内容列与状态列都没有被对方改过）。这条用例把“没有冲突记录”补齐，
// 若实现误把整行或用户列登记成并发修改，即使两边取值碰巧都对，这里也会失败。
//
// 用例只依赖对外行为：两台设备的业务行、数据版本的冲突列表与同步结果。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

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
  }) async {
    final opened = await openSyncDevice(
      server,
      rig: await openTestRig(clock: clock.call),
      email: email,
      register: register,
      deviceId: deviceId,
      clock: clock,
    );
    devices.add(opened);
    return opened;
  }

  /// 两台设备同步到同一条记忆：A 上传基线，B 首次同步拉取之后，A 再同步一次
  /// 把两边位置归一，后面只比较两边各自改过的内容。
  Future<(SyncDevice, SyncDevice)> devicesWithMemory(String content) async {
    final a = await openDevice(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: content);
    await a.sync.syncNow(confirmBaseline: true);
    final b = await openDevice('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    return (a, b);
  }

  /// 冲突列表里每一条的“表/行/列”；失败信息里直接看出是哪一格。
  List<String> describeConflicts(List<RevisionConflict> conflicts) => [
    for (final conflict in conflicts)
      '${conflict.table}/${conflict.rowKey}/${conflict.column}'
          '（${conflict.reason}）',
  ];

  test('A 改内容、B 改状态双向同步后，两边都没有冲突记录（3.2）', () async {
    final (a, b) = await devicesWithMemory('喜欢先看例子');

    // A 只改内容，B 只改状态；两边都会顺带改到维护列 updated_at。
    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    }, label: '修改记忆内容');
    await updateTestMemory(b.rig, 'm1', {
      'status': 'superseded',
      'updated_at': '2026-11-17 10:06:00',
    }, label: '修改记忆状态');

    await b.sync.syncNow();
    await a.sync.syncNow();
    await b.sync.syncNow();

    // 先确认场景本身成立：两边各自的新值都到了对方那里。
    final aRow = (await testMemory(a.rig, 'm1'))!;
    final bRow = (await testMemory(b.rig, 'm1'))!;
    expect(
      bRow['content'],
      'A 的新内容',
      reason: '准备阶段：B 应当收到 A 改的内容，实际 ${bRow['content']}',
    );
    expect(
      aRow['status'],
      'superseded',
      reason: '准备阶段：A 应当收到 B 改的状态，实际 ${aRow['status']}',
    );

    // 验收要的是“没有冲突记录”：整张冲突列表为空，不只是 updated_at 不出现。
    final aConflicts = describeConflicts(await a.rig.revisions.conflicts());
    final bConflicts = describeConflicts(await b.rig.revisions.conflicts());
    expect(
      aConflicts,
      isEmpty,
      reason:
          'A 上出现了冲突记录：$aConflicts；两边改的是同一行的不同列，'
          '用户不该看到任何冲突（期望空列表）',
    );
    expect(
      bConflicts,
      isEmpty,
      reason:
          'B 上出现了冲突记录：$bConflicts；两边改的是同一行的不同列，'
          '用户不该看到任何冲突（期望空列表）',
    );
  });
}
