import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';

import '../support/fake_server.dart';

void main() {
  late FakeServer server;
  late Directory dir;
  late AccountService account;
  late CloudPreferencesStore preferences;

  setUp(() async {
    server = FakeServer();
    dir = await Directory.systemTemp.createTemp('zhixin_account_test');
    preferences = CloudPreferencesStore(filesDir: dir.path);
    account = AccountService(
      store: AccountStore(MemorySecretStore()),
      preferences: preferences,
      clientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: server.client),
    );
    await account.setServerBaseUrl('http://server.test');
  });

  tearDown(() async {
    account.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('没有填写地址时使用默认服务地址，并能检查就绪状态', () async {
    final defaultDir = Directory('${dir.path}/default');
    final defaultAccount = AccountService(
      store: AccountStore(MemorySecretStore()),
      preferences: CloudPreferencesStore(filesDir: defaultDir.path),
      clientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: server.client),
    );
    addTearDown(defaultAccount.dispose);

    final snapshot = await defaultAccount.snapshot();
    expect(snapshot.serverBaseUrl, defaultServerBaseUrl);
    expect(snapshot.usesDefaultServer, isTrue);
    expect(snapshot.serverLabel, startsWith('默认地址：'));

    final ready = await defaultAccount.checkServer();
    expect(ready.ready, isTrue);
    expect(ready.schemaVersion, 27);

    await defaultAccount.register(
      email: 'default@example.com',
      password: 'password123',
    );
    expect((await defaultAccount.quota()).dailyTokens, 200000);
    expect(
      (await defaultAccount.models()).map((model) => model.id),
      contains('deepseek-flash'),
    );
  });

  test('注册后保存会话，知新服务配置换成访问令牌', () async {
    final snapshot = await account.register(
      email: 'A@Example.com',
      password: 'password123',
    );
    expect(snapshot.signedIn, isTrue);
    expect(snapshot.email, 'a@example.com');
    expect(snapshot.serverBaseUrl, 'http://server.test');

    final authorized = await account.authorizeModelConfig(
      const LlmConfig(
        source: LlmSource.server,
        baseUrl: '',
        model: 'deepseek-flash',
      ),
    );
    expect(authorized, isNotNull);
    expect(authorized!.apiKey, startsWith('access-'));
    expect(authorized.baseUrl, 'http://server.test/v1/llm');
    expect(authorized.api, LlmApi.chat);
  });

  test('访问令牌被服务端作废时自动刷新并重试一次', () async {
    await account.register(email: 'b@example.com', password: 'password123');
    server.expireAccess = true;
    final quota = await account.quota();
    expect(quota.dailyTokens, 200000);
    final snapshot = await account.snapshot();
    expect(snapshot.signedIn, isTrue);
  });

  test('登录时密码错误返回 invalid_credentials', () async {
    await account.register(email: 'c@example.com', password: 'password123');
    await account.logout();
    await expectLater(
      account.login(email: 'c@example.com', password: 'wrong-password'),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'invalid_credentials',
        ),
      ),
    );
  });

  test('退出登录清掉本机会话，云端数据保留', () async {
    final snapshot = await account.register(
      email: 'd@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    await account.logout();
    expect((await account.snapshot()).signedIn, isFalse);
    expect(
      await account.authorizeModelConfig(
        const LlmConfig(source: LlmSource.server),
      ),
      isNull,
    );
    expect(server.userIdOf('d@example.com'), userId);
  });

  test('清除云端数据删除备份与提交序列，账号还在', () async {
    final snapshot = await account.register(
      email: 'e@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    server.commits[userId] = [
      {'request_id': 'r1', 'seq': 1},
    ];
    await account.clearCloudData();
    expect(server.commits[userId], isEmpty);
    expect((await account.snapshot()).signedIn, isTrue);
    expect(server.userIdOf('e@example.com'), userId);
  });

  test('注册后邮箱未验证，确认验证码之后状态更新', () async {
    final snapshot = await account.register(
      email: 'g@example.com',
      password: 'password123',
    );
    expect(snapshot.emailVerified, isFalse);

    await account.requestEmailVerification();
    final code = server.codeFor('g@example.com', 'verify_email');
    expect(code, isNotNull);
    await account.confirmEmailVerification(code!);

    final refreshed = await account.refreshAccount();
    expect(refreshed.emailVerified, isTrue);
  });

  test('验证码错误时服务端返回 invalid_code', () async {
    await account.register(email: 'h@example.com', password: 'password123');
    await account.requestEmailVerification();
    await expectLater(
      account.confirmEmailVerification('000000'),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'invalid_code',
        ),
      ),
    );
  });

  test('忘记密码重设之后清掉本机会话，旧密码与旧令牌失效', () async {
    await account.register(email: 'i@example.com', password: 'password123');
    await account.requestEmailVerification();
    final verifyCode = server.codeFor('i@example.com', 'verify_email')!;
    await account.confirmEmailVerification(verifyCode);

    final oldSession = await account.snapshot();
    await account.logout();
    await account.requestPasswordReset('i@example.com');
    final resetCode = server.codeFor('i@example.com', 'reset_password')!;
    await account.resetPassword(
      email: 'i@example.com',
      code: resetCode,
      newPassword: 'newpassword123',
    );
    expect((await account.snapshot()).signedIn, isFalse);
    expect(oldSession.session, isNotNull);

    await expectLater(
      account.login(email: 'i@example.com', password: 'password123'),
      throwsA(isA<ServerProblem>()),
    );
    final again = await account.login(
      email: 'i@example.com',
      password: 'newpassword123',
    );
    expect(again.signedIn, isTrue);
  });

  test('删除账号清掉服务端数据与本机会话', () async {
    final snapshot = await account.register(
      email: 'f@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    server.commits[userId] = [
      {'request_id': 'r1', 'seq': 1},
    ];
    await account.deleteAccount(password: 'password123');
    expect((await account.snapshot()).signedIn, isFalse);
    expect(server.commits.containsKey(userId), isFalse);
  });

  test('删除账号时密码错误只提示密码错误，登录状态与账号保留', () async {
    final snapshot = await account.register(
      email: 'j@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;

    await expectLater(
      account.deleteAccount(password: 'wrong-password'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.code, 'code', 'invalid_credentials')
            .having((error) => error.userMessage, 'message', '邮箱或密码不正确'),
      ),
    );
    // 密码错误不刷新令牌再试，避免叠一次失败预算。
    expect(server.deleteAttempts, 1);
    expect((await account.snapshot()).signedIn, isTrue);
    expect((await account.snapshot()).session!.userId, userId);
    expect(server.userIdOf('j@example.com'), userId);

    await account.deleteAccount(password: 'password123');
    expect((await account.snapshot()).signedIn, isFalse);
  });
}
