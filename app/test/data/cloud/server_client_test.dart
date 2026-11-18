import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/data/cloud/server_client.dart';

import '../../support/fake_server.dart';

void main() {
  group('地址规范化', () {
    test('只填域名时补 https 并去掉末尾斜杠', () {
      expect(
        ServerClient.normalizeBaseUrl('zhixin.example.com/'),
        'https://zhixin.example.com',
      );
      expect(
        ServerClient.normalizeBaseUrl('http://127.0.0.1:8080//'),
        'http://127.0.0.1:8080',
      );
    });

    test('空地址与非 http 协议被拒绝', () {
      expect(
        () => ServerClient.normalizeBaseUrl('   '),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ServerClient.normalizeBaseUrl('ftp://zhixin.example.com'),
        throwsA(isA<FormatException>()),
      );
    });

    test('正式构建只接受 https，显式打开联调开关时才允许 http', () {
      expect(
        ServerClient.normalizeBaseUrl(
          'https://zhixin.example.com/',
          requireHttps: true,
        ),
        'https://zhixin.example.com',
      );
      expect(
        () => ServerClient.normalizeBaseUrl(
          'http://127.0.0.1:8080',
          requireHttps: true,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('https'),
          ),
        ),
      );
      expect(
        ServerClient.normalizeBaseUrl(
          'http://127.0.0.1:8080',
          requireHttps: false,
        ),
        'http://127.0.0.1:8080',
      );
    });
  });

  group('重定向', () {
    test('同源 30x 跟随，并保留访问令牌', () async {
      final seen = <String>[];
      final client = ServerClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((request) async {
          seen.add(request.url.toString());
          if (request.url.path == '/v1/sync/head') {
            return http.Response(
              '',
              302,
              headers: {'location': '/v1/sync/head2'},
            );
          }
          expect(
            request.headers['authorization'] ??
                request.headers['Authorization'],
            'Bearer token',
          );
          return http.Response(
            jsonEncode({'head': 3, 'schema_version': 27}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final head = await client.head('token');
      expect(head.head, 3);
      expect(seen, [
        'http://server.test/v1/sync/head',
        'http://server.test/v1/sync/head2',
      ]);
    });

    test('跨域 30x 直接按失败处理，不把带令牌的请求带到别的域', () async {
      var requests = 0;
      final client = ServerClient(
        baseUrl: 'http://server.test',
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.test/v1/sync/head'},
          );
        }),
      );

      await expectLater(
        client.head('token'),
        throwsA(
          isA<ServerProblem>()
              .having((error) => error.code, 'code', 'redirect_blocked')
              .having((error) => error.userMessage, 'message', contains('跨域')),
        ),
      );
      expect(requests, 1);
    });
  });

  group('刷新令牌', () {
    test('同一 request_id 重试旧刷新令牌按重试处理', () async {
      final server = FakeServer();
      final client = ServerClient(
        baseUrl: 'http://server.test',
        httpClient: server.client,
      );
      final tokens = await client.register(
        email: 'refresh-a@example.com',
        password: 'password123',
      );

      final refreshed = await client.refresh(
        tokens.refreshToken,
        requestId: 'request-1',
      );
      expect(refreshed.accessToken, isNot(tokens.accessToken));
      final replay = await client.refresh(
        tokens.refreshToken,
        requestId: 'request-1',
      );
      expect(replay.accessToken, refreshed.accessToken);
      expect(server.refreshRequests.map((entry) => entry.requestId), [
        'request-1',
        'request-1',
      ]);
    });

    test('换一个 request_id 使用旧刷新令牌会撤销会话', () async {
      final server = FakeServer();
      final client = ServerClient(
        baseUrl: 'http://server.test',
        httpClient: server.client,
      );
      final tokens = await client.register(
        email: 'refresh-b@example.com',
        password: 'password123',
      );
      final refreshed = await client.refresh(
        tokens.refreshToken,
        requestId: 'request-1',
      );

      await expectLater(
        client.refresh(tokens.refreshToken, requestId: 'request-2'),
        throwsA(
          isA<ServerProblem>().having(
            (error) => error.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      await expectLater(
        client.head(refreshed.accessToken),
        throwsA(
          isA<ServerProblem>().having((error) => error.status, 'status', 401),
        ),
      );
    });
  });

  test('注册与登录返回令牌，重复注册说明邮箱已占用', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    final tokens = await client.register(
      email: 'a@example.com',
      password: 'password123',
      deviceName: '测试设备',
    );
    expect(tokens.accessToken, isNotEmpty);
    expect(tokens.refreshToken, isNotEmpty);
    expect(tokens.userId, isNotEmpty);

    await expectLater(
      client.register(email: 'a@example.com', password: 'password123'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.code, 'code', 'email_taken')
            .having((error) => error.userMessage, 'message', contains('已经注册')),
      ),
    );
    final again = await client.login(
      email: 'a@example.com',
      password: 'password123',
    );
    expect(again.userId, tokens.userId);
  });

  test('令牌失效时返回 unauthorized，界面按登录失效说明', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    await expectLater(
      client.head('bad-token'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.isUnauthorized, 'unauthorized', true)
            .having((error) => error.userMessage, 'message', contains('重新登录')),
      ),
    );
  });

  test('推送在服务端位置变化时给出 conflict 与最新 head', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    final tokens = await client.register(
      email: 'b@example.com',
      password: 'password123',
    );
    final commit = ServerCommit(
      requestId: 'r1',
      deviceId: 'device-a',
      schemaVersion: 27,
      actor: 'user',
      action: '新增记忆',
      createdAt: '2026-11-17 10:00:00',
      changes: const [
        ServerChange(
          table: 'memory',
          rowKey: 'm1',
          op: 'insert',
          after: {
            'id': {'t': 'text', 'v': 'm1'},
          },
        ),
      ],
    );
    expect(
      await client.push(tokens.accessToken, baseSeq: 0, commits: [commit]),
      1,
    );
    await expectLater(
      client.push(
        tokens.accessToken,
        baseSeq: 0,
        commits: [
          ServerCommit(
            requestId: 'r2',
            deviceId: 'device-a',
            schemaVersion: 27,
            actor: 'user',
            action: '新增记忆',
            createdAt: '2026-11-17 10:00:00',
            changes: const [
              ServerChange(table: 'memory', rowKey: 'm2', op: 'delete'),
            ],
          ),
        ],
      ),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.isConflict, 'conflict', true)
            .having((error) => error.extra['head'], 'head', 1),
      ),
    );
  });

  test('备份上传带哈希与 schema，列表、下载与删除往返', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    final tokens = await client.register(
      email: 'c@example.com',
      password: 'password123',
    );
    final bytes = Uint8List.fromList(utf8.encode('zip-bytes'));
    final sha = _sha256Of(bytes);
    final uploaded = await client.backupUpload(
      tokens.accessToken,
      bytes: bytes,
      sha256: sha,
      schemaVersion: 27,
      deviceName: '测试设备',
    );
    expect(uploaded.sha256, sha);
    expect(uploaded.size, bytes.length);

    final list = await client.backupList(tokens.accessToken);
    expect(list, hasLength(1));
    expect(list.first.id, uploaded.id);

    final response = await client.backupDownload(
      tokens.accessToken,
      uploaded.id,
    );
    expect(response.bodyBytes, bytes);

    await client.backupDelete(tokens.accessToken, uploaded.id);
    expect(await client.backupList(tokens.accessToken), isEmpty);
  });

  test('附件按内容寻址：上传、存在检查与下载', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    final tokens = await client.register(
      email: 'd@example.com',
      password: 'password123',
    );
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final sha = _sha256Of(bytes);
    expect(await client.blobExists(tokens.accessToken, sha), isNull);

    await client.blobUpload(tokens.accessToken, sha, bytes);
    expect(await client.blobExists(tokens.accessToken, sha), bytes.length);
    expect(await client.blobDownload(tokens.accessToken, sha), bytes);
  });

  test('plumbing: DELETE 全量备份与同步序列返回 204', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );
    final tokens = await client.register(
      email: 'e@example.com',
      password: 'password123',
    );
    await client.deleteAllBackups(tokens.accessToken);
    await client.deleteSyncLog(tokens.accessToken);
    expect(await client.head(tokens.accessToken).then((h) => h.head), 0);
  });

  test('非 problem 响应也按状态码归类', () async {
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: MockClient((request) async => http.Response('oops', 502)),
    );
    await expectLater(
      client.head('token'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.status, 'status', 502)
            .having((error) => error.code, 'code', 'internal'),
      ),
    );
  });

  test('读发布清单不需要登录', () async {
    final server = FakeServer()
      ..releases.add({
        'platform': 'android',
        'version': '0.2.0',
        'build': 2,
        'url': 'https://example.test/zhixin-0.2.0.apk',
        'min_version': '0.1.0',
        'notes': '登录与云端备份',
      });
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );

    final list = await client.releases();
    expect(list, hasLength(1));
    expect(list.single.version, '0.2.0');
    expect(list.single.build, 2);
    expect(list.single.minVersion, '0.1.0');
    expect(list.single.notes, '登录与云端备份');
  });

  test('提交反馈不需要登录，空正文与服务端拒绝一致', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );

    final receipt = await client.sendFeedback(
      content: '记录页按“下一步”没有反应',
      appVersion: '0.2.0-dev+3',
      diagnostics: '2026-11-18 10:00 记录页',
    );
    expect(receipt.id, isNotEmpty);
    expect(server.feedbacks.single['content'], '记录页按“下一步”没有反应');
    expect(server.feedbacks.single['platform'], 'android');
    expect(server.feedbacks.single['app_version'], '0.2.0-dev+3');

    await expectLater(
      client.sendFeedback(content: '   '),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );
  });

  test('匿名活跃上报不需要登录', () async {
    final server = FakeServer();
    final client = ServerClient(
      baseUrl: 'http://server.test',
      httpClient: server.client,
    );

    await client.reportActive(
      installId: '0f8fad5b-d9cb-469f-a165-70867728950e',
      appVersion: '0.2.0-dev+3',
    );
    expect(
      server.actives.single['install_id'],
      '0f8fad5b-d9cb-469f-a165-70867728950e',
    );
    expect(server.actives.single['platform'], 'android');
    expect(server.actives.single['app_version'], '0.2.0-dev+3');

    await expectLater(
      client.reportActive(installId: 'too-short'),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );
  });
}

String _sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
