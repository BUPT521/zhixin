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
import 'package:zhixin/domain/models/server_models.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/domain/models/revision_models.dart';
import 'package:zhixin/domain/rules/uuid_v7.dart';

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
      'kind': 'semantic',
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

/// 附件引用只认表结构里声明的列（审查 S17）：用材料行的文件哈希引用附件，
/// 不再把哈希写进记忆正文。
Future<void> _insertMaterialWithFile(TestRig rig, String id, String hash) {
  return rig.db.command((txn) async {
    await insertRow(txn, 'material', {
      'id': id,
      'title': '带附件的材料',
      'kind': 'text',
      'source_file_name': '$id.png',
      'source_file_hash': hash,
      'created_at': '2026-11-17 10:00:00',
      'updated_at': '2026-11-17 10:00:00',
    });
  }, label: '保存材料');
}

Future<String?> _materialFileHash(TestRig rig, String id) async {
  final rows = await selectRows(
    rig.raw,
    'material',
    columns: ['source_file_hash'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['source_file_hash'] as String?;
}

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

  test('新设备首次同步只拉取、不上传基线，服务端序列长度不变', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    final bytes = [4, 4, 4, 2];
    final hash = AssetStore.hashBytes(bytes);
    await a.rig.db.command((txn) async {
      await a.rig.engine.assets.putBytes(txn, hash, Uint8List.fromList(bytes));
    }, label: '保存附件');
    await _insertMemory(a.rig, 'm1', '带附件的讲义');
    await _insertMaterialWithFile(a.rig, 'mat1', hash);
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;
    final headAfterA = server.headOf(userId);
    expect(headAfterA, greaterThan(0));
    expect(server.blobs[userId]!.keys, contains(hash));
    final uploadsBefore = server.blobUploadAttempts;

    // B 是本机投影为空的新设备：拉完之后本机每一行都由远端提交表达，一条基线
    // 也不产生，服务端序列长度、附件与推送次数都不变，和 `git clone` 一样。
    final b = await device('a@example.com', deviceId: 'device-b');
    final result = await b.sync.syncNow();
    expect(result.pulledCommits, greaterThanOrEqualTo(1));
    expect(result.pushedCommits, 0);
    expect(result.uploadedAssets, 0);
    expect(result.downloadedAssets, 1);
    expect(
      server.headOf(userId),
      headAfterA,
      reason:
          '新设备首次同步不该上传基线：服务端现在有 ${server.headOf(userId)} 条，'
          '期望 $headAfterA 条',
    );
    expect(server.blobUploadAttempts, uploadsBefore, reason: '拉到的附件不该再传一遍');
    expect(await _memoryContent(b.rig, 'm1'), '带附件的讲义');
    expect(await _materialFileHash(b.rig, 'mat1'), hash);
    final bytesOnB = await b.rig.engine.assets.readBytes(b.rig.raw, hash);
    expect(bytesOnB, bytes);

    // 第二轮同步同样没有可推的东西：拉下来的远端提交不会再传回去。
    final again = await b.sync.syncNow();
    expect(again.pushedCommits, 0);
    expect(server.headOf(userId), headAfterA);
  });

  test('已有本地数据的设备首次同步只上传本机独有的行', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await _insertMemory(a.rig, 'm1', 'A 先有的记录');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;
    final headAfterA = server.headOf(userId);

    // B 在首次同步之前已经有一条自己的记录，还有一条带附件：两条都是本机独有
    // 的数据；服务端已有的 m1 与 profile 行不进基线。
    final b = await device('a@example.com', deviceId: 'device-b');
    await _insertMemory(b.rig, 'm2', 'B 先有的记录');
    final bytes = [7, 5, 3, 1];
    final hash = AssetStore.hashBytes(bytes);
    await b.rig.db.command((txn) async {
      await b.rig.engine.assets.putBytes(txn, hash, Uint8List.fromList(bytes));
    }, label: '保存附件');
    await _insertMaterialWithFile(b.rig, 'mat-b', hash);
    await expectLater(
      b.sync.syncNow(),
      throwsA(isA<BaselineConfirmationRequired>()),
      reason: '本机有记录、账号还没同步过时仍然要先确认一次',
    );
    expect(server.headOf(userId), headAfterA, reason: '确认之前不向服务端写任何记录');

    final result = await b.sync.syncNow(confirmBaseline: true);
    expect(result.pulledCommits, greaterThanOrEqualTo(1));
    expect(result.pushedCommits, 1);
    expect(result.uploadedAssets, 1);
    expect(server.headOf(userId), headAfterA + 1);
    final baseline = server.commits[userId]!.last;
    expect(baseline['action'], '首次同步基线');
    final changes = baseline['changes']! as List;
    expect(
      [
        for (final change in changes)
          '${(change as Map)['table']}/${change['row_key']}',
      ],
      ['material/mat-b', 'memory/m2'],
      reason: '服务端已有的 m1 与 profile 行不该重复上传：$changes',
    );
    expect(server.blobs[userId]!.keys, contains(hash), reason: '本机独有行的附件要跟着上传');

    // 两边互相拿到对方的记录；B 的第二轮同步没有可推的东西。
    await a.sync.syncNow();
    expect(await _memoryContent(a.rig, 'm2'), 'B 先有的记录');
    expect(await _materialFileHash(a.rig, 'mat-b'), hash);
    expect(await _memoryContent(b.rig, 'm1'), 'A 先有的记录');
    final again = await b.sync.syncNow();
    expect(again.pushedCommits, 0);
    expect(server.headOf(userId), headAfterA + 1);
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
    await _insertMaterialWithFile(a.rig, 'mat1', hash);
    final pushed = await a.sync.syncNow();
    expect(pushed.pushedCommits, greaterThanOrEqualTo(1));
    expect(pushed.uploadedAssets, 1);

    final pulled = await b.sync.syncNow();
    expect(pulled.pulledCommits, greaterThanOrEqualTo(1));
    expect(pulled.downloadedAssets, 1);
    expect(await _materialFileHash(b.rig, 'mat1'), hash);
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

  test('换实例重新登录后自动同步先暂停，同步位置只看库里还在不在', () async {
    final a = await device('a@example.com', register: true);
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    expect((await a.sync.status()).serverHead, isNotNull);
    final positionBefore = await a.rig.raw
        .rawQuery('SELECT position FROM revision_cursor WHERE name = ?', [
          RevisionCursor.syncPushed,
        ])
        .then((rows) => rows.single['position']);

    await a.account.setServerBaseUrl('http://other.test');
    final snapshot = await a.account.login(
      identifier: 'a@example.com',
      password: 'password123',
    );
    expect(snapshot.signedIn, isTrue);
    expect(snapshot.autoSync, isFalse);
    expect(await a.account.preferences.syncState(), isNull);
    final status = await a.sync.status();
    // 游标不再带账号与实例的 scope：本机空间标识只用于名册与诊断，同步位置
    // 只看库里还在不在（ADR-0056 第 9 条）。换实例之后的这一轮因此仍从原位置
    // 继续，不再有“位置属于别的实例就把下一次当基线”的分支。
    expect(
      await a.rig.raw
          .rawQuery('SELECT position FROM revision_cursor WHERE name = ?', [
            RevisionCursor.syncPushed,
          ])
          .then((rows) => rows.single['position']),
      positionBefore,
    );
    expect(status.needsBootstrap, isFalse);
    expect(status.serverHead, isNotNull);
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
    await _insertMaterialWithFile(a.rig, 'mat1', firstHash);
    await _insertMaterialWithFile(a.rig, 'mat2', secondHash);

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
    await _insertMaterialWithFile(a.rig, 'mat1', hash);

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

  test('推送填提交的 uid：参数再长也不影响推送，重复推送按 uid 去重', () async {
    final a = await device('a@example.com', register: true);
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;
    // 首次同步已经上传了本机投影作为基线。
    final baselineHead = server.headOf(userId);

    // 以前按动作参数派生的请求编号（JSON 编码的“动作 + 参数”原文）会把整条
    // 参数写进提交身份，按 UTF-8 可能超过服务端的 64 字节上限。现在提交身份由
    // 界面在动作开始时生成 UUIDv7，参数再长也只影响动作说明与行内容。
    final long = jsonEncode([
      'correct-material-page',
      '01a1f4d1-78ae-7000-befb-f35f122c1838',
      '',
      '方阵的迹为主对角元素之和。',
    ]);
    expect(utf8.encode(long).length, greaterThan(64));
    final uid = newUuidV7();
    final outcome = await a.rig.db.commandOutcome(
      (txn) => insertRow(txn, 'memory', {
        'id': 'm1',
        'kind': 'semantic',
        'content': '长参数的写入：$long',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-17 10:00:00',
        'updated_at': '2026-11-17 10:00:00',
      }),
      label: '更正材料页',
      uid: uid,
    );
    final commit = outcome.commit!;
    expect(commit.uid, uid);
    expect(commit.uid, hasLength(36));
    expect(utf8.encode(commit.uid).length, lessThanOrEqualTo(64));

    await a.sync.syncNow();
    expect(server.headOf(userId), baselineHead + 1);
    final pushed = server.commits[userId]!.last;
    expect(pushed['uid'], commit.uid);
    expect(utf8.encode(pushed['uid']! as String).length, lessThanOrEqualTo(64));

    // 服务端已经见过这条 uid：同一条提交再推一次不增加序列长度。
    await a.sync.syncNow();
    expect(server.headOf(userId), baselineHead + 1);
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

  test('同步位置不再带 scope：退出登录只解除阻塞，位置保留', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;
    // 本机空间标识仍由 syncScopeFor 给出，服务端名册与诊断用它；游标本身只记
    // 位置，一个库只属于一个账号与实例，不再按 scope 区分（ADR-0056 第 9 条）。
    expect(syncScopeFor(userId, 'http://server.test'), isNotEmpty);

    Future<Map<String, Map<String, Object?>>> cursors() async {
      final rows = await selectRows(a.rig.raw, 'revision_cursor');
      return {for (final row in rows) row['name']! as String: row};
    }

    final before = await cursors();
    expect(
      before[RevisionCursor.syncPushed]!.containsKey('scope'),
      isFalse,
      reason: '游标表没有 scope 列',
    );
    final pushedPosition = before[RevisionCursor.syncPushed]!['position'];
    expect(before[RevisionCursor.syncPushed]!['blocking'], 1);
    expect(before.containsKey(RevisionCursor.syncServerHead), isTrue);

    // 退出登录只把推送位置改成不阻塞：位置留着，重新登录同一账号时从原位置
    // 继续增量同步（同步方案 3.3）。
    await a.account.logout();
    await a.sync.clearState();
    final after = await cursors();
    expect(after[RevisionCursor.syncPushed]!['blocking'], 0);
    expect(after[RevisionCursor.syncPushed]!['position'], pushedPosition);
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
    expect(
      kinds.where((commit) => commit.isRemote).map((commit) => commit.kind),
      contains(RevisionKind.write),
    );
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

    // B 首次同步只拉取、不上传基线；A 再同步一次把两边的服务端位置归一，
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

  test('拉取把被覆盖的格子写进 sync_shadow，推送失败不丢，推完清掉', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await _insertMemory(a.rig, 'm1', '喜欢先看例子');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;

    await _updateMemory(b.rig, 'm1', '先看例子再看定义');
    await b.sync.syncNow();

    // A 在拉取之前也改过这一行：拉取会把本机值覆盖成 B 的值，这条本机提交的
    // 格子要登记成遮蔽行。另加一条不受覆盖的写入，这一轮才会真的发推送请求。
    await _updateMemory(a.rig, 'm1', '本机偏好：先自己做');
    await _insertMemory(a.rig, 'm2', 'A 新增的一行');
    final headBeforePull = await a.rig.engine.headId(a.rig.raw);
    final headBeforeServer = server.headOf(userId);

    server.pushFailures = 1;
    await expectLater(
      a.sync.syncNow(),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'unavailable',
        ),
      ),
      reason: '准备阶段：这一轮应当拉取成功、推送失败',
    );

    // 遮蔽行在应用远端提交的事务里落库，推送失败之后仍然在，`upto_commit` 是
    // 拉取之前的本机 HEAD：编号不大于它的本机提交在这些格子上作废。
    final shadows = await selectRows(a.rig.raw, 'sync_shadow');
    expect(
      [
        for (final row in shadows)
          '${row['table_name']}/${row['row_key']}/${row['column_name']}',
      ],
      containsAll(['memory/m1/content', 'memory/m1/updated_at']),
      reason: '拉取应用远端提交时应当把它写进本机的格子登记下来：$shadows',
    );
    for (final row in shadows) {
      expect(
        row['upto_commit'],
        headBeforePull,
        reason: '遮蔽行的 upto_commit 取应用远端提交之前的本机 HEAD',
      );
    }
    expect(server.headOf(userId), headBeforeServer, reason: '准备阶段：推送失败时序列没有前进');

    // 下一轮同步：被覆盖的格子不再推，只推剩下的那条新增；推送位置越过之后
    // 遮蔽行删掉。
    final next = await a.sync.syncNow();
    expect(next.pushedCommits, 1, reason: '只有不受遮蔽的那条提交需要推送');
    expect(
      await selectRows(a.rig.raw, 'sync_shadow'),
      isEmpty,
      reason: '推送位置越过 upto_commit 之后遮蔽行应当删掉',
    );
    final pushed = server.commits[userId]!.last['changes']! as List;
    expect(
      [for (final change in pushed) (change as Map)['row_key']],
      ['m2'],
      reason: '被遮蔽的 m1 不能再推回服务端，剩下的 m2 照常推',
    );

    await b.sync.syncNow();
    expect(
      await _memoryContent(b.rig, 'm1'),
      '先看例子再看定义',
      reason: '被远端覆盖的旧值不应该在下一轮又被推上去',
    );
    expect(await _memoryContent(b.rig, 'm2'), 'A 新增的一行');
  });

  test('一条提交同时改两行时，被遮蔽的行去掉、剩下的行照常推送', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await _insertMemory(a.rig, 'm1', '第一条');
    await _insertMemory(a.rig, 'm2', '第二条');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();
    final userId = (await a.account.snapshot()).session!.userId;

    await _updateMemory(b.rig, 'm1', 'B 的新内容');
    await b.sync.syncNow();

    // A 一条提交同时改两行：m1 会被远端提交覆盖，m2 只有本机改过。
    await a.rig.db.command((txn) async {
      await updateRow(
        txn,
        'memory',
        {'content': 'A 改的 m1', 'updated_at': '2026-11-17 10:06:00'},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      await updateRow(
        txn,
        'memory',
        {'content': 'A 改的 m2', 'updated_at': '2026-11-17 10:06:00'},
        where: 'id = ?',
        whereArgs: ['m2'],
      );
    }, label: '一次改两条记忆');

    await a.sync.syncNow();

    // 推上去的是按格变基之后的剩余部分：只有 m2 那一行，m1 的格子已经被远端
    // 覆盖，不再推。
    final changes = server.commits[userId]!.last['changes']! as List;
    expect(changes, hasLength(1), reason: '一条提交只推剩下的那一行');
    final change = changes.single as Map;
    expect(change['row_key'], 'm2');
    final after = change['after']! as Map;
    expect((after['content']! as Map)['v'], 'A 改的 m2');

    await b.sync.syncNow();
    expect(await _memoryContent(b.rig, 'm2'), 'A 改的 m2');
    expect(await _memoryContent(b.rig, 'm1'), 'B 的新内容');
    expect(await _memoryContent(a.rig, 'm1'), 'B 的新内容');
  });
}
