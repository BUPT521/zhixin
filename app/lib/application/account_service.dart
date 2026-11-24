import 'dart:async';

import '../ai/llm_config.dart';
import '../data/cloud/account_store.dart';
import '../data/cloud/cloud_preferences_store.dart';
import '../data/cloud/server_client.dart';
import '../domain/models/model_api_key.dart';
import '../domain/models/quota_purchase.dart';
import '../domain/rules/uuid_v7.dart';
import 'embedding_client.dart';

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
    this.profile,
    this.usesDefaultServer = false,
  });

  final String serverBaseUrl;
  final AccountSession? session;

  /// 账号的登录方式列表；资料还没读到时为空，界面按未读到的状态显示。
  final AccountProfile? profile;
  final bool autoSync;

  /// 地址还没有被改过，用的是编译时的默认值。
  final bool usesDefaultServer;

  bool get signedIn => session != null;

  /// 账号页与“我的”显示的一行：第一条登录方式的值。以后加头像时，图片地址也
  /// 从这里取，页面不用改结构。
  String get displayLabel => profile?.displayLabel ?? '';

  /// 至少有一种登录方式已经确认；没有确认时找回密码收不到验证码，托管额度与
  /// 云端写入也不开放。
  bool get contactVerified => profile?.contactVerified ?? false;

  String get serverLabel => serverBaseUrl.isEmpty
      ? '还没有填写服务地址'
      : (usesDefaultServer ? '默认地址：$serverBaseUrl' : serverBaseUrl);
}

