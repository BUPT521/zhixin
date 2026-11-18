import 'dart:async';

import '../ai/llm_config.dart';
import '../data/cloud/account_store.dart';
import '../data/cloud/cloud_preferences_store.dart';
import '../data/cloud/server_client.dart';
import '../domain/rules/uuid_v7.dart';

/// 还没有登录，或登录已经失效；需要用户重新登录之后才能继续。
class AccountSignedOut implements Exception {
  const AccountSignedOut();

  String get userMessage => '还没有登录，登录后可以使用云端备份、同步与知新服务';

  @override
  String toString() => userMessage;
}

/// 账号相关的配置问题，例如还没填服务地址；说明可以直接显示。
class AccountConfigException implements Exception {
  const AccountConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 设置页与账号页读到的一份账号状态。
class AccountSnapshot {
  const AccountSnapshot({
    required this.serverBaseUrl,
    required this.session,
    required this.autoSync,
    this.usesDefaultServer = false,
  });

  final String serverBaseUrl;
  final AccountSession? session;
  final bool autoSync;

  /// 地址还没有被改过，用的是编译时的默认值。
  final bool usesDefaultServer;

  bool get signedIn => session != null;
  String get email => session?.email ?? '';

  /// 邮箱还没有验证时，找回密码收不到验证码；账号页据此提示。
  bool get emailVerified => session?.emailVerified ?? false;

  String get serverLabel => serverBaseUrl.isEmpty
      ? '还没有填写服务地址'
      : (usesDefaultServer ? '默认地址：$serverBaseUrl' : serverBaseUrl);
}

/// 账号与登录：注册、登录、刷新令牌、退出、删除账号与清除云端数据。
///
/// 令牌只进 Android Keystore；服务地址与同步游标写在应用私有目录的
/// `cloud.json`（[CloudPreferencesStore]）。所有需要登录的请求经 [call] 发出去，
/// 访问令牌过期时先刷新再重试一次；刷新失败说明登录已经失效，界面要求重登。
class AccountService {
  AccountService({
    required this.store,
    required this.preferences,
    DateTime Function()? now,
    String? deviceName,
    this.clientFactory,
  }) : _now = now ?? DateTime.now,
       _deviceName = deviceName ?? '知新';

  /// 注册与登录时带给服务端的设备名，只用于在服务端列出会话，不含个人信息。
  String get deviceName => _deviceName;

  final AccountStore store;
  final CloudPreferencesStore preferences;
  final DateTime Function() _now;
  final String _deviceName;

  /// 建服务端客户端的方式；测试注入进程内的假服务，生产留空。
  final ServerClient Function(String baseUrl)? clientFactory;

  /// 多个请求同时发现令牌过期时只刷新一次，避免两次刷新互相作废。
  Future<AccountSession>? _refreshing;
  ServerClient? _client;

  Future<AccountSnapshot> snapshot() async {
    final session = await store.read();
    final baseUrl = await preferences.serverBaseUrl();
    final autoSync = await preferences.autoSync();
    final usesDefault = await preferences.usesDefaultServerBaseUrl();
    if (session != null && session.isExpired) {
      await store.clear();
      return AccountSnapshot(
        serverBaseUrl: baseUrl,
        session: null,
        autoSync: autoSync,
        usesDefaultServer: usesDefault,
      );
    }
    return AccountSnapshot(
      serverBaseUrl: baseUrl,
      session: session,
      autoSync: autoSync,
      usesDefaultServer: usesDefault,
    );
  }

  Future<String> serverBaseUrl() => preferences.serverBaseUrl();

  /// 保存服务地址；格式不合法时抛出 [FormatException]。
  Future<void> setServerBaseUrl(String value) async {
    final normalized = ServerClient.normalizeBaseUrl(value);
    await preferences.setServerBaseUrl(normalized);
    _client?.dispose();
    _client = null;
  }

  Future<bool> autoSync() => preferences.autoSync();

  Future<void> setAutoSync(bool value) => preferences.setAutoSync(value);

  /// 注册并登录当前设备；邮箱已经注册时抛出 `email_taken`。
  Future<AccountSnapshot> register({
    required String email,
    required String password,
  }) async {
    final client = await _requireClient();
    final tokens = await client.register(
      email: email.trim().toLowerCase(),
      password: password,
      deviceName: _deviceName,
    );
    return _adopt(tokens, email: email.trim().toLowerCase());
  }

  Future<AccountSnapshot> login({
    required String email,
    required String password,
  }) async {
    final client = await _requireClient();
    final tokens = await client.login(
      email: email.trim().toLowerCase(),
      password: password,
      deviceName: _deviceName,
    );
    return _adopt(tokens, email: email.trim().toLowerCase());
  }

