import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 服务端的一次拒绝：`application/problem+json` 里的 `code` 是分支依据，
/// `detail` 只给开发者看，界面按 [userMessage] 给出说明。
class ServerProblem implements Exception {
  const ServerProblem({
    required this.code,
    required this.status,
    this.detail = '',
    this.extra = const {},
    this.retryAfterSeconds,
  });

  /// 请求没有到达服务端，或连接中途断开。
  const ServerProblem.offline(this.detail)
    : code = 'offline',
      status = 0,
      extra = const {},
      retryAfterSeconds = null;

  final String code;
  final int status;
  final String detail;

  /// 409 时的最新 `head`、400 时的 `schema_version` 等附加信息。
  final Map<String, Object?> extra;
  final int? retryAfterSeconds;

  bool get isUnauthorized => status == 401;
  bool get isConflict => status == 409;

  /// 给界面看的一句说明；未知错误保持笼统，不把 `detail` 带进界面。
  String get userMessage => switch (code) {
    'offline' => '无法连接服务端，请检查网络与服务地址',
    'unauthorized' => '登录状态已失效，请重新登录',
    'invalid_credentials' => '邮箱或密码不正确',
    'invalid_code' => '验证码不正确或已经过期，可以重新获取',
    'identifier_taken' => '这个邮箱已经注册过，可以直接登录',
    'rate_limited' =>
      retryAfterSeconds == null
          ? '尝试过于频繁，请稍后再试'
          : '尝试过于频繁，请 $retryAfterSeconds 秒后再试',
    'payload_too_large' =>
      extra['resource'] == 'sync' ? '单条同步提交超过服务端允许的大小' : '文件超过服务端允许的大小',
    'contact_unverified' => '请先在账号页验证一种登录方式',
    'history_compacted' => '云端历史已经压缩，暂时不能按云端修复这台设备',
    'storage_full' => _storageFullMessage,
    'conflict' => '云端数据已经变化，请先同步再试',
    'model_not_allowed' => '服务端不允许使用这个模型',
    'quota_exceeded' => '今日模型额度已经用完，可以改用自己的 API Key',
    'not_found' => '云端没有这条记录',
    'invalid_request' => '服务端没有接受这次请求',
    'redirect_blocked' => '服务地址发生了跨域跳转，已停止这次请求',
    'unavailable' || 'upstream_failed' => '服务端暂时不可用，请稍后再试',
    'not_implemented' => '服务端还没有实现这个操作',
    _ => '服务端没有完成这次请求',
  };

  /// 附件总量超限时把服务端给出的已用与上限写成一句说明；数字缺失时只说明
  /// 空间已满，不编造额度。
  String get _storageFullMessage {
    if (extra['resource'] == 'sync') {
      return '云端同步空间已满，仍可在本机使用和备份学习记录';
    }
    final used = _byteCount(extra['used_bytes']);
    final limit = _byteCount(extra['limit_bytes']);
    if (used == null || limit == null) {
      return '云端附件空间已满，请先清理云端数据或删掉不再需要的附件';
    }
    return '云端附件空间已满：已用 ${_formatBytes(used)}，上限 ${_formatBytes(limit)}';
  }

  static int? _byteCount(Object? value) => switch (value) {
    num number => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  String toString() => 'ServerProblem($status $code): $detail';
}

/// 服务端返回的一种登录方式。
class ServerIdentity {
  const ServerIdentity({
    required this.id,
    required this.kind,
    required this.identifier,
    this.verified = false,
  });

  factory ServerIdentity.fromJson(Map<String, Object?> json) => ServerIdentity(
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    identifier: json['identifier'] as String? ?? '',
    verified: json['verified'] == true,
  );

  final String id;

  /// `email`、`phone` 或 `wechat`，与契约的 `IdentityKind` 一致。
  final String kind;
  final String identifier;

  /// 这种登录方式是否已经用验证码确认。
  final bool verified;
}

/// 登录后的账号信息与它的登录方式。
class ServerAccount {
  const ServerAccount({
    required this.userId,
    this.identities = const [],
    this.createdAt,
  });

  factory ServerAccount.fromJson(Map<String, Object?> json) => ServerAccount(
    userId: json['user_id'] as String? ?? '',
    identities: [
      for (final item in (json['identities'] as List? ?? const []))
        if (item is Map) ServerIdentity.fromJson(item.cast<String, Object?>()),
    ],
    createdAt: _parseTime(json['created_at']),
  );