/// 账号与登录：注册、登录、刷新令牌、退出、删除账号与请求服务端清除数据。
///
/// 令牌只进 Android Keystore，服务地址与各空间的同步偏好由
/// [CloudPreferencesStore] 保存。所有需要登录的请求经 [call] 发出去，
/// 访问令牌过期时先刷新再重试一次；刷新失败说明登录已经失效，界面要求重登。
class AccountService {
  AccountService({
    required this.store,
    required this.preferences,
    DateTime Function()? now,
    String? deviceName,
    this.clientFactory,
    this.onSyncStateCleared,
    this.acceptsSession,
    this.onSignedIn,
    this.onSignedOut,
    this.onSessionExpired,
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

  /// 同步状态被清掉之后的回调：退出登录、删除账号、清除云端与重设密码都会
  /// 调用。同步服务用它把库里的推送位置改成不阻塞并保留位置，重新登录同一
  /// 账号时仍从原位置继续增量同步（同步方案 3.3）。
  final Future<void> Function()? onSyncStateCleared;

  /// 多个请求同时发现令牌过期时只刷新一次，避免两次刷新互相作废。
  Future<AccountSession>? _refreshing;
  ServerClient? _client;
  bool _disposed = false;

  /// 身份代次：切换服务实例、登录、退出、删除账号与重设密码时加一。
  ///
  /// 刷新与同步在开始时记下代次，完成时发现代次变了就丢弃这次结果，避免把
  /// 旧账号的令牌或位置写到新身份上。
  int _epoch = 0;

  /// 当前实例来源的缓存，避免在界面构建路径上反复读文件。
  String? _origin;

  final bool Function(AccountSession)? acceptsSession;
  final Future<void> Function(AccountSession, AccountProfile?)? onSignedIn;
  final Future<void> Function(bool deleteSpace)? onSignedOut;
  final void Function()? onSessionExpired;

  int get identityEpoch => _epoch;

  void _advanceEpoch() => _epoch++;

  /// 网络往返期间身份代次变了：这次结果属于旧实例或旧账号，直接丢弃。
  void _ensureIdentityUnchanged(int epoch) {
    if (epoch != _epoch) throw const AccountSignedOut();
  }

  /// 当前实例的来源；会话与同步游标都按它与账号一起区分。
  ///
  /// 读出来之后缓存在内存里：界面会在构建与预读里同步式地取会话，如果每次都
  /// 落文件 I/O，测试的假异步区里这个 Future 不会推进，整条读取链就会停住。
  Future<String> serverOrigin() async {
    final cached = _origin;
    if (cached != null) return cached;
    final origin = ServerClient.originOf(await serverBaseUrl());
    _origin = origin;
    return origin;
  }

  /// 只读当前实例的会话：换了实例之后旧会话读不出来，按未登录处理。
  Future<AccountSession?> _readSession() async {
    if (_disposed) return null;
    final session = await store.read(origin: await serverOrigin());
    return session != null && (acceptsSession?.call(session) ?? true)
        ? session
        : null;
  }

  Future<AccountSnapshot> snapshot() async {
    final epoch = _epoch;
    final session = await _readSession();
    final baseUrl = await preferences.serverBaseUrl();
    final autoSync = await preferences.autoSync();
    final usesDefault = await preferences.usesDefaultServerBaseUrl();
    final profile = session == null ? null : await _readProfile(session);
    if (session != null && session.isExpired) {
      await _expireSession(epoch);
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
      profile: profile,
      autoSync: autoSync,
      usesDefaultServer: usesDefault,
    );
  }

  Future<String> serverBaseUrl() => preferences.serverBaseUrl();

  Future<bool> developerMode() => preferences.developerMode();

  Future<void> setDeveloperMode(bool enabled) =>
      preferences.setDeveloperMode(enabled);

  /// 先用无凭据请求确认目标实例就绪且支持当前 schema，再切换服务实例。
  Future<void> configureServerBaseUrl(
    String value, {
    required int schemaVersion,
  }) async {
    if (!await developerMode()) {
      throw const AccountConfigException('请先开启开发者模式');
    }
    final epoch = _epoch;
    final address = ServerClient.normalizeBaseUrl(value);
    final uri = Uri.parse(address);
    if (uri.hasQuery || uri.hasFragment) {
      throw const FormatException('服务地址不能包含查询参数或片段');
    }
    final candidate =
        clientFactory?.call(address) ?? ServerClient(baseUrl: address);
    try {
      final ready = await candidate.ready();
      if (!ready.ready || ready.schemaVersion == 0) {
        throw const AccountConfigException('该地址没有可用的知新服务');
      }
      if (ready.schemaVersion != schemaVersion) {
        throw AccountConfigException(
          '该服务支持 schema ${ready.schemaVersion}，当前客户端使用 $schemaVersion',
        );
      }
    } on FormatException {
      throw const AccountConfigException('该地址没有返回有效的知新服务就绪状态');
    } on ServerProblem catch (error) {
      if (error.code != 'offline') rethrow;
      throw AccountConfigException(error.userMessage);
    } finally {
      candidate.dispose();
    }
    if (!await developerMode()) {
      throw const AccountConfigException('请先开启开发者模式');
    }
    _ensureIdentityUnchanged(epoch);
    await setServerBaseUrl(address);
  }

  /// 保存服务地址；格式不合法时抛出 [FormatException]。
  ///
  /// 换到另一个实例时旧会话与同步游标都不再适用，直接清掉并暂停自动同步：
  /// 恢复自动同步之前要用户确认，避免把数据传到还没确认过的实例上。
  Future<void> setServerBaseUrl(String value) async {
    final normalized = ServerClient.normalizeBaseUrl(value);
    final previousOrigin = ServerClient.originOf(
      await preferences.serverBaseUrl(),
    );
    final nextOrigin = ServerClient.originOf(normalized);
    _origin = nextOrigin;
    await preferences.setServerBaseUrl(normalized);
    _client?.dispose();
    _client = null;
    if (previousOrigin == nextOrigin) return;
    _advanceEpoch();
    await store.clear();
    final signedOut = onSignedOut;
    if (signedOut != null) {
      await signedOut(false);
    } else {
      await _clearSyncState();
      await preferences.setAutoSync(false);
    }
  }

  Future<bool> autoSync() => preferences.autoSync();

  Future<void> setAutoSync(bool value) => preferences.setAutoSync(value);

  /// 注册并登录当前设备；这种登录方式已经被占用时抛出 `identifier_taken`。
  ///
  /// [identifier] 是登录方式的值，服务端负责识别种类并规范化，现在只接受邮箱。
  Future<AccountSnapshot> register({
    required String identifier,
    required String password,
  }) async {
    final epoch = _epoch;
    final client = await _requireClient();
    final tokens = await client.register(
      identifier: identifier.trim().toLowerCase(),
      password: password,
      deviceName: _deviceName,
    );
    _ensureIdentityUnchanged(epoch);
    return _adopt(tokens);
  }

  Future<AccountSnapshot> login({
    required String identifier,
    required String password,
  }) async {
    final epoch = _epoch;
    final client = await _requireClient();
    final tokens = await client.login(
      identifier: identifier.trim().toLowerCase(),
      password: password,
      deviceName: _deviceName,
    );
    _ensureIdentityUnchanged(epoch);
    return _adopt(tokens);
  }

  /// 退出当前设备；服务端不可达时也要清掉本机会话。
  Future<void> logout({bool deleteSpace = false}) async {
    final epoch = _epoch;
    final session = await _readSession();
    if (session != null) {
      try {
        final client = await _requireClient();
        await client.logout(session.accessToken);
      } catch (_) {
        // 退出登录以本机为准：网络失败时服务端会话到期后自然失效。
      }
    }
    // 退出途中换了账号或实例：不能清掉新的登录状态。
    if (epoch != _epoch) return;
    _advanceEpoch();
    await store.clear();
    await onSignedOut?.call(deleteSpace);
  }

  /// 删除账号及其云端数据，并通知应用删除对应的本机空间。
  ///
  /// 服务端要求重新提交当前密码：密码错误时抛出 `invalid_credentials`，本机
  /// 会话与页面状态都不改动，也不刷新令牌重试，避免多消耗一次失败预算。
  Future<void> deleteAccount({required String password}) async {
    final epoch = _epoch;
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
    // 删除请求途中切了账号：不能清掉新会话，也不能当作旧账号已经删除。
    _ensureIdentityUnchanged(epoch);
    _advanceEpoch();
    await store.clear();
    final signedOut = onSignedOut;
    if (signedOut != null) {
      await signedOut(true);
    } else {
      await _clearSyncState();
    }
  }

  /// 清空账号的云端数据并保留会话，调用方随后重建当前本机空间。
  ///
  /// 清空之后服务端位置回到 0，下一次同步需要重新确认后再上传基线。上一次
  /// 清除还没结束时服务端返回 409 `conflict`，调用方按“稍后重试”处理。
  Future<void> clearCloudData({required String password}) async {
    final epoch = _epoch;
    await call<void>(
      (client, token) => client.deleteCloud(token, password: password),
    );
    _ensureIdentityUnchanged(epoch);
    if (onSignedOut == null) await _clearSyncState();
  }

  /// 读当前服务端的就绪状态与它接受的客户端 schema。
  Future<ServerReady> checkServer() async {
    final client = await _requireClient();
    return client.ready();
  }

  /// 重新读一次服务端的账号资料，刷新登录方式列表；网络失败时沿用本机记录。
  Future<AccountSnapshot> refreshAccount() async {
    final epoch = _epoch;
    final session = await _readSession();
    if (session == null) return snapshot();
    try {
      final remote = await call<ServerAccount>(
        (client, token) => client.me(token),
      );
      // 核对途中换了账号或实例：旧账号的资料不能写到新会话上。
      if (epoch != _epoch) return await snapshot();
      final profile = AccountProfile.fromServer(
        remote,
        serverOrigin: session.serverOrigin,
      );
      await store.saveProfile(profile);
      return AccountSnapshot(
        serverBaseUrl: await serverBaseUrl(),
        session: session,
        profile: profile,
        autoSync: await autoSync(),
        usesDefaultServer: await preferences.usesDefaultServerBaseUrl(),
      );
    } catch (_) {
      // 资料是一次额外的核对，失败不影响本机已登录状态。
      return snapshot();
    }
  }

  /// 给指定的登录方式发验证码；已经确认过的服务端不重复发送。
  Future<void> requestIdentityVerification(String identityId) => call<void>(
    (client, token) => client.requestIdentityVerification(token, identityId),
  );

  /// 用六位验证码确认某一种登录方式，成功之后重新读一次资料。
  Future<void> confirmIdentityVerification(
    String identityId,
    String code,
  ) async {
    final epoch = _epoch;
    await call<void>(
      (client, token) =>
          client.confirmIdentityVerification(token, identityId, code),
    );
    _ensureIdentityUnchanged(epoch);
    await refreshAccount();
  }

  /// 向账号登记的登录方式发重设验证码；账号不存在或还没确认时服务端也返回成功。
  Future<void> requestPasswordReset(String identifier) async {
    final client = await _requireClient();
    await client.requestPasswordReset(identifier);
  }

  /// 用验证码重设密码；成功后服务端作废全部会话，这里清掉本机登录状态。
  Future<void> resetPassword({
    required String identifier,
    required String code,
    required String newPassword,
  }) async {
    final epoch = _epoch;
    final client = await _requireClient();
    await client.resetPassword(
      identifier: identifier,
      code: code,
      newPassword: newPassword,
    );
    _ensureIdentityUnchanged(epoch);
    _advanceEpoch();
    await store.clear();
    final signedOut = onSignedOut;
    if (signedOut != null) {
      await signedOut(false);
    } else {
      await _clearSyncState();
    }
  }

  /// 当前账号的访问令牌，过期时先刷新。未登录或刷新失败时返回 null。
  Future<String?> accessTokenOrNull() async =>
      (await _hostedModelEndpoint())?.token;

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
      if (!error.isUnauthorized || error.code == 'invalid_credentials') rethrow;
      final retry = await _refreshStale(token);
      return action(client, retry.accessToken);
    }
  }

