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
}

String _sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