  /// 退出当前设备；服务端不可达时也要清掉本机会话。
  Future<void> logout() async {
    final session = await store.read();
    if (session != null) {
      try {
        final client = await _requireClient();
        await client.logout(session.accessToken);
      } catch (_) {
        // 退出登录以本机为准：网络失败时服务端会话到期后自然失效。
      }
    }
    await store.clear();
  }

  /// 删除账号，连同云端同步序列、附件与备份；本机学习记录保留。
  ///
  /// 服务端要求重新提交当前密码：密码错误时抛出 `invalid_credentials`，本机
  /// 会话与页面状态都不改动，也不刷新令牌重试，避免多消耗一次失败预算。
  Future<void> deleteAccount({required String password}) async {
    final session = await _requireSession();
    final client = await _requireClient();
    final token = (await _fresh(session)).accessToken;
    try {
      await client.deleteMe(token, password: password);
    } on ServerProblem catch (error) {
      if (!error.isUnauthorized || error.code == 'invalid_credentials') rethrow;
      final retry = await _refreshStale(token);
      await client.deleteMe(retry.accessToken, password: password);
    }
    await store.clear();
    await preferences.clearSyncState();
  }

  /// 清除云端备份与同步序列，保留账号与本机记录。
  ///
  /// 清空之后服务端位置回到 0，下一次同步会按当前本机数据重新上传一份基线。
  Future<void> clearCloudData() async {
    await call<void>((client, token) async {
      await client.deleteAllBackups(token);
      await client.deleteSyncLog(token);
    });
    await preferences.clearSyncState();
  }

  /// 读服务端的就绪状态与它接受的客户端 schema；保存地址之后核对一次。
  Future<ServerReady> checkServer() async {
    final client = await _requireClient();
    return client.ready();
  }

  /// 重新读一次服务端的账号信息，更新邮箱验证状态；网络失败时沿用本机记录。
  Future<AccountSnapshot> refreshAccount() async {
    final session = await store.read();
    if (session == null) return snapshot();
    try {
      final remote = await call<ServerAccount>(
        (client, token) => client.me(token),
      );
      final updated = session.copyWith(emailVerified: remote.emailVerified);
      if (updated.emailVerified != session.emailVerified) {
        await store.save(updated);
      }
      return AccountSnapshot(
        serverBaseUrl: await serverBaseUrl(),
        session: updated,
        autoSync: await autoSync(),
        usesDefaultServer: await preferences.usesDefaultServerBaseUrl(),
      );
    } catch (_) {
      // 验证状态是一次额外的核对，失败不影响本机已登录状态。
      return snapshot();
    }
  }

  /// 给当前账号的邮箱发验证码；已经验证过时服务端不重复发信。
  Future<void> requestEmailVerification() =>
      call<void>((client, token) => client.requestEmailVerification(token));

  /// 用六位验证码确认邮箱。
  Future<void> confirmEmailVerification(String code) async {
    await call<void>(
      (client, token) => client.confirmEmailVerification(token, code),
    );
    final session = await store.read();
    if (session != null) {
      await store.save(session.copyWith(emailVerified: true));
    }
  }

  /// 向已验证的邮箱发重设验证码；邮箱没有注册或没有验证时服务端也返回成功。
  Future<void> requestPasswordReset(String email) async {
    final client = await _requireClient();
    await client.requestPasswordReset(email);
  }

  /// 用验证码重设密码；成功后服务端作废全部会话，这里清掉本机登录状态。
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final client = await _requireClient();
    await client.resetPassword(
      email: email,
      code: code,
      newPassword: newPassword,
    );
    await store.clear();
    await preferences.clearSyncState();
  }

  /// 当前账号的访问令牌；过期时先刷新，登录失效时清掉会话并抛出
  /// [AccountSignedOut]。没有登录时返回 null，供模型来源判断是否可用。
  Future<String?> accessTokenOrNull() async {
    final session = await store.read();
    if (session == null || session.isExpired) return null;
    try {
      return (await _fresh(session)).accessToken;
    } catch (_) {
      // 刷新失败（含断网）按暂时不可用处理，回答退回本地兜底。
      return null;
    }
  }

  /// 发一次需要登录的请求；401 时刷新令牌后重试一次。
  Future<T> call<T>(
    Future<T> Function(ServerClient client, String token) action,
  ) async {
    final session = await _requireSession();
    final client = await _requireClient();
    final token = (await _fresh(session)).accessToken;
    try {
      return await action(client, token);
    } on ServerProblem catch (error) {
      if (!error.isUnauthorized) rethrow;
      final retry = await _refreshStale(token);
      return action(client, retry.accessToken);
    }
  }

  /// 把“知新服务”配置补上当前访问令牌；自填 Key 的配置原样返回。
  ///
  /// 选择知新服务但还没有登录时返回 null，让回答按未配置退回本地兜底；界面在
  /// 设置页说明要先登录。
  Future<LlmConfig?> authorizeModelConfig(LlmConfig? stored) async {
    if (stored == null || !stored.isServer) return stored;
    final token = await accessTokenOrNull();
    if (token == null) return null;
    final base = await serverBaseUrl();
    if (base.isEmpty) return null;
    return stored.copyWith(
      api: LlmApi.chat,
      baseUrl: '$base/v1/llm',
      apiKey: token,
    );
  }