  /// 换账号或实例时丢弃旧身份的密钥响应，包括签发凭据和支付宝订单。
  Future<T> _callForCurrentIdentity<T>(
    Future<T> Function(ServerClient client, String token) action,
  ) {
    final epoch = _epoch;
    return call((client, token) async {
      _ensureIdentityUnchanged(epoch);
      try {
        return await action(client, token);
      } finally {
        _ensureIdentityUnchanged(epoch);
      }
    });
  }

  Future<List<ModelApiKey>> apiKeys() =>
      _callForCurrentIdentity((client, token) => client.apiKeys(token));

  Future<String> createApiKey({
    required String name,
    required String password,
  }) => _callForCurrentIdentity(
    (client, token) =>
        client.createApiKey(token, name: name, password: password),
  );

  Future<void> revokeApiKey(String id) => _callForCurrentIdentity(
    (client, token) => client.revokeApiKey(token, id),
  );

  Future<void> revokeAllApiKeys() => _callForCurrentIdentity(
    (client, token) => client.revokeAllApiKeys(token),
  );

  String apiKeyErrorMessage(Object error, {bool issuing = false}) {
    if (error is AccountSignedOut) return '请登录知新账号后管理 API Key';
    if (error is ServerProblem) {
      return switch (error.code) {
        'invalid_credentials' => '当前密码不正确，请重新输入',
        'conflict' when issuing => '有效密钥已达上限，请先撤销一把再申请',
        'offline' when issuing => '未收到签发结果，请刷新列表确认后再试',
        _ => error.userMessage,
      };
    }
    return issuing ? '未取得完整 API Key，请刷新列表确认后再试' : '无法管理 API Key，请稍后重试';
  }

