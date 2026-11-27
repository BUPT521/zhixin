import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/cloud/device_preferences_store.dart';

/// 设备级偏好的读写：默认地址、去空白保存，以及文件不叫 cloud.json。
void main() {
  late Directory directory;
  late DevicePreferencesStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-device-prefs-');
    store = DevicePreferencesStore(filesDir: directory.path);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('没有保存过时用默认地址', () async {
    expect(await store.storedServerBaseUrl(), isEmpty);
    expect(await store.usesDefaultServerBaseUrl(), isTrue);
    expect(await store.serverBaseUrl(), defaultServerBaseUrl);
  });

  test('地址按去掉首尾空白保存，清空之后回到默认地址', () async {
    await store.setServerBaseUrl('  https://example.com  ');
    expect(await store.storedServerBaseUrl(), 'https://example.com');
    expect(await store.usesDefaultServerBaseUrl(), isFalse);
    await store.setServerBaseUrl('   ');
    expect(await store.usesDefaultServerBaseUrl(), isTrue);
    expect(await store.serverBaseUrl(), defaultServerBaseUrl);
  });

  test('开发者模式保存之后读得出', () async {
    expect(await store.developerMode(), isFalse);
    await store.setDeveloperMode(true);
    expect(await store.developerMode(), isTrue);
  });

  test('设备偏好与同步偏好不是同一个文件', () async {
    expect(store.path, isNot(contains('cloud.json')));
    expect(store.path, endsWith(DevicePreferencesStore.fileName));
  });
}