  /// 设置页的连接测试与保存前使用：把表单里的知新服务配置补上令牌。
  Future<LlmConfig> prepareModelConfig(LlmConfig config) async {
    if (!config.isServer) return config;
    final authorized = await authorizeModelConfig(config);
    if (authorized == null) throw const AccountSignedOut();
    return authorized;
  }

  Future<ServerQuota> quota() =>
      call<ServerQuota>((client, token) => client.quota(token));

  Future<List<ServerModel>> models() =>
      call<List<ServerModel>>((client, token) => client.models(token));

  /// 当前访问令牌的设备标识，用于同步基线的请求编号。
  Future<String> deviceId() => store.deviceId();

  void dispose() {
    _client?.dispose();
    _client = null;
  }

  Future<AccountSnapshot> _adopt(
    ServerTokens tokens, {
    required String email,
  }) async {
    // 登录响应不带邮箱验证状态，多读一次 /v1/me；读不到不影响这次登录，
    // 账号页下一次打开会再核对。
    var emailVerified = false;
    try {
      final client = await _requireClient();
      emailVerified = (await client.me(tokens.accessToken)).emailVerified;
    } catch (_) {
      // 忽略：首屏仍可进入，验证状态稍后重试。
    }
    final session = AccountSession(
      userId: tokens.userId,
      email: email,
      emailVerified: emailVerified,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessExpiresAt: tokens.accessExpiresAt,
      refreshExpiresAt: tokens.refreshExpiresAt,
    );
    await store.save(session);
    final state = await preferences.syncState();
    if (state != null && state.userId != session.userId) {
      await preferences.clearSyncState();
    }
    return AccountSnapshot(
      serverBaseUrl: await serverBaseUrl(),
      session: session,
      autoSync: await autoSync(),
      usesDefaultServer: await preferences.usesDefaultServerBaseUrl(),
    );
  }

  Future<AccountSession> _requireSession() async {
    final session = await store.read();
    if (session == null) throw const AccountSignedOut();
    if (session.isExpired) {
      await store.clear();
      throw const AccountSignedOut();
    }
    return session;
  }

  /// 访问令牌在到期前一分钟就换新，避免请求发到一半过期。
  Future<AccountSession> _fresh(AccountSession session) {
    final remaining = session.accessExpiresAt.difference(_now());
    if (remaining > const Duration(minutes: 1)) return Future.value(session);
    return _refreshStale(session.accessToken);
  }

  Future<AccountSession> _refreshStale(String usedToken) async {
    final current = await store.read();
    if (current == null) throw const AccountSignedOut();
    // 别的请求已经换过令牌时直接用它，不再拿旧刷新令牌去换。
    if (current.accessToken != usedToken &&
        current.accessExpiresAt.difference(_now()) >
            const Duration(minutes: 1)) {
      return current;
    }
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _refresh(current);
    _refreshing = future;
    return future;
  }

  Future<AccountSession> _refresh(AccountSession current) async {
    try {
      final client = await _requireClient();
      // 一次逻辑刷新只生成一个标识；两次请求都带上它，服务端才把第二次当作
      // 同一次刷新的重试，而不是拿旧刷新令牌盗用。
      final requestId = newUuidV7();
      Future<ServerTokens> attempt() =>
          client.refresh(current.refreshToken, requestId: requestId);
      ServerTokens tokens;
      try {
        tokens = await attempt();
      } on ServerProblem catch (error) {
        if (error.code != 'offline') rethrow;
        // 轮换可能已经在服务端完成、只是响应没有回来；宽限期内换一组新令牌
        // 会被服务端当成盗用并撤销会话，所以只按同一标识重试一次。
        tokens = await attempt();
      }
      final next = current.copyWith(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accessExpiresAt: tokens.accessExpiresAt,
        refreshExpiresAt: tokens.refreshExpiresAt,
      );
      await store.save(next);
      return next;
    } on ServerProblem catch (error) {
      if (error.isUnauthorized) {
        await store.clear();
        throw const AccountSignedOut();
      }
      rethrow;
    } finally {
      _refreshing = null;
    }
  }

  Future<ServerClient> _requireClient() async {
    final base = await serverBaseUrl();
    if (base.isEmpty) {
      throw const AccountConfigException('先在账号页填写服务地址');
    }
    return _clientFor(base);
  }

  ServerClient _clientFor(String baseUrl) {
    final existing = _client;
    if (existing != null) return existing;
    final created =
        clientFactory?.call(baseUrl) ?? ServerClient(baseUrl: baseUrl);
    _client = created;
    return created;
  }
}