  /// 知新服务的对话接口地址：`<服务地址>/v1/llm/responses`（ADR-0052）。
  static String responsesEndpoint(String base) => '$base/v1/llm/responses';

  /// 知新服务的嵌入接口地址：`<服务地址>/v1/llm`，嵌入客户端在它后面接
  /// `/embeddings` 与 `/embeddings/lookup`。
  static String embeddingsEndpoint(String base) => '$base/v1/llm';

  /// 给模型配置补上知新服务的对话地址与当前访问令牌；没有登录时返回 null。
  ///
  /// 保存的配置里只有模型名、上下文上限与图片开关，地址按
  /// [responsesEndpoint] 现拼，令牌不进 Keystore。没有登录或令牌取不到时返回
  /// null，让回答按未配置退回本地兜底；界面在设置页说明要先登录。
  Future<LlmConfig?> authorizeModelConfig(LlmConfig? stored) async {
    if (stored == null) return null;
    final target = await _hostedModelEndpoint();
    if (target == null) return null;
    return stored.copyWith(
      endpoint: responsesEndpoint(target.base),
      apiKey: target.token,
    );
  }

  /// 设置页的连接测试与保存前使用：把表单里的配置补上地址与令牌。
  Future<LlmConfig> prepareModelConfig(LlmConfig config) async {
    final authorized = await authorizeModelConfig(config);
    if (authorized == null) throw const AccountSignedOut();
    return authorized;
  }

