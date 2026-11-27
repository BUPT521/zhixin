import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/model_api_key.dart';
import '../../domain/models/quota_purchase.dart';
import '../../domain/models/server_models.dart';

/// 自建 API 服务的最小客户端：只拼 HTTP、解 JSON 与把错误统一成
/// [ServerProblem]，令牌的保存、刷新与重试由账号服务负责。
///
/// 地址只填域名时补 `https://`；路径按契约拼在服务地址之后，服务端部署在
/// 反向代理的子路径下时也能用。
class ServerClient {
  ServerClient({
    required String baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : baseUrl = normalizeBaseUrl(baseUrl),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;
  final bool _ownsHttpClient;

  /// 规范化服务地址：去掉末尾斜杠，只接受 http 与 https。
  ///
  /// 正式构建默认只接受 https；http 需要构建时显式打开联调开关。
  /// [requireHttps] 只给测试核对正式包的判定，生产调用不传。
  static String normalizeBaseUrl(String raw, {bool? requireHttps}) {
    var value = raw.trim();
    if (value.isEmpty) throw const FormatException('服务地址不能为空');
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('服务地址格式不正确');
    }
    if (uri.userInfo.isNotEmpty) {
      // 地址里带用户名或密码会随请求与日志外泄，服务地址只接受不含凭据的地址。
      throw const FormatException('服务地址不能包含用户名或密码');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('服务地址只支持 http 与 https');
    }
    if ((requireHttps ?? serverRequiresHttps) && uri.scheme != 'https') {
      throw const FormatException(
        '正式版只接受 https 服务地址；本地联调需要使用 http 时，'
        '在构建时显式打开不安全地址开关',
      );
    }
    final normalized = uri.toString().replaceAll(RegExp(r'/+$'), '');
    return normalized;
  }

  /// 服务地址的来源（协议、主机与端口）；账号会话与同步游标按它区分实例。
  static String originOf(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) return baseUrl.trim();
    return uri.origin;
  }

  /// 读一次就绪检查；依赖不可用时服务端返回 503，客户端按 [ServerProblem] 抛出。
  Future<ServerReady> ready() async {
    final json = await _json('GET', '/readyz');
    return ServerReady.fromJson(json);
  }

  /// 注册并登录当前设备；这种登录方式已经被占用时抛出 `identifier_taken`。
  ///
  /// [identifier] 是登录方式的值，服务端负责识别种类并规范化，现在只接受邮箱。
  Future<ServerTokens> register({
    required String identifier,
    required String password,
    String deviceName = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/auth/register',
      body: {
        'identifier': identifier,
        'password': password,
        if (deviceName.isNotEmpty) 'device_name': deviceName,
      },
    );
    return ServerTokens.fromJson(json);
  }

  Future<ServerTokens> login({
    required String identifier,
    required String password,
    String deviceName = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/auth/login',
      body: {
        'identifier': identifier,
        'password': password,
        if (deviceName.isNotEmpty) 'device_name': deviceName,
      },
    );
    return ServerTokens.fromJson(json);
  }

  /// 用刷新令牌换一组新令牌；旧的两枚立即失效。
  ///
  /// [requestId] 是这次逻辑刷新的标识，网络在响应回来之前断开时用同一个标识与
  /// 旧刷新令牌重试，服务端才按重试处理；换一个标识重试会被当成盗用并撤销会话。
  Future<ServerTokens> refresh(String refreshToken, {String? requestId}) async {
    final json = await _json(
      'POST',
      '/v1/auth/refresh',
      body: {
        'refresh_token': refreshToken,
        if (requestId != null && requestId.trim().isNotEmpty)
          'request_id': requestId.trim(),
      },
    );
    return ServerTokens.fromJson(json);
  }

  Future<void> logout(String accessToken) =>
      _send('POST', '/v1/auth/logout', accessToken: accessToken);

  Future<ServerAccount> me(String accessToken) async {
    final json = await _json('GET', '/v1/me', accessToken: accessToken);
    return ServerAccount.fromJson(json);
  }

  static const _apiKeysPath = '/v1/me/api-keys';

