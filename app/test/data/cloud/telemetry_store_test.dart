import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/cloud/telemetry_store.dart';

/// 匿名活跃上报的本机状态：安装标识只生成一次，默认开启，说明与日期都按文件
/// 保存；文件损坏时退回空状态，不影响启动。
void main() {
  late Directory directory;
  late TelemetryStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-telemetry-');
    store = TelemetryStore(filesDir: directory.path);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('安装标识首次生成后保持不变', () async {
    final first = await store.installId();
    expect(first, hasLength(32));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(first), isTrue);
    expect(await store.installId(), first);
  });

  test('默认开启，关闭之后读出关闭状态', () async {
    expect(await store.enabled(), isTrue);
    await store.setEnabled(false);
    expect(await store.enabled(), isFalse);
  });

  test('首次说明默认没看过，看过之后不再弹出', () async {
    expect(await store.noticeSeen(), isFalse);
    await store.markNoticeSeen();
    expect(await store.noticeSeen(), isTrue);
  });

  test('上次上报日期按本机自然日保存', () async {
    expect(await store.lastReportDay(), isNull);
    await store.setLastReportDay('2026-11-18');
    expect(await store.lastReportDay(), '2026-11-18');
  });

  test('文件损坏时按空状态处理', () async {
    await File(store.path).parent.create(recursive: true);
    await File(store.path).writeAsString('not-json');
    expect(await store.enabled(), isTrue);
    expect(await store.lastReportDay(), isNull);
    expect(await store.installId(), hasLength(32));
  });
}