  /// 语义索引选择知新服务时，每次嵌入请求前取服务地址与当前访问令牌。
  ///
  /// 令牌不进配置，过期或轮换之后下一次请求自然换新；没有登录或刷新失败时
  /// 抛 [EmbeddingSourceUnavailable]，索引更新据此停下本次剩余的请求。
  Future<EmbeddingEndpoint> embeddingEndpoint() async {
    final target = await _hostedModelEndpoint();
    if (target == null) {
      throw const EmbeddingSourceUnavailable('当前登录不可用，暂时无法使用知新服务的嵌入');
    }
    return (endpoint: embeddingsEndpoint(target.base), apiKey: target.token);
  }

  /// 一次取到服务地址与当前访问令牌；没有登录或令牌取不到时为 null。
  /// 两类地址由 [responsesEndpoint] 与 [embeddingsEndpoint] 在调用处各自拼出，
  /// 不在这里拼成同一个前缀。
  Future<({String base, String token})?> _hostedModelEndpoint() async {
    final epoch = _epoch;
    final base = await serverBaseUrl();
    if (base.isEmpty) return null;
    final origin = ServerClient.originOf(base);
    final session = await _readSession();
    if (epoch != _epoch ||
        session == null ||
        session.isExpired ||
        session.serverOrigin != origin) {
      return null;
    }
    try {
      final current = await _fresh(session);
      if (epoch != _epoch ||
          _origin != origin ||
          current.serverOrigin != origin) {
        return null;
      }
      return (base: base, token: current.accessToken);
    } catch (_) {
      return null;
    }
  }

  Future<ServerQuota> quota() =>
      call<ServerQuota>((client, token) => client.quota(token));

  Future<QuotaPurchaseOverview> quotaPurchases() =>
      _callForCurrentIdentity((client, token) => client.quotaPurchases(token));

  Future<({QuotaPurchaseOrder order, String orderString})?> quotaCheckout(
    String offerId, {
    String? orderId,
  }) async {
    try {
      return await _callForCurrentIdentity(
        (client, token) =>
            client.quotaCheckout(token, offerId, orderId: orderId),
      );
    } on ServerProblem catch (error) {
      if (error.status == 409) return null;
      rethrow;
    }
  }

  Future<QuotaPurchaseOrder> quotaOrder(String orderId) =>
      _callForCurrentIdentity(
        (client, token) => client.quotaOrder(token, orderId),
      );

  Future<List<ServerModel>> models() =>
      call<List<ServerModel>>((client, token) => client.models(token));

  /// 当前访问令牌的设备标识，用于同步基线的请求编号。
  Future<String> deviceId() => store.deviceId();

  /// 清掉偏好文件里的同步状态，并让同步服务把库里的推送位置改成不阻塞。
  ///
  /// 位置与 scope 保留在库里，由同步服务决定重新登录同一账号时是否继续用；
  /// 这里只负责通知，账号操作本身不依赖回调是否成功。
  Future<void> _clearSyncState() async {
    await preferences.clearSyncState();
    final callback = onSyncStateCleared;
    if (callback == null) return;
    try {
      await callback();
    } catch (_) {
      // 同步位置的簿记失败不影响退出、删除与清除云端这些账号操作。
    }
  }

  void dispose() {
    _disposed = true;
    _advanceEpoch();
    _client?.dispose();
    _client = null;
  }