  Future<List<ModelApiKey>> apiKeys(String accessToken) async {
    final json = await _json('GET', _apiKeysPath, accessToken: accessToken);
    return [
      for (final row in (json['keys'] as List).cast<Map<String, Object?>>())
        ModelApiKey(
          id: row['id'] as String,
          name: row['name'] as String,
          prefix: row['prefix'] as String,
          revoked: row['revoked'] as bool,
          createdAt: DateTime.parse(row['created_at'] as String),
          lastUsedAt: DateTime.tryParse(row['last_used_at'] as String? ?? ''),
        ),
    ];
  }

  Future<String> createApiKey(
    String accessToken, {
    required String name,
    required String password,
  }) async {
    final json = await _json(
      'POST',
      _apiKeysPath,
      accessToken: accessToken,
      body: {'name': name, 'password': password},
    );
    final key = json['key'];
    if (key is! String || key.isEmpty) {
      throw const FormatException('签发响应中缺少完整密钥');
    }
    return key;
  }

  Future<void> revokeApiKey(String accessToken, String id) => _send(
    'DELETE',
    '$_apiKeysPath/${Uri.encodeComponent(id)}',
    accessToken: accessToken,
  );

  Future<void> revokeAllApiKeys(String accessToken) =>
      _send('DELETE', _apiKeysPath, accessToken: accessToken);

  /// 删除账号，连同同步序列、附件、备份与用量；删除前必须重新提交当前密码。
  ///
  /// 密码错误返回 401 `invalid_credentials`，与其他失败共用账号的失败预算。
  Future<void> deleteMe(String accessToken, {required String password}) =>
      _send(
        'DELETE',
        '/v1/me',
        accessToken: accessToken,
        body: {'password': password},
      );

  /// 给指定的登录方式发验证码；已经确认过的服务端返回 204，不重复发送。
  Future<void> requestIdentityVerification(
    String accessToken,
    String identityId,
  ) => _send(
    'POST',
    '/v1/me/identities/$identityId/verification',
    accessToken: accessToken,
  );

  /// 用六位验证码确认指定的登录方式。
  Future<void> confirmIdentityVerification(
    String accessToken,
    String identityId,
    String code,
  ) => _send(
    'POST',
    '/v1/me/identities/$identityId/verification/confirm',
    accessToken: accessToken,
    body: {'code': code},
  );

  /// 向账号登记的登录方式发送重设验证码；账号不存在时服务端同样返回 204。
  Future<void> requestPasswordReset(String identifier) => _send(
    'POST',
    '/v1/auth/password/forgot',
    body: {'identifier': identifier.trim().toLowerCase()},
  );

  /// 用验证码重设密码；成功后这个账号的全部会话都被作废。
  Future<void> resetPassword({
    required String identifier,
    required String code,
    required String newPassword,
  }) => _send(
    'POST',
    '/v1/auth/password/reset',
    body: {
      'identifier': identifier.trim().toLowerCase(),
      'code': code,
      'new_password': newPassword,
    },
  );

  /// 删除该账号的全部云端备份，账号保留。
  Future<void> deleteAllBackups(
    String accessToken, {
    required String password,
  }) => _send(
    'DELETE',
    '/v1/backups',
    accessToken: accessToken,
    body: {'password': password},
  );

  /// 一次清空该账号的全部云端数据：备份、提交序列、附件与对象存储里遗留的字节。
  ///
  /// 可重复调用；上一次清除还没结束时服务端返回 409 `conflict`，稍后重试即可。
  Future<void> deleteCloud(String accessToken, {required String password}) =>
      _send(
        'DELETE',
        '/v1/cloud',
        accessToken: accessToken,
        body: {'password': password},
      );

  /// 清空该账号的同步序列，服务端位置回到 0；账号与备份保留。
  Future<void> deleteSyncLog(String accessToken, {required String password}) =>
      _send(
        'DELETE',
        '/v1/sync/commits',
        accessToken: accessToken,
        body: {'password': password},
      );

  /// 服务端序列的最新位置、保留下界与当前快照。
  ///
  /// [deviceId] 是本机设备标识，随同步请求发在 `X-Device-Id` 里；服务端据此更新
  /// 账号级设备名册，并按能力声明决定压缩门槛是否要等这台设备（ADR-0048）。
  Future<ServerHead> head(String accessToken, {String deviceId = ''}) async {
    final json = await _json(
      'GET',
      '/v1/sync/head',
      accessToken: accessToken,
      headers: _syncHeaders(deviceId),
    );
    return ServerHead.fromJson(json);
  }

