import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';

/// cloud.json 的读写：默认值、往返保存，以及两个动作同时改这份偏好时各自改的键
/// 都留在文件里。后一组用例盯的是并发写入：读改写之间没有排队时，后写的动作会
/// 覆盖先写的键，两次写入还会共用同一个临时文件，Windows 上 rename 会报找不到
/// 源文件。
void main() {
  late Directory directory;
  late CloudPreferencesStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-cloud-prefs-');
    store = CloudPreferencesStore(filesDir: directory.path);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('没有保存过时用默认地址、开启自动同步、没有同步状态', () async {
    expect(await store.storedServerBaseUrl(), isEmpty);
    expect(await store.usesDefaultServerBaseUrl(), isTrue);
    expect(await store.serverBaseUrl(), defaultServerBaseUrl);
    expect(await store.autoSync(), isTrue);
    expect(await store.lastIdentity(), isEmpty);
    expect(await store.syncState(), isNull);
  });

  test('地址按去掉首尾空白保存，清空之后回到默认地址', () async {
    await store.setServerBaseUrl('  https://example.com  ');
    expect(await store.storedServerBaseUrl(), 'https://example.com');
    expect(await store.usesDefaultServerBaseUrl(), isFalse);
    await store.setServerBaseUrl('   ');
    expect(await store.usesDefaultServerBaseUrl(), isTrue);
    expect(await store.serverBaseUrl(), defaultServerBaseUrl);
  });

  test('开关与上次登录身份保存之后读得出', () async {
    await store.setAutoSync(false);
    await store.setLastIdentity('https://example.com#user-1');
    expect(await store.autoSync(), isFalse);
    expect(await store.lastIdentity(), 'https://example.com#user-1');
  });

  test('同步状态带比对标记保存，清除之后为空', () async {
    final syncedAt = DateTime.utc(2026, 11, 21, 8, 30);
    await store.saveSyncState(
      SyncState(
        userId: 'user-1',
        serverOrigin: 'https://example.com',
        syncedAt: syncedAt,
        digestMismatch: true,
      ),
    );
    final state = await store.syncState();
    expect(state?.userId, 'user-1');
    expect(state?.serverOrigin, 'https://example.com');
    expect(state?.syncedAt, syncedAt);
    expect(state?.digestMismatch, isTrue);

    await store.clearSyncState();
    expect(await store.syncState(), isNull);
  });

  test('缺少账号或实例来源的同步状态按没有状态处理', () async {
    await File(store.path).parent.create(recursive: true);
    await File(store.path).writeAsString(
      jsonEncode({
        'sync_state': {'user_id': '', 'server_origin': 'https://example.com'},
      }),
    );
    expect(await store.syncState(), isNull);
  });

  test('同时改不同的键，各自改的键都写进文件', () async {
    await Future.wait([
      store.setAutoSync(false),
      store.setServerBaseUrl('https://example.com'),
      store.setLastIdentity('https://example.com#user-1'),
    ]);

    final raw = (jsonDecode(await File(store.path).readAsString()) as Map)
        .cast<String, Object?>();
    expect(raw['auto_sync'], isFalse);
    expect(raw['server_base_url'], 'https://example.com');
    expect(raw['last_identity'], 'https://example.com#user-1');
    expect(await File('${store.path}.partial').exists(), isFalse);
  });

  test('两个实例写同一个目录时也排进同一条队列', () async {
    final other = CloudPreferencesStore(filesDir: directory.path);
    await Future.wait([
      store.setAutoSync(false),
      other.setLastIdentity('https://example.com#user-1'),
    ]);

    expect(await store.autoSync(), isFalse);
    expect(await store.lastIdentity(), 'https://example.com#user-1');
  });

  test('同一个键并发改写按调用顺序生效，文件不被写坏', () async {
    await Future.wait([
      for (var i = 0; i < 8; i++) store.setLastIdentity('origin#user-$i'),
    ]);

    expect(await store.lastIdentity(), 'origin#user-7');
    expect(await store.autoSync(), isTrue);
    final raw = (jsonDecode(await File(store.path).readAsString()) as Map)
        .cast<String, Object?>();
    expect(raw['last_identity'], 'origin#user-7');
  });

  test('写入失败时不留临时文件', () async {
    // 把目标路径占成目录，临时文件改名成它时一定失败。
    await Directory(store.path).create(recursive: true);
    await expectLater(
      store.setAutoSync(false),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File('${store.path}.partial').exists(), isFalse);
  });
}
