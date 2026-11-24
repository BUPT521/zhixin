import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/db/app_database.dart'
    show zhixinDbFileName, zhixinSchemaVersion;
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_config_store.dart';
import 'package:zhixin/ai/llm_protocol.dart';
import 'package:zhixin/ai/llm_transport.dart';
import 'package:zhixin/application/account_service.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/application/service_runtime.dart';
import 'package:zhixin/application/settings_service.dart';
import 'package:zhixin/application/time_policy_controller.dart';
import 'package:zhixin/data/backup/data_package_service.dart';
import 'package:zhixin/data/backup/data_version_service.dart';
import 'package:zhixin/data/backup/restore_point_store.dart';
import 'package:zhixin/data/cloud/account_store.dart';
import 'package:zhixin/data/cloud/cloud_preferences_store.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/settings_repository.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_package.dart';
import 'package:zhixin/domain/rules/embedding.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/fake_server.dart';
import '../support/test_db.dart';

/// 保存模型配置的用例用固定时刻：提交时间与截止小时口径都落在这里。
DateTime _fixedClock() => DateTime(2026, 11, 7, 20);

/// 只挂库的数据版本服务：保存模型配置不碰恢复与清空，这两个入口不会被调用。
DataVersionService _settingsDataVersions(TestRig rig) => DataVersionService(
  gate: rig.db.gate,
  revisions: rig.revisions,
  revisionPackages: RevisionPackageService(
    engine: rig.engine,
    assets: rig.engine.assets,
    schemaVersion: zhixinSchemaVersion,
    appVersion: 'test',
  ),
  dataPackages: DataPackageService(
    filesDir: rig.filesDir,
    dbPath: p.join(rig.filesDir, zhixinDbFileName),
    appVersion: 'test',
    schemaVersion: zhixinSchemaVersion,
  ),
  restorePointStore: RestorePointStore(filesDir: rig.filesDir),
  engine: rig.engine,
  cache: AttachmentCache(filesDir: () => rig.filesDir),
  connection: () => rig.raw,
  database: () => rig.db,
  reopen: () async => rig.raw,
  resetStudyData: () async {},
  markPendingWorkInvalidated: () {},
  notifyDataChanged: () {},
  recordFailure: (error, stack, {required kind}) {},
);

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

  test('知新 API Key 使用账号令牌，输错当前密码时不刷新会话', () async {
    final operations = <String>[];
    final backend = server.client;
    addTearDown(backend.close);
    var revoked = false;
    const fullKey = 'test-model-proxy-key';
    const path = '/v1/me/api-keys';
    late String accessToken;
    final client = MockClient((request) async {
      if (!request.url.path.startsWith(path)) {
        final forwarded = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await backend.send(forwarded));
      }
      expect(request.headers['authorization'], 'Bearer $accessToken');
      operations.add('${request.method} ${request.url.path}');
      switch (request.method) {
        case 'POST':
          final body = jsonDecode(request.body) as Map;
          expect(body['name'], '本机脚本');
          if (body['password'] != 'password123') {
            return http.Response('{"code":"invalid_credentials"}', 401);
          }
          return http.Response(jsonEncode({'key': fullKey}), 201);
        case 'GET':
          return http.Response(
            jsonEncode({
              'keys': [
                {
                  'id': 'key-1',
                  'name': '本机脚本',
                  'prefix': 'test-prefix',
                  'revoked': revoked,
                  'created_at': '2026-11-25T02:00:00Z',
                  'last_used_at': '2026-11-25T03:00:00Z',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        case 'DELETE':
          revoked = true;
          return http.Response('', 204);
        default:
          fail('意外的 API Key 请求 ${request.method}');
      }
    });
    addTearDown(client.close);
    final keysAccount = AccountService(
      store: AccountStore(MemorySecretStore()),
      preferences: preferences,
      clientFactory: (baseUrl) =>
          ServerClient(baseUrl: baseUrl, httpClient: client),
    );
    addTearDown(keysAccount.dispose);
    final signedIn = await keysAccount.register(
      identifier: 'keys@example.test',
      password: 'password123',
    );
    accessToken = signedIn.session!.accessToken;

    await expectLater(
      keysAccount.createApiKey(name: '本机脚本', password: 'incorrect'),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'invalid_credentials',
        ),
      ),
    );
    expect(server.refreshRequests, isEmpty);
    expect(
      await keysAccount.createApiKey(name: '本机脚本', password: 'password123'),
      fullKey,
    );
    final key = (await keysAccount.apiKeys()).single;
    expect(key.prefix, 'test-prefix');
    expect(key.lastUsedAt, DateTime.utc(2026, 11, 25, 3));
    expect(key.revoked, isFalse);
    await keysAccount.revokeApiKey(key.id);
    expect((await keysAccount.apiKeys()).single.revoked, isTrue);
    await keysAccount.revokeAllApiKeys();
    expect(operations, [
      'POST $path',
      'POST $path',
      'GET $path',
      'DELETE $path/key-1',
      'GET $path',
      'DELETE $path',
    ]);
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
      contains('zhixin-chat'),
    );
  });

  test('模型列表按用途区分，嵌入模型带维度，额度分开读', () async {
    await account.register(
      identifier: 'kind@example.com',
      password: 'password123',
    );

    final models = await account.models();
    final chat = models.singleWhere((model) => model.id == 'zhixin-chat');
    expect(chat.isChat, isTrue);
    expect(chat.dimensions, isNull);
    final embedding = models.singleWhere(
      (model) => model.id == 'zhixin-embedding',
    );
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
      spec: const EmbeddingModelSpec(
        id: 'zhixin-embedding',
        dim: 4,
        provider: 'server',
      ),
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
      const LlmConfig(model: 'zhixin-chat'),
    );
    expect(authorized, isNotNull);
    expect(authorized!.apiKey, startsWith('access-'));
    expect(authorized.endpoint, 'http://server.test/v1/llm/responses');
    expect(authorized.model, 'zhixin-chat');
  });

  test('未登录时模型配置补不上地址与令牌，设置页据此要求先登录', () async {
    expect(
      await account.authorizeModelConfig(const LlmConfig(model: 'zhixin-chat')),
      isNull,
    );
    await expectLater(
      account.prepareModelConfig(const LlmConfig(model: 'zhixin-chat')),
      throwsA(isA<AccountSignedOut>()),
    );
  });

  test('保存只存模型名、上下文上限与图片开关，令牌与地址不进本机配置', () async {
    await account.register(
      identifier: 'save@example.com',
      password: 'password123',
    );
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    final settings = SettingsRepository(rig.db);
    final store = LlmConfigStore(MemorySecretStore());
    final ai = AiChatService(
      store: store,
      configSource: () async =>
          account.authorizeModelConfig((await store.read()).valueOrNull),
    );
    addTearDown(ai.dispose);
    final service = SettingsService(
      settings: settings,
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      llmStore: store,
      ai: ai,
      runtime: ServiceRuntime(
        policySource: () => TimePolicy(clock: _fixedClock),
        filesDirSource: () => rig.filesDir,
      ),
      timePolicy: TimePolicyController(
        settings: settings,
        clock: _fixedClock,
        onChanged: () {},
      ),
      dataVersions: _settingsDataVersions(rig),
      authorizeConfig: account.prepareModelConfig,
    );

    const form = LlmConfig(model: 'zhixin-chat', contextWindowTokens: 8192);
    await service.saveConfig(form);
    final saved = (await store.read()).valueOrNull!;
    expect(saved.model, 'zhixin-chat');
    expect(saved.contextWindowTokens, 8192);
    expect(saved.apiKey, isEmpty);
    expect(saved.endpoint, isEmpty);
    // 回答路径每次现取：地址按服务地址拼，令牌是当前访问令牌。
    final current = await ai.config();
    expect(
      current.valueOrNull!.endpoint,
      'http://server.test/v1/llm/responses',
    );
    expect(current.valueOrNull!.apiKey, startsWith('access-'));
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
      await account.authorizeModelConfig(const LlmConfig(model: 'zhixin-chat')),
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
      SyncState(userId: userId, serverOrigin: 'http://server.test'),
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
      SyncState(userId: userId, serverOrigin: 'http://server.test'),
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

  // 项目技术审查 API-01 的验收：登录后经过账号服务拼出的地址，再经过真实传输
  // 层，最终请求必须落在服务端注册的 /v1/llm/responses。以前的用例分别验证
  // 地址拼接与由测试注入的完整地址，两者之间错位过一次，所以这里只经过
  // authorizeModelConfig，不注入地址。
  group('对话请求的跨层契约', () {
    late List<http.Request> sent;
    late HttpLlmClient Function(LlmConfig config) transport;

    setUp(() {
      sent = [];
      transport = (config) => HttpLlmClient(
        config: config,
        httpClient: MockClient.streaming((request, body) async {
          sent.add(request as http.Request);
          final reply = jsonEncode({
            'id': 'resp_1',
            'object': 'response',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '好的', 'annotations': []},
                ],
              },
            ],
          });
          return http.StreamedResponse(
            Stream.value(utf8.encode(reply)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });

    Future<LlmConfig> signedInConfig() async {
      await account.register(
        identifier: 'contract@example.com',
        password: 'password123',
      );
      final config = await account.authorizeModelConfig(
        const LlmConfig(model: 'zhixin-chat'),
      );
      return config!;
    }

    test('地址是 /v1/llm/responses，方法是 POST，鉴权头是当前访问令牌', () async {
      final config = await signedInConfig();
      final client = transport(config);
      addTearDown(client.dispose);

      final reply = await client.complete(
        system: '你是搭子',
        messages: const [LlmMessage(role: 'user', content: '在吗')],
        tools: const [],
      );
      expect(reply.text, '好的');

      final request = sent.single;
      expect(request.url.path, '/v1/llm/responses');
      expect(request.url.toString(), 'http://server.test/v1/llm/responses');
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer ${config.apiKey}');
      expect(config.apiKey, startsWith('access-'));
    });

    test('请求体带 store: false，不带 temperature 与 top_p', () async {
      final config = await signedInConfig();
      final client = transport(config);
      addTearDown(client.dispose);

      await client.complete(
        system: '你是搭子',
        messages: const [LlmMessage(role: 'user', content: '在吗')],
        tools: const [],
      );

      final body = jsonDecode(sent.single.body) as Map<String, Object?>;
      expect(body['store'], isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body['model'], 'zhixin-chat');
      // 服务端的输出上限是 16 到 32768，客户端不能发出范围之外的请求。
      final limit = body['max_output_tokens'] as int;
      expect(limit, inInclusiveRange(16, 32768));
    });

    test('嵌入走 /v1/llm/embeddings，与对话地址分开', () async {
      await signedInConfig();
      final target = await account.embeddingEndpoint();
      expect(target.endpoint, 'http://server.test/v1/llm');
      expect(endpointUri(target, '/embeddings').path, '/v1/llm/embeddings');
      expect(
        endpointUri(target, '/embeddings/lookup').path,
        '/v1/llm/embeddings/lookup',
      );
    });
  });
}