  final String userId;
  final List<ServerIdentity> identities;
  final DateTime? createdAt;

  /// 至少有一种登录方式已经确认；托管额度与云端写入按它判断。
  bool get contactVerified => identities.any((identity) => identity.verified);

  /// 账号页与提示里显示的一行：优先取已确认的登录方式，没有时取第一条。
  String get displayLabel {
    for (final identity in identities) {
      if (identity.verified) return identity.identifier;
    }
    return identities.isEmpty ? '' : identities.first.identifier;
  }
}

/// 一组访问令牌与刷新令牌；刷新时服务端会同时换掉两枚。
class ServerTokens {
  const ServerTokens({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  factory ServerTokens.fromJson(Map<String, Object?> json) => ServerTokens(
    userId: json['user_id'] as String? ?? '',
    accessToken: json['access_token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String? ?? '',
    accessExpiresAt: _parseTime(json['access_expires_at']) ?? DateTime.now(),
    refreshExpiresAt:
        _parseTime(json['refresh_expires_at']) ??
        DateTime.now().add(const Duration(days: 30)),
  );

  final String userId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
}

/// 构建时是否允许 http 服务地址：正式包默认关闭，只在本机联调时用
/// `--dart-define=ZHIXIN_ALLOW_INSECURE_SERVER=true` 显式打开。
const bool allowInsecureServer = bool.fromEnvironment(
  'ZHIXIN_ALLOW_INSECURE_SERVER',
  defaultValue: false,
);

/// AOT 正式构建的标记；debug 构建与 `flutter test` 都不是正式包。
const bool _isReleaseBuild = bool.fromEnvironment('dart.vm.product');

/// 正式构建强制 https；debug 构建与显式打开的联调开关允许 http。
bool get serverRequiresHttps => _isReleaseBuild && !allowInsecureServer;

/// 提交序列里的一条行级变化；`before`/`after` 是客户端版本值的原始 JSON。
class ServerChange {
  const ServerChange({
    required this.table,
    required this.rowKey,
    required this.op,
    this.before,
    this.after,
  });

  factory ServerChange.fromJson(Map<String, Object?> json) => ServerChange(
    table: json['table'] as String? ?? '',
    rowKey: json['row_key'] as String? ?? '',
    op: json['op'] as String? ?? '',
    before: (json['before'] as Map?)?.cast<String, Object?>(),
    after: (json['after'] as Map?)?.cast<String, Object?>(),
  );

  final String table;
  final String rowKey;

  /// `insert` / `update` / `delete`。
  final String op;
  final Map<String, Object?>? before;
  final Map<String, Object?>? after;

  Map<String, Object?> toJson() => {
    'table': table,
    'row_key': rowKey,
    'op': op,
    if (before != null) 'before': before,
    if (after != null) 'after': after,
  };
}

/// 服务端保存的一条提交；`seq` 由服务端分配，推送时忽略客户端给的值。
///
/// [stateDigest] 是可选的整库摘要：只有推送完成、本机没有待推送提交时，最后
/// 一条提交才带它，服务端原样保存、不解析，拉取时原样带回。其他设备据此比较
/// 本机摘要（同步方案 3.5）。
class ServerCommit {
  const ServerCommit({
    required this.requestId,
    required this.deviceId,
    required this.schemaVersion,
    required this.actor,
    required this.action,
    required this.changes,
    this.seq,
    this.createdAt,
    this.receivedAt,
    this.stateDigest,
  });

  factory ServerCommit.fromJson(Map<String, Object?> json) => ServerCommit(
    seq: (json['seq'] as num?)?.toInt(),
    requestId: json['request_id'] as String? ?? '',
    deviceId: json['device_id'] as String? ?? '',
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
    actor: json['actor'] as String? ?? 'user',
    action: json['action'] as String? ?? '',
    createdAt: json['created_at'] as String?,
    receivedAt: json['received_at'] as String?,
    stateDigest: json['state_digest'] as String?,
    changes: [
      for (final item in (json['changes'] as List? ?? const []))
        if (item is Map) ServerChange.fromJson(item.cast<String, Object?>()),
    ],
  );

  final int? seq;
  final String requestId;
  final String deviceId;
  final int schemaVersion;
  final String actor;
  final String action;
  final String? createdAt;
  final String? receivedAt;
  final String? stateDigest;
  final List<ServerChange> changes;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'device_id': deviceId,
    'schema_version': schemaVersion,
    'actor': actor,
    'action': action,
    'created_at': createdAt,
    if (stateDigest != null) 'state_digest': stateDigest,
    'changes': [for (final change in changes) change.toJson()],
  };
}

/// 一页远端提交与它到达的服务端位置。
class ServerCommitPage {
  const ServerCommitPage({
    required this.commits,
    required this.head,
    required this.hasMore,
  });

  factory ServerCommitPage.fromJson(Map<String, Object?> json) =>
      ServerCommitPage(
        commits: [
          for (final item in (json['commits'] as List? ?? const []))
            if (item is Map)
              ServerCommit.fromJson(item.cast<String, Object?>()),
        ],
        head: (json['head'] as num?)?.toInt() ?? 0,
        hasMore: json['has_more'] == true,
      );

  final List<ServerCommit> commits;
  final int head;
  final bool hasMore;
}

/// 服务端的就绪状态与它接受的客户端 schema 版本。
class ServerReady {
  const ServerReady({required this.ready, required this.schemaVersion});

  factory ServerReady.fromJson(Map<String, Object?> json) => ServerReady(
    ready: json['status'] == 'ready',
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
  );

  final bool ready;
  final int schemaVersion;
}

/// 服务端序列的最新位置与它接受的客户端 schema 版本。
class ServerHead {
  const ServerHead({required this.head, required this.schemaVersion});

  factory ServerHead.fromJson(Map<String, Object?> json) => ServerHead(
    head: (json['head'] as num?)?.toInt() ?? 0,
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
  );

  final int head;
  final int schemaVersion;
}

/// 云端一份整库备份的元数据。
class ServerBackup {
  const ServerBackup({
    required this.id,
    required this.sha256,
    required this.size,
    required this.schemaVersion,
    required this.deviceName,
    this.createdAt,
  });

  factory ServerBackup.fromJson(Map<String, Object?> json) => ServerBackup(
    id: json['id'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
    deviceName: json['device_name'] as String? ?? '',
    createdAt: _parseTime(json['created_at']),
  );

  final String id;
  final String sha256;
  final int size;
  final int schemaVersion;
  final String deviceName;
  final DateTime? createdAt;
}

/// 今天的模型用量与额度；聊天与嵌入分开计。
class ServerQuota {
  const ServerQuota({
    required this.day,
    required this.usedTokens,
    required this.dailyTokens,
    this.embeddingUsedTokens = 0,
    this.embeddingDailyTokens = 0,
  });

  factory ServerQuota.fromJson(Map<String, Object?> json) => ServerQuota(
    day: json['day'] as String? ?? '',
    usedTokens: (json['used_tokens'] as num?)?.toInt() ?? 0,
    dailyTokens: (json['daily_tokens'] as num?)?.toInt() ?? 0,
    embeddingUsedTokens: (json['embedding_used_tokens'] as num?)?.toInt() ?? 0,
    embeddingDailyTokens:
        (json['embedding_daily_tokens'] as num?)?.toInt() ?? 0,
  );

  final String day;

  /// 聊天当天已用与每日额度。
  final int usedTokens;
  final int dailyTokens;

  /// 嵌入当天已用与每日额度；旧版服务端没有这两项，读作 0。
  final int embeddingUsedTokens;
  final int embeddingDailyTokens;
}

/// 服务端模型的用途：聊天模型给回答用，嵌入模型给语义索引用。
enum ServerModelKind {
  chat('chat'),
  embedding('embedding');

  const ServerModelKind(this.value);

  final String value;

  /// 旧版服务端不带 `kind`，那时只有聊天模型，按聊天处理；不认识的值返回
  /// null，调用方跳过这一项。
  static ServerModelKind? fromValue(Object? value) {
    if (value == null) return ServerModelKind.chat;
    for (final kind in values) {
      if (kind.value == value) return kind;
    }
    return null;
  }
}

/// 服务端代理允许的一个模型。
class ServerModel {
  const ServerModel(
    this.id, {
    this.kind = ServerModelKind.chat,
    this.dimensions,
  });

  final String id;
  final ServerModelKind kind;

  /// 嵌入模型的向量维度；后台没有配置时为空，由用户在本机填写。
  final int? dimensions;

  bool get isChat => kind == ServerModelKind.chat;

  bool get isEmbedding => kind == ServerModelKind.embedding;
}

/// 发布清单里的一项；是否需要更新由界面比较 [version] 与 [build] 决定，
/// 服务端只给数据（ADR-0025）。
class ServerRelease {
  const ServerRelease({
    required this.platform,
    required this.version,
    required this.build,
    required this.url,
    this.publishedAt = '',
    this.sha256 = '',
    this.signature = '',
    this.size = 0,
    this.minVersion = '',
    this.notes = '',
  });

  factory ServerRelease.fromJson(Map<String, Object?> json) => ServerRelease(
    platform: json['platform'] as String? ?? '',
    version: json['version'] as String? ?? '',
    build: (json['build'] as num?)?.toInt() ?? 0,
    url: json['url'] as String? ?? '',
    publishedAt: json['published_at'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    signature: json['signature'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    minVersion: json['min_version'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
  );

  final String platform;
  final String version;
  final int build;
  final String url;
  final String publishedAt;

  /// 安装包的 SHA-256，契约要求 64 位小写十六进制。
  final String sha256;

  /// 对 [sha256] 十六进制字符串的 Ed25519 签名（base64）。
  final String signature;
  final int size;
  final String minVersion;
  final String notes;
}

/// 提交反馈之后的回执。
class ServerFeedbackReceipt {
  const ServerFeedbackReceipt({required this.id, this.createdAt});

  factory ServerFeedbackReceipt.fromJson(Map<String, Object?> json) =>
      ServerFeedbackReceipt(
        id: json['id'] as String? ?? '',
        createdAt: _parseTime(json['created_at']),
      );

  final String id;
  final DateTime? createdAt;
}

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

  Future<ServerHead> head(String accessToken) async {
    final json = await _json('GET', '/v1/sync/head', accessToken: accessToken);
    return ServerHead.fromJson(json);
  }

  Future<ServerCommitPage> pull(
    String accessToken, {
    int after = 0,
    int limit = 200,
  }) async {
    final json = await _json(
      'GET',
      '/v1/sync/commits',
      accessToken: accessToken,
      query: {'after': '$after', 'limit': '$limit'},
    );
    return ServerCommitPage.fromJson(json);
  }

  /// 基于 `baseSeq` 推送一批提交；服务端位置已经变化时抛出 `conflict`，
  /// `extra['head']` 给出最新位置。
  Future<int> push(
    String accessToken, {
    required int baseSeq,
    required List<ServerCommit> commits,
  }) async {
    final json = await _json(
      'POST',
      '/v1/sync/commits',
      accessToken: accessToken,
      body: {
        'base_seq': baseSeq,
        'commits': [for (final commit in commits) commit.toJson()],
      },
    );
    return (json['head'] as num?)?.toInt() ?? baseSeq;
  }

  Future<List<ServerBackup>> backupList(String accessToken) async {
    final json = await _json('GET', '/v1/backups', accessToken: accessToken);
    return [
      for (final item in (json['backups'] as List? ?? const []))
        if (item is Map) ServerBackup.fromJson(item.cast<String, Object?>()),
    ];
  }

  Future<ServerBackup> backupUpload(
    String accessToken, {
    required Uint8List bytes,
    required String sha256,
    required int schemaVersion,
    required String deviceName,
  }) async {
    final json = await _json(
      'POST',
      '/v1/backups',
      accessToken: accessToken,
      bodyBytes: bytes,
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
    return ServerBackup.fromJson(json);
  }

  /// 下载备份的原始字节；服务端给出的哈希与大小由调用方核对。
  Future<http.Response> backupDownload(String accessToken, String id) =>
      _raw('GET', '/v1/backups/$id', accessToken: accessToken);

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

  ServerProblem _problem(http.Response response) {
    var code = response.statusCode == 401 ? 'unauthorized' : 'internal';
    var detail = 'HTTP ${response.statusCode}';
    Map<String, Object?> extra = const {};
    int? retryAfter;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
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
    final retry = response.headers['retry-after'];
    if (retry != null) retryAfter = int.tryParse(retry.trim());
    return ServerProblem(
      code: code,
      status: response.statusCode,
      detail: detail,
      extra: extra,
      retryAfterSeconds: retryAfter,
    );
  }
}

DateTime? _parseTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}
