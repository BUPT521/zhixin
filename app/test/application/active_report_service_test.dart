import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/application/active_report_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/cloud/telemetry_store.dart';
import 'package:zhixin/data/diagnostics/crash_log.dart';

/// 匿名活跃上报（ADR-0019）：不登录、开启、说明看过且当天还没报过时才发一次；
/// 失败静默重试一次，仍失败只写本机诊断。
void main() {
  late Directory directory;
  late TelemetryStore store;
  late CrashLog crashLog;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-active-report-');
    store = TelemetryStore(filesDir: directory.path);
    crashLog = CrashLog(filesDir: directory.path);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  ActiveReportService service({
    required http.Client client,
    Future<bool> Function()? signedIn,
    DateTime? now,
  }) => ActiveReportService(
    store: store,
    signedIn: signedIn ?? () async => false,
    serverBaseUrl: () async => 'http://server.test',
    crashLog: crashLog,
    appVersion: '0.2.0-dev+1',
    clock: () => now ?? DateTime(2026, 11, 18, 9, 30),
    clientFactory: (baseUrl) =>
        ServerClient(baseUrl: baseUrl, httpClient: client),
    retryDelay: Duration.zero,
  );

  test('不登录时每天上报一次，内容只有标识、版本与平台', () async {
    var requests = 0;
    var body = <String, Object?>{};
    final client = MockClient((request) async {
      requests++;
      body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      return http.Response('', 204);
    });
    await store.markNoticeSeen();

    await service(client: client).reportIfDue();
    expect(requests, 1);
    expect(body['install_id'], hasLength(32));
    expect(body['app_version'], '0.2.0-dev+1');
    expect(body['platform'], isNotEmpty);
    expect(await store.lastReportDay(), '2026-11-18');

    // 同一天再调用不发第二次。
    await service(client: client).reportIfDue();
    expect(requests, 1);

    // 第二天再报一次。
    await service(client: client, now: DateTime(2026, 11, 19, 8)).reportIfDue();
    expect(requests, 2);
    expect(await store.lastReportDay(), '2026-11-19');
  });

  test('关闭统计、没看过说明或已经登录时都不上报', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('', 204);
    });

    await service(client: client).reportIfDue(); // 没看过说明
    expect(requests, 0);

    await store.markNoticeSeen();
    await store.setEnabled(false);
    await service(client: client).reportIfDue(); // 关闭
    expect(requests, 0);

    await store.setEnabled(true);
    await service(client: client, signedIn: () async => true).reportIfDue();
    expect(requests, 0); // 登录用户由服务端统计
  });

  test('第一次失败后静默重试一次，成功就记下当天', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return requests == 1
          ? http.Response('{"code":"internal"}', 500)
          : http.Response('', 204);
    });
    await store.markNoticeSeen();

    await service(client: client).reportIfDue();
    expect(requests, 2);
    expect(await store.lastReportDay(), '2026-11-18');
  });

  test('首次说明的选择写进本机状态', () async {
    final client = MockClient((request) async => http.Response('', 204));
    await service(client: client).completeNotice(enabled: false);
    expect(await store.enabled(), isFalse);
    expect(await store.noticeSeen(), isTrue);

    // 再看一次说明并选择保持开启时，当天就会上报一次。
    await service(client: client).completeNotice(enabled: true);
    expect(await store.enabled(), isTrue);
    expect(await store.noticeSeen(), isTrue);
    expect(await store.lastReportDay(), '2026-11-18');
  });

  test('两次都失败时不记日期，只写本机诊断', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('', 500);
    });
    await store.markNoticeSeen();

    await service(client: client).reportIfDue();
    expect(requests, 2);
    expect(await store.lastReportDay(), isNull);
    final diagnostics = File(p.join(directory.path, CrashLog.fileName));
    expect(await diagnostics.exists(), isTrue);
    expect(await diagnostics.readAsString(), contains('telemetry_report'));
  });
}
