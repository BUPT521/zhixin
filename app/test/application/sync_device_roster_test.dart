// ADR-0048 的客户端侧验收用例：设备名册、同步请求头与别名。
//
// 服务端一侧另有用例；这里只核对客户端按契约发什么、缓存什么、改名之后怎么更新：
// - 四个同步请求都带 X-Device-Id 与 X-Sync-Capabilities: snapshot；
// - 一轮同步成功之后拉一次名册，缓存在同步服务里；
// - 别名查询按设备标识取，没有别名时为空；
// - 改名成功之后缓存用服务端返回的对象更新，未知设备按 404 not_found 抛出；
// - 名册读取失败只记一条诊断，不影响这一轮同步的结果。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/domain/models/server_models.dart';

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

  /// 名册按最近出现时间倒序：相邻两项的时间不递增。
  void expectRecentFirst(List<SyncRosterDevice> roster) {
    for (var index = 1; index < roster.length; index++) {
      final previous = roster[index - 1].lastSeen;
      final current = roster[index].lastSeen;
      if (previous == null || current == null) continue;
      expect(
        previous.isBefore(current),
        isFalse,
        reason: '第 $index 台设备比前一台更近：$roster',
      );
    }
  }

  test('同步请求带设备标识与能力声明，同步成功之后缓存名册', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-local-1',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);

    // 这一轮同步发过四个请求，带的是同一个设备标识与 snapshot 能力。
    final paths = {for (final entry in server.syncDeviceHeaders) entry.path};
    expect(paths, containsAll(['/v1/sync/head', '/v1/sync/commits']));
    expect(paths, contains('/v1/sync/snapshot'));
    expect(
      server.syncDeviceHeaders.where((entry) => entry.method == 'POST'),
      isNotEmpty,
      reason: '这一轮有本机记录要作为基线推送',
    );
    for (final entry in server.syncDeviceHeaders) {
      expect(entry.deviceId, 'device-local-1', reason: entry.path);
      expect(entry.capabilities, ['snapshot'], reason: entry.path);
    }

    // 服务端按头把设备写进名册；客户端同步之后读回了这一份。
    expect(server.rosterOf(userId).single.deviceId, 'device-local-1');
    expect(server.rosterOf(userId).single.capabilities, ['snapshot']);
    expect(a.sync.devices, hasLength(1));
    expect(a.sync.devices.single.deviceId, 'device-local-1');
    expect(a.sync.devices.single.lastSeen, isNotNull);
    expect(a.sync.deviceAlias('device-local-1'), isNull, reason: '还没有设置别名');
    expect(a.sync.deviceAlias('device-unknown'), isNull);

    // 另一台设备同步之后，A 拉一次名册就能看到它，仍然没有别名。
    final b = await device('a@example.com', deviceId: 'device-local-2');
    await b.sync.syncNow();
    await a.sync.refreshDevices();
    expect(
      {for (final item in a.sync.devices) item.deviceId},
      {'device-local-1', 'device-local-2'},
    );
    expect(a.sync.deviceAlias('device-local-2'), isNull);
    expectRecentFirst(a.sync.devices);

    // 给另一台设备起个名字之后，A 再拉一次名册按别名查到它。
    await b.sync.renameDevice('device-local-2', '书房平板');
    await a.sync.refreshDevices();
    expect(a.sync.deviceAlias('device-local-2'), '书房平板');
    expect(
      a.sync.devices
          .firstWhere((item) => item.deviceId == 'device-local-2')
          .alias,
      '书房平板',
    );
    expect(failures, isEmpty, reason: '正常路径不写诊断：$failures');
  });

  test('改名成功之后更新缓存，未知设备返回 404 not_found', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-local-1',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = await userIdOf(a);
    final before = server.rosterOf(userId).single.lastSeen;

    // 首尾空白由客户端去掉，服务端保存去掉之后的 0–64 字符。
    await a.sync.renameDevice('device-local-1', '  小明的手机  ');
    expect(a.sync.deviceAlias('device-local-1'), '小明的手机');
    expect(a.sync.devices.single.alias, '小明的手机', reason: '改名返回的设备对象替换了缓存里这一台');
    expect(server.rosterOf(userId).single.alias, '小明的手机');
    expect(
      server.rosterOf(userId).single.lastSeen,
      before,
      reason: '改名不改变最近出现时间',
    );

    // 未知设备：服务端返回 404 not_found，缓存保持原样。
    await expectLater(
      a.sync.renameDevice('device-unknown', '别人的手机'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'not_found'),
      ),
    );
    expect(a.sync.deviceAlias('device-local-1'), '小明的手机');
    expect(a.sync.devices, hasLength(1), reason: '失败不往缓存里加设备');
    expect(a.sync.deviceAlias('device-unknown'), isNull);

    // 空串表示清除别名，列表里这一台回到“未命名设备”的显示。
    await a.sync.renameDevice('device-local-1', '');
    expect(a.sync.deviceAlias('device-local-1'), isNull);
    expect(a.sync.devices.single.alias, isEmpty);
    expect(server.rosterOf(userId).single.alias, isEmpty);
  });

  test('名册读取失败只记一条诊断，同步结果不受影响', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-local-1',
    );
    await insertTestMemory(a.rig, 'm1', content: '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    expect(failures, isEmpty);

    // 名册接口不可用：这一轮同步照常完成，只多一条诊断。
    server.deviceListFailures = 1;
    await insertTestMemory(a.rig, 'm2', content: '晚上效率低');
    final result = await a.sync.syncNow();
    expect(result.pushedCommits, 1);
    expect(
      failures.map((failure) => failure.kind),
      contains('cloud_sync_devices'),
    );
    expect(
      failures.where((failure) => failure.kind == 'cloud_sync_devices'),
      hasLength(1),
      reason: '一次读取失败只记一条诊断',
    );

    // 缓存保留上一次读到的内容，下一轮同步再补读。
    expect(a.sync.devices.single.deviceId, 'device-local-1');
    await a.sync.refreshDevices();
    expect(a.sync.devices.single.deviceId, 'device-local-1');
  });
}