  Future<AccountSnapshot> _adopt(ServerTokens tokens) async {
    final epoch = _epoch;
    // 会话绑定到签发它的实例：来源在请求之前读好，网络往返期间切换实例时
    // 下面的代次检查会丢弃这次登录结果。
    final origin = await serverOrigin();
    // 登录响应不带登录方式列表，多读一次 /v1/me；读不到不影响这次登录，账号页
    // 下一次打开会再读。
    final profile = await _fetchProfile(
      tokens.accessToken,
      tokens.userId,
      origin,
    );
    _ensureIdentityUnchanged(epoch);
    final session = AccountSession(
      userId: tokens.userId,
      serverOrigin: origin,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessExpiresAt: tokens.accessExpiresAt,
      refreshExpiresAt: tokens.refreshExpiresAt,
    );
    _advanceEpoch();
    await store.save(session);
    if (profile != null) await store.saveProfile(profile);
    final signedIn = onSignedIn;
    if (signedIn != null) {
      final result = AccountSnapshot(
        serverBaseUrl: await serverBaseUrl(),
        session: session,
        profile: profile,
        autoSync: await autoSync(),
      );
      await signedIn(session, profile);
      return result;
    }
    final state = await preferences.syncState();
    final identity = '${session.serverOrigin}|${session.userId}';
    final lastIdentity = await preferences.lastIdentity();
    await preferences.setLastIdentity(identity);
    final switched = lastIdentity.isNotEmpty && lastIdentity != identity;
    if (switched) {
      // 换了一个账号（或实例）：旧账号的同步位置不能用，自动同步先暂停，
      // 等用户在账号页确认之后再恢复。
      await _clearSyncState();
      await preferences.setAutoSync(false);
    } else if (state != null &&
        (state.userId != session.userId ||
            state.serverOrigin != session.serverOrigin)) {
      await _clearSyncState();
    }
    return AccountSnapshot(
      serverBaseUrl: await serverBaseUrl(),
      session: session,
      profile: profile,
      autoSync: await autoSync(),
      usesDefaultServer: await preferences.usesDefaultServerBaseUrl(),
    );
  }

  /// 读一次账号资料；网络失败或服务端不可达时返回 null，登录本身照常完成。
  Future<AccountProfile?> _fetchProfile(
    String accessToken,
    String userId,
    String origin,
  ) async {
    try {
      final client = await _requireClient();
      final remote = await client.me(accessToken);
      return AccountProfile.fromServer(remote, serverOrigin: origin);
    } catch (_) {
      return null;
    }
  }

  /// 读本机的资料，只认与会话同一个账号、同一个实例的那一份。
  Future<AccountProfile?> _readProfile(AccountSession session) async {
    final profile = await store.readProfile(origin: session.serverOrigin);
    if (profile == null || profile.userId != session.userId) return null;
    return profile;
  }

  Future<AccountSession> _requireSession() async {
    final epoch = _epoch;
    final session = await _readSession();
    if (session == null) throw const AccountSignedOut();
    if (session.isExpired) {
      await _expireSession(epoch);
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
    final current = await _readSession();
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
    final epoch = _epoch;
    try {
      final client = await _requireClient();
      _ensureIdentityUnchanged(epoch);
      if (ServerClient.originOf(client.baseUrl) != current.serverOrigin) {
        throw const AccountSignedOut();
      }
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
      // 刷新期间换了账号或实例：这次结果属于旧身份，不写回。
      if (epoch != _epoch) throw const AccountSignedOut();
      final next = current.copyWith(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        accessExpiresAt: tokens.accessExpiresAt,
        refreshExpiresAt: tokens.refreshExpiresAt,
      );
      await store.save(next);
      return next;
    } on ServerProblem catch (error) {
      if (error.isUnauthorized && epoch == _epoch) {
        await _expireSession(epoch);
        throw const AccountSignedOut();
      }
      rethrow;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _expireSession(int epoch) async {
    if (epoch != _epoch) return;
    _advanceEpoch();
    await store.clear();
    onSessionExpired?.call();
  }

  Future<ServerClient> _requireClient() async {
    final base = await serverBaseUrl();
    if (base.isEmpty) {
      throw const AccountConfigException('请在设置的开发者模式中填写知新服务地址');
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
