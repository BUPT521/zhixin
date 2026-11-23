import 'dart:io';

import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';

import 'fake_server.dart';
import 'test_db.dart';

/// 同步用例的密码与固定服务地址；两台设备登录同一个账号。
const String syncTestPassword = 'password123';

/// 同步用例的固定服务地址：账号、会话与同步状态都按这个实例来源归属。
const String syncTestServerUrl = 'http://server.test';

/// 一台设备：本机库、账号服务、同步服务与偏好目录。
class SyncDevice {
  SyncDevice({
    required this.rig,
    required this.account,
    required this.preferences,
    required this.sync,
    required this.dir,
    this.ownsDir = true,
  });

  final TestRig rig;
  final AccountService account;
  final CloudPreferencesStore preferences;
  final SyncService sync;
  final Directory dir;

  /// 偏好目录是不是这里新建的临时目录；用例自己传了目录时不删它。
  final bool ownsDir;

  Future<void> close() async {
    sync.dispose();
    account.dispose();
    await rig.close();
    if (ownsDir && await dir.exists()) await dir.delete(recursive: true);
  }
}

/// 在 [rig] 上开一台登录了 [email] 的设备。
///
/// 时钟由用例控制：[clock] 同时给版本引擎、账号服务与同步服务，提交时间、
/// 重试时效与同步收尾都取同一个时刻，用例因此可以按需推进分钟数。
///
/// [home] 是偏好、会话与附件的目录；整库恢复的用例把库换成文件库，偏好留在
/// 库外，恢复之后仍然有效，正是要复现的场景。
Future<SyncDevice> openSyncDevice(
  FakeServer server, {
  required TestRig rig,
  required String email,
  required bool register,
  required String deviceId,
  required TestClock clock,
  Directory? home,
  void Function(Object error, StackTrace stack, {required String kind})?
  recordFailure,
}) async {
  final dir =
      home ?? await Directory.systemTemp.createTemp('zhixin_sync_device');
  final preferences = CloudPreferencesStore(filesDir: dir.path);
  final account = AccountService(
    store: AccountStore(
      MemorySecretStore({AccountStore.deviceIdKey: deviceId}),
    ),
    preferences: preferences,
    now: clock.call,
    clientFactory: (baseUrl) =>
        ServerClient(baseUrl: baseUrl, httpClient: server.client),
  );
  await account.setServerBaseUrl(syncTestServerUrl);
  if (register) {
    await account.register(identifier: email, password: syncTestPassword);
  } else {
    await account.login(identifier: email, password: syncTestPassword);
  }
  final sync = SyncService(
    account: account,
    preferences: preferences,
    revisions: rig.revisions,
    engine: rig.engine,
    database: rig.db,
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
    assets: rig.engine.assets,
    cache: AttachmentCache(filesDir: () => dir.path),
    clock: clock.call,
    recordFailure: recordFailure ?? (error, stack, {required kind}) {},
  );
  return SyncDevice(
    rig: rig,
    account: account,
    preferences: preferences,
    sync: sync,
    dir: dir,
    ownsDir: home == null,
  );
}

/// 用例自己的时钟：起点固定，需要“过一会儿再操作”时显式推进。
///
/// 同步与数据版本里的“重试”判断按两分钟内的同一次动作处理；用例推进三分钟
/// 表示用户隔了一会儿重新点了一次，而不是网络回调或双击造成的重试。
class TestClock {
  TestClock([DateTime? start]) : now = start ?? DateTime(2026, 11, 17, 10);

  DateTime now;

  void advance(Duration duration) => now = now.add(duration);

  /// 交给 `openTestRig`、账号服务与同步服务的时钟函数。
  DateTime call() => now;
}

/// 在 [rig] 里插一条记忆；[timestamp] 同时写进创建与更新时间。
Future<void> insertTestMemory(
  TestRig rig,
  String id, {
  required String content,
  String kind = 'semantic',
  String status = 'active',
  String timestamp = '2026-11-17 10:00:00',
  String label = '新增记忆',
}) => rig.db.command((txn) async {
  await insertRow(txn, 'memory', {
    'id': id,
    'kind': kind,
    'content': content,
    'scope': null,
    'source_kind': 'user',
    'source_id': null,
    'valid_until': null,
    'status': status,
    'created_at': timestamp,
    'updated_at': timestamp,
  });
}, label: label);

/// 改一条记忆的若干列；测试自己给 `updated_at`，两边的时间先后才是确定的。
Future<void> updateTestMemory(
  TestRig rig,
  String id,
  Map<String, Object?> values, {
  String label = '修改记忆',
}) => rig.db.command((txn) async {
  await updateRow(txn, 'memory', values, where: 'id = ?', whereArgs: [id]);
}, label: label);

/// 读一条记忆的整行；不存在时为空。
Future<Map<String, Object?>?> testMemory(TestRig rig, String id) async {
  final rows = await selectRows(
    rig.raw,
    'memory',
    where: 'id = ?',
    whereArgs: [id],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.first;
}

/// 读全部记忆，按主键排序；整表比较时用它。
Future<List<Map<String, Object?>>> testMemories(TestRig rig) =>
    rig.raw.rawQuery('SELECT * FROM memory ORDER BY id');

/// 一条记忆的正文；行不存在时为空。
Future<Object?> testMemoryContent(TestRig rig, String id) async =>
    (await testMemory(rig, id))?['content'];

/// 服务端序列的动作清单，失败信息里用它说明这一轮有没有推上去。
///
/// 整条序列带上变更明细太长，失败输出里只留序号与动作，够看出多了哪一条。
String serverActions(FakeServer server, String userId) {
  final commits = server.commits[userId] ?? const [];
  return [for (final commit in commits) '#${commit['seq']} ${commit['action']}']
      .join('，');
}
