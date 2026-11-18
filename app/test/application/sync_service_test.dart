import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/application/sync_service.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';

import '../support/fake_server.dart';
import '../support/test_db.dart';

DateTime _fixedClock() => DateTime(2026, 11, 17, 10);

/// 一台设备：本机库、账号服务与同步服务。
class _Device {
  _Device({
    required this.rig,
    required this.account,
    required this.sync,
    required this.dir,
  });

  final TestRig rig;
  final AccountService account;
  final SyncService sync;
  final Directory dir;

  Future<void> close() async {
    sync.dispose();
    account.dispose();
    await rig.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

Future<_Device> _openDevice(
  FakeServer server, {
  required String email,
  required String password,
  required bool register,
}) async {
  final rig = await openTestRig(clock: _fixedClock);
  final dir = await Directory.systemTemp.createTemp('zhixin_sync_test');
  final preferences = CloudPreferencesStore(filesDir: dir.path);
  final account = AccountService(
    store: AccountStore(MemorySecretStore()),
    preferences: preferences,
    now: _fixedClock,
    clientFactory: (baseUrl) =>
        ServerClient(baseUrl: baseUrl, httpClient: server.client),
  );
  await account.setServerBaseUrl('http://server.test');
  if (register) {
    await account.register(email: email, password: password);
  } else {
    await account.login(email: email, password: password);
  }
  final sync = SyncService(
    account: account,
    preferences: preferences,
    revisions: rig.revisions,
    engine: rig.engine,
    database: rig.db,
    transactions: WriteTransactions(rig.db),
    assets: rig.engine.assets,
    cache: AttachmentCache(filesDir: () => dir.path),
    clock: _fixedClock,
    recordFailure: (error, stack, {required kind}) {},
  );
  return _Device(rig: rig, account: account, sync: sync, dir: dir);
}

Future<void> _insertMemory(TestRig rig, String id, String content) {
  return rig.db.command((txn) async {
    await insertRow(txn, 'memory', {
      'id': id,
      'kind': 'preference',
      'content': content,
      'scope': null,
      'source_kind': 'user',
      'source_id': null,
      'valid_until': null,
      'status': 'active',
      'created_at': '2026-11-17 10:00:00',
      'updated_at': '2026-11-17 10:00:00',
    });
  }, label: '新增记忆');
}

Future<List<Map<String, Object?>>> _memories(TestRig rig) =>
    rig.raw.rawQuery('SELECT id, content FROM memory ORDER BY id');

void main() {
  late FakeServer server;
  final devices = <_Device>[];

  setUp(() {
    server = FakeServer();
    devices.clear();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
  });

  Future<_Device> device(String email, {bool register = false}) async {
    final opened = await _openDevice(
      server,
      email: email,
      password: 'password123',
      register: register,
    );
    devices.add(opened);
    return opened;
  }

  test('首次同步上传当前数据为基线，另一台设备拉取后得到同一条记录', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow();

    final userId = (await a.account.snapshot()).session!.userId;
    expect(server.headOf(userId), 1);
    final baseline = server.commits[userId]!.single;
    expect(baseline['action'], '首次同步基线');
    final changes = baseline['changes']! as List;
    expect(
      changes.map((change) => (change as Map)['table']),
      contains('memory'),
    );

    final b = await device('a@example.com');
    await b.sync.syncNow();
    final rows = await _memories(b.rig);
    expect(rows.map((row) => row['content']), contains('喜欢先看例子'));
    final history = await b.rig.revisions.history();
    expect(history.commits.length, greaterThanOrEqualTo(2));
  });

  test('之后的本机写入按提交推送，另一台设备拉取后看到新记录与附件', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow();

    final b = await device('a@example.com');
    await b.sync.syncNow();
    expect((await _memories(b.rig)), hasLength(1));

    final bytes = [9, 8, 7, 6, 5];
    final hash = AssetStore.hashBytes(bytes);
    await a.rig.db.command((txn) async {
      await a.rig.engine.assets.putBytes(txn, hash, Uint8List.fromList(bytes));
    }, label: '保存附件');
    await _insertMemory(a.rig, 'm2', hash);
    final pushed = await a.sync.syncNow();
    expect(pushed.pushedCommits, greaterThanOrEqualTo(1));
    expect(pushed.uploadedAssets, 1);

    final pulled = await b.sync.syncNow();
    expect(pulled.pulledCommits, greaterThanOrEqualTo(1));
    expect(pulled.downloadedAssets, 1);
    final rows = await _memories(b.rig);
    expect(rows.map((row) => row['content']), contains(hash));
    final bytesOnB = await b.rig.engine.assets.readBytes(b.rig.raw, hash);
    expect(bytesOnB, bytes);
  });

  test('服务端序列被清空之后重新上传基线', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;
    expect(server.headOf(userId), 1);

    await a.account.clearCloudData();
    await a.sync.clearState();
    await a.sync.syncNow();
    // 清除云端数据之后服务端位置回到 0，同步重新上传了一份基线。
    expect(server.headOf(userId), 1);
    final last = server.commits[userId]!.last;
    expect(last['action'], '首次同步基线');
  });

  test('换实例重新登录后不复用旧同步游标，自动同步先暂停', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow();
    expect((await a.sync.status()).serverHead, isNotNull);

    await a.account.setServerBaseUrl('http://other.test');
    final snapshot = await a.account.login(
      email: 'a@example.com',
      password: 'password123',
    );
    expect(snapshot.signedIn, isTrue);
    expect(snapshot.autoSync, isFalse);
    expect(await a.account.preferences.syncState(), isNull);
    final status = await a.sync.status();
    expect(status.serverHead, isNull);
    expect(status.needsBootstrap, isTrue);
  });
}
