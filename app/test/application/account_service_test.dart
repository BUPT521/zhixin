import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/app_database.dart' show zhixinSchemaVersion;
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/domain/rules/embedding.dart';

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
    expect(ready.schemaVersion, zhixinSchemaVersion);

    await defaultAccount.register(
      identifier: 'default@example.com',
      password: 'password123',
    );
    expect((await defaultAccount.quota()).dailyTokens, 200000);
    expect(
      (await defaultAccount.models()).map((model) => model.id),
      contains('deepseek-flash'),
    );
  });

  test('模型列表按用途区分，嵌入模型带维度，额度分开读', () async {
    await account.register(
      identifier: 'kind@example.com',
      password: 'password123',
    );

    final models = await account.models();
    final chat = models.singleWhere((model) => model.id == 'deepseek-flash');
    expect(chat.isChat, isTrue);
    expect(chat.dimensions, isNull);
    final embedding = models.singleWhere((model) => model.id == 'bge-m3');
    expect(embedding.isEmbedding, isTrue);
    expect(embedding.dimensions, 4);

    final quota = await account.quota();
    expect(quota.dailyTokens, 200000);
    expect(quota.embeddingDailyTokens, 2000000);
  });

  test('旧版服务端不带 kind 时按聊天模型处理，不认识的用途跳过', () {
    expect(ServerModelKind.fromValue(null), ServerModelKind.chat);
    expect(ServerModelKind.fromValue('embedding'), ServerModelKind.embedding);
    expect(ServerModelKind.fromValue('rerank'), isNull);
  });

  test('知新服务的嵌入地址与令牌每次现取，未登录时报来源不可用', () async {
    await expectLater(
      account.embeddingEndpoint(),
      throwsA(isA<EmbeddingSourceUnavailable>()),
    );

    final snapshot = await account.register(
      identifier: 'embed@example.com',
      password: 'password123',
    );
    final endpoint = await account.embeddingEndpoint();
    expect(endpoint.endpoint, 'http://server.test/v1/llm');
    expect(endpoint.apiKey, snapshot.session!.accessToken);

    final client = RemoteEmbeddingClient(
      spec: const EmbeddingModelSpec(id: 'bge-m3', dim: 4, provider: 'server'),
      credentials: account.embeddingEndpoint,
      httpClient: server.client,
    );
    addTearDown(client.dispose);
    final vectors = await client.embedBatch(['熵', '导数是什么']);
    expect(vectors, hasLength(2));
    expect(server.embeddingTokens, [snapshot.session!.accessToken]);

    server.embeddingQuotaExceeded = true;
    await expectLater(
      client.embed('熵'),
      throwsA(isA<EmbeddingSourceUnavailable>()),
    );

    await account.setServerBaseUrl('http://other-server.test');
    await expectLater(
      client.embed('熵'),
      throwsA(isA<EmbeddingSourceUnavailable>()),
    );
    expect(
      server.embeddingTokens,
      List.filled(2, snapshot.session!.accessToken),
    );
  });

  test('注册后保存会话，知新服务配置换成访问令牌', () async {
    final snapshot = await account.register(
      identifier: 'A@Example.com',
      password: 'password123',
    );
    expect(snapshot.signedIn, isTrue);
    expect(snapshot.displayLabel, 'a@example.com');
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
    await account.register(
      identifier: 'b@example.com',
      password: 'password123',
    );
    server.expireAccess = true;
    final quota = await account.quota();
    expect(quota.dailyTokens, 200000);
    final snapshot = await account.snapshot();
    expect(snapshot.signedIn, isTrue);
  });

  test('刷新响应丢失时用同一个 request_id 重试旧刷新令牌', () async {
    await account.register(
      identifier: 'l@example.com',
      password: 'password123',
    );
    // 下一次带令牌的请求被判过期，客户端先刷新；刷新在服务端已经轮换成功，
    // 但响应在返回之前断开，客户端应当用同一个标识与旧刷新令牌再试一次。
    server.expireAccess = true;
    server.dropNextRefreshResponse = true;

    final quota = await account.quota();
    expect(quota.dailyTokens, 200000);
    expect(server.refreshRequests, hasLength(2));
    final first = server.refreshRequests[0];
    final retry = server.refreshRequests[1];
    expect(first.refreshToken, retry.refreshToken);
    expect(first.requestId, isNotEmpty);
    expect(retry.requestId, first.requestId);
    expect((await account.snapshot()).signedIn, isTrue);
  });

  test('登录时密码错误返回 invalid_credentials', () async {
    await account.register(
      identifier: 'c@example.com',
      password: 'password123',
    );
    await account.logout();
    await expectLater(
      account.login(identifier: 'c@example.com', password: 'wrong-password'),
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
      identifier: 'd@example.com',
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

  test('清除云端数据一次清空备份、提交序列与附件，账号还在', () async {
    final snapshot = await account.register(
      identifier: 'e@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    server.commits[userId] = [
      {'request_id': 'r1', 'seq': 1},
    ];
    server.backups[userId] = [
      FakeBackup(
        meta: {'id': 'backup-1', 'sha256': '', 'size': 0},
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
    ];
    server.blobs[userId] = {
      'a' * 64: Uint8List.fromList([4, 5, 6]),
    };
    await account.clearCloudData(password: 'password1');
    expect(server.cloudClearRequests, 1);
    expect(server.commits[userId], isEmpty);
    expect(server.backups[userId], isNull);
    expect(server.blobs[userId], isNull);
    expect((await account.snapshot()).signedIn, isTrue);
    expect(server.userIdOf('e@example.com'), userId);
  });

  test('清除期间服务端返回 409 时不算失败，游标保留并可重试', () async {
    final snapshot = await account.register(
      identifier: 'e2@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    await preferences.saveSyncState(
      SyncState(
        userId: userId,
        serverOrigin: 'http://server.test',
        serverHead: 2,
        pushedThrough: 1,
      ),
    );
    server.cloudClearConflicts = 1;

    await expectLater(
      account.clearCloudData(password: 'password1'),
      throwsA(
        isA<ServerProblem>()
            .having((error) => error.isConflict, 'conflict', true)
            .having((error) => error.status, 'status', 409),
      ),
    );
    // 上一次清除还没结束时不清游标，用户稍后重试即可。
    expect(await preferences.syncState(), isNotNull);
    expect(server.cloudClearRequests, 1);

    await account.clearCloudData(password: 'password1');
    expect(server.cloudClearRequests, 2);
    expect(await preferences.syncState(), isNull);
  });

  test('注册后登录方式未确认，确认验证码之后状态更新', () async {
    final snapshot = await account.register(
      identifier: 'g@example.com',
      password: 'password123',
    );
    expect(snapshot.contactVerified, isFalse);
    // 登录之后立刻读到了资料，账号页因此能直接列出登录方式。
    expect(snapshot.displayLabel, 'g@example.com');
    final identityId = snapshot.profile!.identities.single.id;

    await account.requestIdentityVerification(identityId);
    final code = server.codeFor('g@example.com', 'verify_contact');
    expect(code, isNotNull);
    await account.confirmIdentityVerification(identityId, code!);

    final refreshed = await account.refreshAccount();
    expect(refreshed.contactVerified, isTrue);
  });

  test('验证码错误时服务端返回 invalid_code', () async {
    final snapshot = await account.register(
      identifier: 'h@example.com',
      password: 'password123',
    );
    final identityId = snapshot.profile!.identities.single.id;
    await account.requestIdentityVerification(identityId);
    await expectLater(
      account.confirmIdentityVerification(identityId, '000000'),
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
    final signedUp = await account.register(
      identifier: 'i@example.com',
      password: 'password123',
    );
    final identityId = signedUp.profile!.identities.single.id;
    await account.requestIdentityVerification(identityId);
    final verifyCode = server.codeFor('i@example.com', 'verify_contact')!;
    await account.confirmIdentityVerification(identityId, verifyCode);

    final oldSession = await account.snapshot();
    await account.logout();
    await account.requestPasswordReset('i@example.com');
    final resetCode = server.codeFor('i@example.com', 'reset_password')!;
    await account.resetPassword(
      identifier: 'i@example.com',
      code: resetCode,
      newPassword: 'newpassword123',
    );
    expect((await account.snapshot()).signedIn, isFalse);
    expect(oldSession.session, isNotNull);

    await expectLater(
      account.login(identifier: 'i@example.com', password: 'password123'),
      throwsA(isA<ServerProblem>()),
    );
    final again = await account.login(
      identifier: 'i@example.com',
      password: 'newpassword123',
    );
    expect(again.signedIn, isTrue);
  });

  test('删除账号清掉服务端数据与本机会话', () async {
    final snapshot = await account.register(
      identifier: 'f@example.com',
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
      identifier: 'j@example.com',
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

  test('会话按实例来源保存，别的实例读不到旧令牌', () async {
    final secrets = MemorySecretStore();
    final store = AccountStore(secrets);
    final now = DateTime.now();
    await store.save(
      AccountSession(
        userId: 'user-1',
        serverOrigin: 'https://a.test',
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        accessExpiresAt: now.add(const Duration(hours: 1)),
        refreshExpiresAt: now.add(const Duration(days: 30)),
      ),
    );
    expect(await store.read(origin: 'https://a.test'), isNotNull);
    expect(await store.read(origin: 'https://b.test'), isNull);
    expect((await store.read())!.serverOrigin, 'https://a.test');
  });

  test('资料单独保存，退出登录时与会话一起清掉', () async {
    var snapshot = await account.register(
      identifier: 'profile@example.com',
      password: 'password123',
    );
    final session = snapshot.session!;
    final origin = session.serverOrigin;
    expect(
      snapshot.profile!.identities.single.identifier,
      'profile@example.com',
    );
    expect(await account.store.readProfile(origin: origin), isNotNull);

    // 令牌刷新只改会话，不动资料。
    await account.store.save(
      session.copyWith(
        accessToken: 'access-token-2',
        refreshToken: 'refresh-token-2',
        accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
        refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
      ),
    );
    expect(await account.store.readProfile(origin: origin), isNotNull);

    await account.logout();
    snapshot = await account.snapshot();
    expect(snapshot.signedIn, isFalse);
    expect(snapshot.profile, isNull);
    expect(await account.store.readProfile(origin: origin), isNull);
  });

  test('切换服务实例后不复用旧会话，同步游标清掉并暂停自动同步', () async {
    final snapshot = await account.register(
      identifier: 'm@example.com',
      password: 'password123',
    );
    final userId = snapshot.session!.userId;
    await preferences.setAutoSync(true);
    await preferences.saveSyncState(
      SyncState(
        userId: userId,
        serverOrigin: 'http://server.test',
        serverHead: 3,
        pushedThrough: 1,
      ),
    );

    await account.setServerBaseUrl('http://other.test');
    final after = await account.snapshot();
    expect(after.signedIn, isFalse);
    expect(after.autoSync, isFalse);
    expect(await preferences.syncState(), isNull);

    // 切回旧实例也不会把旧会话还回来，需要重新登录。
    await account.setServerBaseUrl('http://server.test');
    expect((await account.snapshot()).signedIn, isFalse);
  });

  test('切换实例时进行中的刷新结果被丢弃', () async {
    await account.register(
      identifier: 'n@example.com',
      password: 'password123',
    );
    server.expireAccess = true;
    final gate = Completer<void>();
    server.delayRefresh = gate.future;

    final pending = account.quota();
    while (server.refreshRequests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    // 刷新还卡在途中时换到另一个实例：这次刷新属于旧实例，结果不能写回。
    await account.setServerBaseUrl('http://other.test');
    gate.complete();

    await expectLater(pending, throwsA(isA<AccountSignedOut>()));
    expect((await account.snapshot()).signedIn, isFalse);
  });

  test('登录途中切换实例时丢弃这次登录结果', () async {
    await account.register(
      identifier: 'q@example.com',
      password: 'password123',
    );
    await account.logout();
    final gate = Completer<void>();
    server.delayLogin = gate.future;

    final pending = account.login(
      identifier: 'q@example.com',
      password: 'password123',
    );
    while (server.loginRequests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await account.setServerBaseUrl('http://other.test');
    gate.complete();

    await expectLater(pending, throwsA(isA<AccountSignedOut>()));
    expect((await account.snapshot()).signedIn, isFalse);
  });

  test('登录另一个账号时暂停自动同步并清掉旧游标', () async {
    final first = await account.register(
      identifier: 'o@example.com',
      password: 'password123',
    );
    await preferences.setAutoSync(true);
    await preferences.saveSyncState(
      SyncState(
        userId: first.session!.userId,
        serverOrigin: 'http://server.test',
        serverHead: 2,
        pushedThrough: 1,
      ),
    );

    await account.logout();
    final second = await account.register(
      identifier: 'p@example.com',
      password: 'password123',
    );
    expect(second.session!.userId, isNot(first.session!.userId));
    expect(second.autoSync, isFalse);
    expect(await preferences.syncState(), isNull);
  });
}