  /// 账号最近出现过的设备，按最近出现时间倒序。
  ///
  /// 设备接口同样接受设备标识与能力声明，带上本机的两个头可以把这台设备记进
  /// 名册，因此还没有同步过的新设备也能在账号页看到（ADR-0048）。
  Future<List<ServerDevice>> devices(
    String accessToken, {
    String deviceId = '',
  }) async {
    final json = await _json(
      'GET',
      '/v1/sync/devices',
      accessToken: accessToken,
      headers: _syncHeaders(deviceId),
    );
    return [
      for (final item in (json['devices'] as List? ?? const []))
        if (item is Map) ServerDevice.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// 改一台设备的别名，返回服务端保存之后的设备对象。
  ///
  /// 别名去掉首尾空白之后 0–64 字符，空串表示清除；只能改本账号名册里已有的
  /// 设备，未知设备返回 404 `not_found`。改名不改写已经推送的提交（ADR-0048）。
  Future<ServerDevice> renameDevice(
    String accessToken, {
    required String deviceId,
    required String alias,
  }) async {
    final json = await _json(
      'PUT',
      '/v1/sync/devices',
      accessToken: accessToken,
      body: {'device_id': deviceId, 'alias': alias.trim()},
    );
    return ServerDevice.fromJson(json);
  }

  /// 读当前快照指针；与 [head] 同形，没有登记过快照时 [ServerHead.snapshot] 为空。
  Future<ServerHead> snapshot(String accessToken) async {
    final json = await _json(
      'GET',
      '/v1/sync/snapshot',
      accessToken: accessToken,
    );
    return ServerHead.fromJson(json);
  }

  /// 登记当前序列位置上的快照：`seq` 是覆盖到的位置，`sha256` 是已经上传的
  /// 快照附件，`digest` 是整库摘要。位置比已经登记的快照小时服务端返回 409
  /// `conflict`（`extra.snapshot_seq` 给出当前位置），相同位置按幂等重试接受。
  Future<ServerHead> registerSnapshot(
    String accessToken, {
    required int seq,
    required String sha256,
    required String digest,
    String deviceId = '',
  }) async {
    final json = await _json(
      'PUT',
      '/v1/sync/snapshot',
      accessToken: accessToken,
      body: {'seq': seq, 'sha256': sha256, 'digest': digest},
      headers: _syncHeaders(deviceId),
    );
    return ServerHead.fromJson(json);
  }

  /// 拉取一页提交。`after` 落在已经压缩的区间时抛 [SyncHistoryCompacted]，
  /// 调用方据此下载快照、把本机换成快照内容之后从快照位置继续拉取。
  Future<ServerCommitPage> pull(
    String accessToken, {
    int after = 0,
    int limit = 200,
    String deviceId = '',
  }) async {
    try {
      final json = await _json(
        'GET',
        '/v1/sync/commits',
        accessToken: accessToken,
        query: {'after': '$after', 'limit': '$limit'},
        headers: _syncHeaders(deviceId),
      );
      return ServerCommitPage.fromJson(json);
    } on ServerProblem catch (error) {
      if (!error.isHistoryCompacted) rethrow;
      throw SyncHistoryCompacted.fromProblem(error);
    }
  }

  /// 基于 `baseSeq` 推送一批提交；服务端位置已经变化时抛出 `conflict`，
  /// `extra['head']` 给出最新位置。
  ///
  /// 响应里的 `seqs` 与请求的提交按条数与顺序一一对应，被当作重复跳过的提交
  /// 回它原来的序号；客户端据此记下每条本机提交的云端序号，并判断整批是不是
  /// 重放（ADR-0054 决定第 2 条）。
  Future<ServerPushResult> push(
    String accessToken, {
    required int baseSeq,
    required List<ServerCommit> commits,
    String deviceId = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/sync/commits',
      accessToken: accessToken,
      body: {
        'base_seq': baseSeq,
        'commits': [for (final commit in commits) commit.toJson()],
      },
      headers: _syncHeaders(deviceId),
    );
    return ServerPushResult(
      head: (json['head'] as num?)?.toInt() ?? baseSeq,
      seqs: [
        for (final item in (json['seqs'] as List? ?? const []))
          if (item is num) item.toInt(),
      ],
    );
  }

  /// 账号的全部命名版本，包括墓碑（ADR-0054 决定第 4 条）。
  Future<List<SyncRefRow>> refs(String accessToken) async {
    final json = await _json('GET', '/v1/sync/refs', accessToken: accessToken);
    return [
      for (final item in (json['refs'] as List? ?? const []))
        if (item is Map) SyncRefRow.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// 写入一个命名版本；比已存删除时间更早的写入不复活名字，此时返回已存的墓碑。
  Future<SyncRefRow> putRef(
    String accessToken, {
    required String name,
    required String commitUid,
    String note = '',
    DateTime? sourceUpdatedAt,
  }) async {
    final json = await _json(
      'PUT',
      '/v1/sync/refs',
      accessToken: accessToken,
      body: {
        'name': name,
        'commit_uid': commitUid,
        'note': note,
        if (sourceUpdatedAt != null)
          'source_updated_at': sourceUpdatedAt.toUtc().toIso8601String(),
      },
    );
    return SyncRefRow.fromJson(json);
  }

  /// 删除一个命名版本，服务端留下墓碑；之后别的设备推回这个名字也不会复活。
  Future<SyncRefRow> deleteRef(
    String accessToken, {
    required String name,
  }) async {
    final json = await _json(
      'PUT',
      '/v1/sync/refs',
      accessToken: accessToken,
      body: {'name': name, 'delete': true},
    );
    return SyncRefRow.fromJson(json);
  }

  Future<List<ServerBackup>> backupList(String accessToken) async {
    final json = await _json('GET', '/v1/backups', accessToken: accessToken);
    return [
      for (final item in (json['backups'] as List? ?? const []))
        if (item is Map) ServerBackup.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// 上传整库备份：请求体从文件流读，内存占用不随备份大小增长。
  ///
  /// [sha256] 由调用方先在同一个文件上分块算出，服务端按它与字节数记账。请求体
  /// 只能消费一次，所以这里不跟随重定向：备份接口固定在服务地址上，出现重定向
  /// 按服务地址配置错误拒绝。
  Future<ServerBackup> backupUpload(
    String accessToken, {
    required File file,
    required String sha256,
    required int schemaVersion,
    required String deviceName,
  }) async {
    final response = await _sendFile(
      'POST',
      '/v1/backups',
      accessToken: accessToken,
      file: file,
      headers: {
        'Content-Type': 'application/zip',
        'X-Content-SHA256': sha256,
        'X-Schema-Version': '$schemaVersion',
        if (deviceName.isNotEmpty)
          // HTTP 头只接受 ASCII：设备名默认带中文，按 UTF-8 百分号编码再发，
          // 服务端解码后保存原文。
          'X-Device-Name': Uri.encodeComponent(deviceName),
      },
    );
    final bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _problemFrom(response.statusCode, response.headers, bytes);
    }
    if (bytes.isEmpty) return ServerBackup.fromJson(const {});
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw ServerProblem(code: 'invalid_request', status: response.statusCode);
    }
    return ServerBackup.fromJson(decoded.cast<String, Object?>());
  }

  /// 把一份备份下载到 [target]：边收边写、边算 SHA-256，不在内存里攒整包。
  ///
  /// 成功时保留 [target] 并返回字节数与哈希；服务端拒绝、超时、连接中断、写入
  /// 失败或校验值不一致时删掉 [target]，调用方在失败路径上不会拿到半个包。
  Future<BackupDownload> backupDownloadTo(
    String accessToken,
    String id,
    File target,
  ) async {
    final origin = Uri.parse(baseUrl).origin;
    var uri = _uri('/v1/backups/$id');
    try {
      for (var redirects = 0; ; redirects++) {
        final request = http.Request('GET', uri)..followRedirects = false;
        if (accessToken.trim().isNotEmpty) {
          request.headers['Authorization'] = 'Bearer ${accessToken.trim()}';
        }
        final response = await _sendStreamedRequest(request);
        final location = response.headers['location'];
        final isRedirect = const {
          301,
          302,
          303,
          307,
          308,
        }.contains(response.statusCode);
        if (isRedirect && location != null && location.trim().isNotEmpty) {
          await response.stream.drain<void>();
          if (redirects >= _maxRedirects) {
            throw ServerProblem(
              code: 'redirect_blocked',
              status: response.statusCode,
              detail: '重定向次数超过上限',
            );
          }
          final next = uri.resolve(location.trim());
          if (next.origin != origin) {
            throw ServerProblem(
              code: 'redirect_blocked',
              status: response.statusCode,
              detail: '拒绝跟随跨域重定向',
            );
          }
          uri = next;
          continue;
        }
        if (response.statusCode != 200) {
          throw _problemFrom(
            response.statusCode,
            response.headers,
            await response.stream.toBytes(),
          );
        }
        return await _writeDownload(response, target);
      }
    } catch (_) {
      await _deleteQuietly(target);
      rethrow;
    }
  }

  Future<void> backupDelete(String accessToken, String id) =>
      _send('DELETE', '/v1/backups/$id', accessToken: accessToken);

  /// 附件是否已经上传；已存在时返回字节数。
  Future<int?> blobExists(String accessToken, String sha256) async {
    final response = await _raw(
      'HEAD',
      '/v1/blobs/$sha256',
      accessToken: accessToken,
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw _problem(response);
    return int.tryParse(response.headers['content-length'] ?? '');
  }

  Future<Uint8List> blobDownload(String accessToken, String sha256) async {
    final response = await _raw(
      'GET',
      '/v1/blobs/$sha256',
      accessToken: accessToken,
    );
    if (response.statusCode != 200) throw _problem(response);
    return response.bodyBytes;
  }

  Future<void> blobUpload(
    String accessToken,
    String sha256,
    Uint8List bytes,
  ) async {
    await _send(
      'PUT',
      '/v1/blobs/$sha256',
      accessToken: accessToken,
      bodyBytes: bytes,
      headers: {'Content-Type': 'application/octet-stream'},
    );
  }

  Future<ServerQuota> quota(String accessToken) async {
    final json = await _json('GET', '/v1/llm/quota', accessToken: accessToken);
    return ServerQuota.fromJson(json);
  }

  static const _quotaPurchasePath = '/v1/me/model-quota-purchases';

  Future<QuotaPurchaseOverview> quotaPurchases(String accessToken) async {
    final json = await _json(
      'GET',
      _quotaPurchasePath,
      accessToken: accessToken,
    );
    final product = json['product'] as Map<String, Object?>?;
    final latest = json['latest_purchase'] as Map<String, Object?>?;
    return QuotaPurchaseOverview(
      balancePoints: (json['balance_points'] as num?)?.toInt() ?? 0,
      balanceUnavailable: json['balance_unavailable'] == true,
      tokensPerPoint: (json['tokens_per_point'] as num?)?.toInt(),
      product: product == null ? null : _quotaProduct(product),
      latestPurchase: latest == null ? null : _quotaLink(latest),
    );
  }

  /// 取一张托管购买页的链接。传 skuId 锁定档位，不传由用户在购买页选择。
  ///
  /// [clientRequestNo] 是客户端每次点击生成的幂等键：同一个键重试复用同一张链接，
  /// 换一次点击换一个键就一定拿新链接；不传时服务端每次生成随机键，等同每次新链接
  /// （ADR-0074）。键最长 64 个字符，这里只发去掉首尾空白之后非空的值。
  Future<QuotaPurchaseLink> quotaPurchaseLink(
    String accessToken, {
    String? skuId,
    String? clientRequestNo,
  }) async {
    final requestNo = clientRequestNo?.trim() ?? '';
    final json = await _json(
      'POST',
      _quotaPurchasePath,
      accessToken: accessToken,
      body: {
        'sku_id': ?skuId,
        if (requestNo.isNotEmpty) 'client_request_no': requestNo,
      },
    );
    return _quotaLink(json);
  }

  Future<QuotaBalance> quotaBalance(String accessToken) async {
    final json = await _json(
      'GET',
      '$_quotaPurchasePath/quota',
      accessToken: accessToken,
    );
    return QuotaBalance(
      remaining: json['remaining'] as int,
      total: json['total'] as int,
      used: json['used'] as int,
    );
  }

  static QuotaPurchaseProduct _quotaProduct(Map<String, Object?> json) =>
      QuotaPurchaseProduct(
        capabilityStatus: json['capability_status'] as String,
        billingMode: json['billing_mode'] as String,
        quotaUnit: json['quota_unit'] as String,
        options: [
          for (final option in (json['options'] as List? ?? const []))
            if (option is Map<String, Object?>)
              QuotaPurchaseOption(
                skuId: option['sku_id'] as String,
                displayName: option['display_name'] as String,
                price: option['price'] as String,
                quotaAmount: option['quota_amount'] as int,
              ),
        ],
      );

  static QuotaPurchaseLink _quotaLink(Map<String, Object?> json) =>
      QuotaPurchaseLink(
        outRequestNo: json['out_request_no'] as String,
        purchaseUrl: json['purchase_url'] as String,
        skuId: json['sku_id'] as String?,
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );

  Future<List<ServerModel>> models(String accessToken) async {
    final json = await _json('GET', '/v1/llm/models', accessToken: accessToken);
    final models = <ServerModel>[];
    for (final item in (json['data'] as List? ?? const [])) {
      if (item is! Map || item['id'] is! String) continue;
      final kind = ServerModelKind.fromValue(item['kind']);
      if (kind == null) continue;
      final dimensions = item['dimensions'];
      models.add(
        ServerModel(
          item['id']! as String,
          kind: kind,
          dimensions: dimensions is int && dimensions > 0 ? dimensions : null,
        ),
      );
    }
    return models;
  }

  /// 读发布清单；不需要登录，没有配置清单时返回空列表。界面按平台取一项，
  /// 再比较 [ServerRelease.version] 与 [ServerRelease.build] 决定是否提示更新。
  Future<List<ServerRelease>> releases() async {
    final json = await _json('GET', '/v1/app/releases');
    return [
      for (final item in (json['releases'] as List? ?? const []))
        if (item is Map) ServerRelease.fromJson(item.cast<String, Object?>()),
    ];
  }

  /// 提交一条应用内反馈；不需要登录，也不会带上访问令牌。联系邮箱、版本、
  /// 平台与诊断摘要都可以留空，服务端只在非空时保存。
  Future<ServerFeedbackReceipt> sendFeedback({
    required String content,
    String contact = '',
    String appVersion = '',
    String platform = 'android',
    String diagnostics = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/feedback',
      body: {
        'content': content,
        if (contact.trim().isNotEmpty) 'contact': contact.trim(),
        if (appVersion.isNotEmpty) 'app_version': appVersion,
        if (platform.isNotEmpty) 'platform': platform,
        if (diagnostics.trim().isNotEmpty) 'diagnostics': diagnostics,
      },
    );
    return ServerFeedbackReceipt.fromJson(json);
  }

  /// 匿名上报一次活跃，配合 ADR-0019 的留存统计；不需要登录，服务端按收到的
  /// 自然日去重，同一天重复调用不会多记。安装标识由调用方生成并保存在应用私有
  /// 目录，属于统计分析，不进入学习记录与备份。
  Future<void> reportActive({
    required String installId,
    String appVersion = '',
    String platform = 'android',
  }) => _send(
    'POST',
    '/v1/telemetry/active',
    body: {
      'install_id': installId,
      if (appVersion.isNotEmpty) 'app_version': appVersion,
      if (platform.isNotEmpty) 'platform': platform,
    },
  );

  void dispose() {
    if (_ownsHttpClient) _http.close();
  }

  /// 当前客户端声明的同步能力，与契约里的能力名一致。
  static const String syncCapabilitySnapshot = 'snapshot';

  /// 同步与名册请求共用的两个头：本机设备标识与能力声明。
  ///
  /// 头值只能是 ASCII：设备标识是 UUID 文本，能力名是小写英文，因此不用像备份的
  /// 设备名那样做百分号编码。服务端按它们把设备记进账号级名册（ADR-0048）。
  Map<String, String> _syncHeaders(String deviceId) {
    final id = deviceId.trim();
    return {
      if (id.isNotEmpty) 'X-Device-Id': id,
      'X-Sync-Capabilities': syncCapabilitySnapshot,
    };
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    String? accessToken,
    Object? body,
    Uint8List? bodyBytes,
    Map<String, String> headers = const {},
    Map<String, String>? query,
  }) async {
    final response = await _raw(
      method,
      path,
      accessToken: accessToken,
      body: body,
      bodyBytes: bodyBytes,
      headers: headers,
      query: query,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _problem(response);
    }
    if (response.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const ServerProblem(code: 'invalid_request', status: 200);
    }
    return decoded.cast<String, Object?>();
  }

  Future<void> _send(
    String method,
    String path, {
    String? accessToken,
    Object? body,
    Uint8List? bodyBytes,
    Map<String, String> headers = const {},
    Map<String, String>? query,
  }) async {
    final response = await _raw(
      method,
      path,
      accessToken: accessToken,
      body: body,
      bodyBytes: bodyBytes,
      headers: headers,
      query: query,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _problem(response);
    }
  }

  /// 一次跳转的上限，与 package:http 的默认值一致。
  static const int _maxRedirects = 5;

  Future<http.Response> _raw(
    String method,
    String path, {
    String? accessToken,
    Object? body,
    Uint8List? bodyBytes,
    Map<String, String> headers = const {},
    Map<String, String>? query,
  }) async {
    final serverOrigin = Uri.parse(baseUrl).origin;
    var currentMethod = method;
    var currentUri = _uri(path, query);
    var currentBody = body;
    var currentBytes = bodyBytes;
    for (var redirects = 0; ; redirects++) {
      final request = http.Request(currentMethod, currentUri);
      if (accessToken != null && accessToken.trim().isNotEmpty) {
        request.headers['Authorization'] = 'Bearer ${accessToken.trim()}';
      }
      request.headers.addAll(headers);
      if (currentBody != null) {
        request.headers['Content-Type'] = 'application/json';
        request.bodyBytes = utf8.encode(jsonEncode(currentBody));
      } else if (currentBytes != null) {
        request.bodyBytes = currentBytes;
      }
      // 不交给 http 自动跟随：带令牌的请求只在同源跳转上继续，跨域一律当作失败。
      request.followRedirects = false;
      final response = await _sendRequest(request);
      final location = response.headers['location'];
      final isRedirect = const {
        301,
        302,
        303,
        307,
        308,
      }.contains(response.statusCode);
      if (!isRedirect || location == null || location.trim().isEmpty) {
        return response;
      }
      if (redirects >= _maxRedirects) {
        throw ServerProblem(
          code: 'redirect_blocked',
          status: response.statusCode,
          detail: '重定向次数超过上限',
        );
      }
      final target = currentUri.resolve(location.trim());
      if (target.origin != serverOrigin) {
        throw ServerProblem(
          code: 'redirect_blocked',
          status: response.statusCode,
          detail: '拒绝跟随跨域重定向',
        );
      }
      // 301、302、303 按浏览器惯例改成 GET；307、308 保留方法与请求体。
      if (response.statusCode != 307 && response.statusCode != 308) {
        currentMethod = currentMethod == 'HEAD' ? 'HEAD' : 'GET';
        currentBody = null;
        currentBytes = null;
      }
      currentUri = target;
    }
  }

  Future<http.Response> _sendRequest(http.Request request) async {
    try {
      final streamed = await _http.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException catch (_) {
      throw const ServerProblem.offline('请求超时');
    } on SocketException catch (error) {
      throw ServerProblem.offline(error.message);
    } on http.ClientException catch (error) {
      throw ServerProblem.offline(error.message);
    }
  }

  /// 发送一个请求体来自文件的请求。响应头与请求体并行处理：边读文件边发，
  /// 读文件或发送中断时按 [ServerProblem.offline] 处理。
  Future<http.StreamedResponse> _sendFile(
    String method,
    String path, {
    String? accessToken,
    required File file,
    Map<String, String> headers = const {},
  }) async {
    final request = http.StreamedRequest(method, _uri(path));
    request.contentLength = await file.length();
    if (accessToken != null && accessToken.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${accessToken.trim()}';
    }
    request.headers.addAll(headers);
    final responseFuture = _sendStreamedRequest(request);
    Object? writeError;
    final wrote = file.openRead().pipe(request.sink).catchError((Object error) {
      writeError = error;
    });
    http.StreamedResponse response;
    try {
      response = await responseFuture;
    } catch (_) {
      // 服务端没有应答时先关掉请求体：没有听众的流会把文件越攒越多，
      // 关闭之后上游的写入立即失败，不必把整个文件读完。
      unawaited(request.sink.close().catchError((Object _) {}));
      await wrote;
      rethrow;
    }
    await wrote;
    if (writeError != null &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      throw ServerProblem.offline('上传中断：$writeError');
    }
    return response;
  }

  Future<http.StreamedResponse> _sendStreamedRequest(
    http.BaseRequest request,
  ) async {
    try {
      return await _http.send(request).timeout(timeout);
    } on TimeoutException catch (_) {
      throw const ServerProblem.offline('请求超时');
    } on SocketException catch (error) {
      throw ServerProblem.offline(error.message);
    } on http.ClientException catch (error) {
      throw ServerProblem.offline(error.message);
    }
  }

  /// 把响应体写到 [target]，同时算 SHA-256 与字节数。
  ///
  /// 声明了 `Content-Length` 或 `X-Content-SHA256` 时逐一核对：两者都是流式下载
  /// 能拿到的完整性依据，不一致说明传输被截断或被改写。
  Future<BackupDownload> _writeDownload(
    http.StreamedResponse response,
    File target,
  ) async {
    final declared = response.headers['x-content-sha256'];
    final declaredLength = response.contentLength;
    final digest = _DigestSink();
    final input = sha256.startChunkedConversion(digest);
    final sink = target.openWrite();
    var length = 0;
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        length += chunk.length;
        input.add(chunk);
        sink.add(chunk);
      }
      input.close();
      await sink.flush();
    } on TimeoutException {
      throw const ServerProblem.offline('请求超时');
    } on SocketException catch (error) {
      throw ServerProblem.offline(error.message);
    } on http.ClientException catch (error) {
      throw ServerProblem.offline(error.message);
    } finally {
      try {
        await sink.close();
      } catch (_) {
        // 句柄在这里释放，写入错误由上面的分支或调用方的校验处理。
      }
    }
    if (declaredLength != null && declaredLength != length) {
      throw const ServerProblem.offline('下载不完整：字节数与服务端声明不一致');
    }
    final actual = digest.value.toString();
    if (declared != null && declared.isNotEmpty && declared != actual) {
      throw const FormatException('云端备份下载不完整，校验值不一致');
    }
    return BackupDownload(
      length: length,
      sha256: actual,
      declaredSha256: declared,
    );
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉不影响这次调用的结果，调用方下次会覆盖同名临时文件。
    }
  }

  ServerProblem _problem(http.Response response) =>
      _problemFrom(response.statusCode, response.headers, response.bodyBytes);

  ServerProblem _problemFrom(
    int status,
    Map<String, String> headers,
    List<int> bodyBytes,
  ) {
    var code = status == 401 ? 'unauthorized' : 'internal';
    var detail = 'HTTP $status';
    Map<String, Object?> extra = const {};
    int? retryAfter;
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map) {
        final map = decoded.cast<String, Object?>();
        if (map['code'] is String) code = map['code']! as String;
        if (map['detail'] is String) detail = map['detail']! as String;
        if (map['extra'] is Map) {
          extra = (map['extra']! as Map).cast<String, Object?>();
        }
      }
    } catch (_) {
      // 非 problem+json 的响应保留状态码。
    }
    final retry = headers['retry-after'];
    if (retry != null) retryAfter = int.tryParse(retry.trim());
    return ServerProblem(
      code: code,
      status: status,
      detail: detail,
      extra: extra,
      retryAfterSeconds: retryAfter,
    );
  }
}

/// 收下 [sha256.startChunkedConversion] 在 `close` 时产出的唯一摘要。
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) throw StateError('摘要还没有产出');
    return digest;
  }

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
