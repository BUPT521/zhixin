import 'dart:async';
import 'dart:convert';
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
import 'package:zhixin/data/revisions/revision_models.dart';

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
  String? deviceId,
}) async {
  final rig = await openTestRig(clock: _fixedClock);
  final dir = await Directory.systemTemp.createTemp('zhixin_sync_test');
  final preferences = CloudPreferencesStore(filesDir: dir.path);
  final account = AccountService(
    store: AccountStore(
      MemorySecretStore(
        deviceId == null ? null : {AccountStore.deviceIdKey: deviceId},
      ),
    ),
    preferences: preferences,
    now: _fixedClock,
    clientFactory: (baseUrl) =>
        ServerClient(baseUrl: baseUrl, httpClient: server.client),
  );
  await account.setServerBaseUrl('http://server.test');
  if (register) {
    await account.register(identifier: email, password: password);
  } else {
    await account.login(identifier: email, password: password);
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
    clock: _fixedClock,
    recordFailure: (error, stack, {required kind}) {},
  );
  return _Device(rig: rig, account: account, sync: sync, dir: dir);
}

Future<void> _updateMemory(TestRig rig, String id, String content) {
  return rig.db.command((txn) async {
    await updateRow(
      txn,
      'memory',
      {'content': content, 'updated_at': '2026-11-17 10:05:00'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }, label: '修改记忆');
}

Future<String?> _memoryContent(TestRig rig, String id) async {
  final rows = await selectRows(
    rig.raw,
    'memory',
    columns: ['content'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['content'] as String?;
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

  Future<_Device> device(
    String email, {
    bool register = false,
    String? deviceId,
  }) async {
    final opened = await _openDevice(
      server,
      email: email,
      password: 'password123',
      register: register,
      deviceId: deviceId,
    );
    devices.add(opened);
    return opened;
  }

  test('首次同步上传当前数据为基线，另一台设备拉取后得到同一条记录', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);

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
    await a.sync.syncNow(confirmBaseline: true);

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
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;
    expect(server.headOf(userId), 1);

    await a.account.clearCloudData(password: 'password1');
    await a.sync.clearState();
    await a.sync.syncNow(confirmBaseline: true);
    // 清除云端数据之后服务端位置回到 0，同步重新上传了一份基线。
    expect(server.headOf(userId), 1);
    final last = server.commits[userId]!.last;
    expect(last['action'], '首次同步基线');
  });

  test('换实例重新登录后不复用旧同步游标，自动同步先暂停', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    expect((await a.sync.status()).serverHead, isNotNull);

    await a.account.setServerBaseUrl('http://other.test');
    final snapshot = await a.account.login(
      identifier: 'a@example.com',
      password: 'password123',
    );
    expect(snapshot.signedIn, isTrue);
    expect(snapshot.autoSync, isFalse);
    expect(await a.account.preferences.syncState(), isNull);
    final status = await a.sync.status();
    expect(status.serverHead, isNull);
    expect(status.needsBootstrap, isTrue);
  });

  test('首次基线上传前必须确认，未确认时不向服务端写任何记录', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    final userId = (await a.account.snapshot()).session!.userId;

    await expectLater(
      a.sync.syncNow(),
      throwsA(
        isA<BaselineConfirmationRequired>().having(
          (error) => error.localCommits,
          'localCommits',
          1,
        ),
      ),
    );
    expect(server.headOf(userId), 0);
    final status = await a.sync.status();
    expect(status.baselineNeedsConfirmation, isTrue);
    expect(status.needsBootstrap, isTrue);

    await a.sync.syncNow(confirmBaseline: true);
    expect(server.headOf(userId), 1);
    final after = await a.sync.status();
    expect(after.baselineNeedsConfirmation, isFalse);
    expect(after.serverHead, 1);
  });

  test('账号附件总量超限时停止上传，游标不写回', () async {
    server.storageLimitBytes = 2;
    final a = await device('a@example.com', register: true);
    final first = [1, 2, 3];
    final second = [4, 5, 6];
    final firstHash = AssetStore.hashBytes(first);
    final secondHash = AssetStore.hashBytes(second);
    await a.rig.db.command((txn) async {
      await a.rig.engine.assets.putBytes(
        txn,
        firstHash,
        Uint8List.fromList(first),
      );
      await a.rig.engine.assets.putBytes(
        txn,
        secondHash,
        Uint8List.fromList(second),
      );
    }, label: '保存附件');
    await _insertMemory(a.rig, 'm1', firstHash);
    await _insertMemory(a.rig, 'm2', secondHash);

    await expectLater(
      a.sync.syncNow(confirmBaseline: true),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.code, 'code', 'storage_full')
            .having(
              (error) => error.userMessage,
              'message',
              contains('云端附件空间已满'),
            ),
      ),
    );
    // 第一个附件超限之后不再尝试后面的附件，也没有写回同步游标。
    expect(server.blobUploadAttempts, 1);
    expect(await a.account.preferences.syncState(), isNull);
  });

  test('上传途中切换实例，进行中的同步结果被丢弃', () async {
    final a = await device('a@example.com', register: true);
    final bytes = [1, 2, 3];
    final hash = AssetStore.hashBytes(bytes);
    await a.rig.db.command((txn) async {
      await a.rig.engine.assets.putBytes(txn, hash, Uint8List.fromList(bytes));
    }, label: '保存附件');
    await _insertMemory(a.rig, 'm1', hash);

    final gate = Completer<void>();
    server.delayBlobUpload = gate.future;
    final pending = a.sync.syncNow(confirmBaseline: true);
    while (server.blobUploadAttempts == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    // 附件已经发到旧实例，但同步还没收尾；这时切走，旧结果不能写回。
    await a.account.setServerBaseUrl('http://other.test');
    gate.complete();

    await expectLater(pending, throwsA(isA<SyncIdentityChanged>()));
    expect(await a.account.preferences.syncState(), isNull);
  });

  test('推送的 request_id 不超过服务端 64 字符上限，超长时按提交编号生成', () {
    // 更正材料页这类命令把 JSON 编码的请求标识写进提交，长度会超过 64。
    final long = jsonEncode([
      'correct-material-page',
      '01a1f4d1-78ae-7000-befb-f35f122c1838',
      '',
      '方阵的迹为主对角元素之和。',
    ]);
    expect(long.length, greaterThan(64));

    final first = syncRequestIdFor(
      stored: long,
      deviceId: '3B164M00XU700000',
      commitId: 41,
    );
    expect(first, 'l-3B164M00-41');
    expect(first.length, lessThanOrEqualTo(64));
    // 同一提交重试时标识不变，服务端仍能按请求标识去重。
    expect(
      syncRequestIdFor(
        stored: long,
        deviceId: '3B164M00XU700000',
        commitId: 41,
      ),
      first,
    );
    expect(
      syncRequestIdFor(
        stored: 'l-3B164M00-7',
        deviceId: '3B164M00XU700000',
        commitId: 7,
      ),
      'l-3B164M00-7',
    );
    expect(
      syncRequestIdFor(
        stored: '   ',
        deviceId: '3B164M00XU700000',
        commitId: 7,
      ),
      'l-3B164M00-7',
    );

    // 服务端按 UTF-8 字节算长度：这条中文标识只有 46 个字符，却有 70 个字节。
    final chinese = jsonEncode([
      'add-memory',
      'preference',
      '只能在上午学习，晚上效率低',
      '',
    ]);
    expect(chinese.length, lessThanOrEqualTo(64));
    expect(utf8.encode(chinese).length, greaterThan(64));
    expect(
      syncRequestIdFor(
        stored: chinese,
        deviceId: '3B164M00XU700000',
        commitId: 31,
      ),
      'l-3B164M00-31',
    );
  });

  test('同步位置写进库里的读取位置，偏好文件只留账号与实例', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;

    final rows = await a.rig.raw.rawQuery(
      'SELECT name, position, blocking FROM revision_cursor ORDER BY name',
    );
    final byName = {for (final row in rows) row['name']! as String: row};
    expect(
      byName.keys,
      containsAll([RevisionCursor.syncPushed, RevisionCursor.syncServerHead]),
    );
    // 推送会丢数据：没有推完的位置阻止裁剪与清理历史。
    expect(byName[RevisionCursor.syncPushed]!['blocking'], 1);
    expect(
      byName[RevisionCursor.syncPushed]!['position'],
      await a.rig.engine.headId(a.rig.raw),
    );
    // 服务端位置只登记，不阻塞裁剪。
    expect(byName[RevisionCursor.syncServerHead]!['blocking'], 0);
    expect(
      byName[RevisionCursor.syncServerHead]!['position'],
      server.headOf(userId),
    );
    expect((await a.sync.status()).serverHead, server.headOf(userId));

    // 同步位置不再写进偏好文件，只留账号与实例的标识。
    final file = File(CloudPreferencesStore(filesDir: a.dir.path).path);
    final raw = await file.readAsString();
    expect(raw, isNot(contains('pushed_through')));
    expect(raw, isNot(contains('remote_local_ids')));
    expect(raw, isNot(contains('server_head')));
    final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
    final state = (decoded['sync_state']! as Map).cast<String, Object?>();
    expect(state['user_id'], userId);
    expect(state['server_origin'], 'http://server.test');
    expect(state['synced_at'], isNotNull);
  });

  test('拉下来的远端提交不会再推回服务端，同步两轮提交数不变', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;

    final b = await device('a@example.com');
    await b.sync.syncNow();
    final afterBootstrap = server.headOf(userId);

    // 设备 A 再写一条并推送；设备 B 拉取时把它应用为一条 remote 提交。
    await _insertMemory(a.rig, 'm2', '晚上效率低');
    await a.sync.syncNow();
    final afterPush = server.headOf(userId);
    expect(afterPush, greaterThan(afterBootstrap));

    final pulled = await b.sync.syncNow();
    expect(pulled.pulledCommits, greaterThanOrEqualTo(1));
    expect(pulled.pushedCommits, 0);
    expect(server.headOf(userId), afterPush);

    // 再同步一轮：本机没有新写入，服务端提交数不变。
    final again = await b.sync.syncNow();
    expect(again.pushedCommits, 0);
    expect(server.headOf(userId), afterPush);
    final kinds = await b.rig.engine.commitsAfter(b.rig.raw, 0);
    expect(kinds.map((commit) => commit.kind), contains(RevisionKind.remote));
  });
  test('两台设备改同一行时列出被覆盖的本机修改，保留本机修改写回并推到另一台', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);

    final b = await device('a@example.com');
    await b.sync.syncNow();
    await _updateMemory(b.rig, 'm1', '先看例子再看定义');
    await b.sync.syncNow();

    // A 在本机改过一次、还没有推送，拉取时后到的远端值覆盖了这一次修改。
    await _updateMemory(a.rig, 'm1', '本机偏好：先自己做');
    await a.sync.syncNow();

    final conflicts = await a.rig.revisions.conflicts();
    expect(conflicts, hasLength(1));
    final conflict = conflicts.single;
    expect(conflict.table, 'memory');
    expect(conflict.rowKey, 'm1');
    expect(conflict.column, 'content');
    expect(conflict.reason, RevisionConflict.concurrentUpdate);
    expect(conflict.local['content']!.value, '本机偏好：先自己做');
    expect(conflict.remoteAfter['content']!.value, '先看例子再看定义');
    expect(await _memoryContent(a.rig, 'm1'), '先看例子再看定义');

    final commit = await a.rig.revisions.keepLocal(conflict.id);
    expect(commit, isNotNull);
    expect(commit!.kind, RevisionKind.write);
    expect(commit.action, '保留本机修改');
    expect(await _memoryContent(a.rig, 'm1'), '本机偏好：先自己做');
    expect(await a.rig.revisions.conflicts(), isEmpty);

    // 写回的是一条普通提交，推送之后另一台设备看到的是这个值。
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(await _memoryContent(b.rig, 'm1'), '本机偏好：先自己做');
  });
  test('拉取之后不把被远端覆盖的本机旧提交推回服务端', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);

    // B 第一次同步会把自己拉到的数据再上传一份基线；A 先同步一次消化掉它，
    // 后面这一轮只比较两边各自改过的内容。
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();

    await _updateMemory(a.rig, 'm1', '本机偏好：先自己做');
    await _updateMemory(b.rig, 'm1', '先看例子再看定义');
    await b.sync.syncNow();

    // A 在拉取之前也改过这一行：拉取把本机值覆盖成 B 的值，这条本机提交
    // 不能再推回去，否则服务端会被旧值覆盖，两台设备从此不一致。
    await a.sync.syncNow();
    expect(await _memoryContent(a.rig, 'm1'), '先看例子再看定义');
    final conflict = (await a.rig.revisions.conflicts()).singleWhere(
      (item) =>
          item.reason == RevisionConflict.concurrentUpdate &&
          item.column == 'content',
    );
    expect(conflict.local['content']!.value, '本机偏好：先自己做');
    expect(conflict.remoteAfter['content']!.value, '先看例子再看定义');

    // 另一台设备看到的仍是自己的值，说明 A 的旧提交没有被推上去。
    await b.sync.syncNow();
    expect(await _memoryContent(b.rig, 'm1'), '先看例子再看定义');
  });
}
