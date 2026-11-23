// 远端提交的来源设备与作者时间（方案 3.12）：同步应用远端提交时把服务端带来的
// `device_id` 与 `created_at` 落到本机 `revision_commit` 的 `origin_device` 与
// `authored_at`；本机提交这两列保持为空与等值（`authored_at` 等于落库时间）。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
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
    clock = TestClock(DateTime(2026, 11, 17, 10));
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

  /// 按动作取一条提交行；同一动作在用例里只应出现一次。
  Future<Map<String, Object?>> commitRow(
    TestRig rig, {
    required String action,
  }) async {
    final rows = await selectRows(
      rig.raw,
      'revision_commit',
      where: 'action = ?',
      whereArgs: [action],
    );
    expect(rows, hasLength(1), reason: '动作“$action”应当对应一条提交：$rows');
    return rows.single;
  }

  test('远端提交记下来源设备与作者时间，本机提交两列保持为空与等值', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await a.sync.syncNow(confirmBaseline: true);

    // A 在 10:05 写一条并推送：本机提交的 origin_device 为空，authored_at 这一
    // 列也只有远端提交才写，本机提交是空值，落库时间看 created_at。
    clock.advance(const Duration(minutes: 5));
    await insertTestMemory(a.rig, 'm1', content: 'A 写的一条');
    final aCommit = await commitRow(a.rig, action: '新增记忆');
    expect(aCommit['origin_device'], isNull);
    expect(aCommit['authored_at'], isNull);
    expect(aCommit['created_at'], '2026-11-17 10:05:00');
    await a.sync.syncNow();

    // B 在 10:15 才首次同步：拉到的远端提交要带上 A 的设备标识与 A 的提交时间，
    // 而不是 B 应用这条提交的时刻。
    clock.advance(const Duration(minutes: 10));
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();

    final remoteRow = await commitRow(b.rig, action: '新增记忆');
    expect(remoteRow['origin_device'], 'device-a');
    expect(remoteRow['authored_at'], '2026-11-17 10:05:00');
    expect(remoteRow['created_at'], '2026-11-17 10:15:00');
    expect(remoteRow['kind'], RevisionKind.write.value);

    final remote = RevisionCommit.fromRow(remoteRow);
    expect(remote.originDevice, 'device-a');
    expect(remote.isRemote, isTrue);
    expect(remote.authoredAt, DateTime(2026, 11, 17, 10, 5));
    expect(remote.createdAt, DateTime(2026, 11, 17, 10, 15));
  });
}
