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
    'email_taken' => '这个邮箱已经注册过，可以直接登录',
    'rate_limited' =>
      retryAfterSeconds == null
          ? '尝试过于频繁，请稍后再试'
          : '尝试过于频繁，请 $retryAfterSeconds 秒后再试',
    'payload_too_large' => '文件超过服务端允许的大小',
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

  @override
  String toString() => 'ServerProblem($status $code): $detail';
}

/// 登录后的账号信息。
class ServerAccount {
  const ServerAccount({
    required this.userId,
    required this.email,
    this.emailVerified = false,
    this.createdAt,
  });

  factory ServerAccount.fromJson(Map<String, Object?> json) => ServerAccount(
    userId: json['user_id'] as String? ?? '',
    email: json['email'] as String? ?? '',
    emailVerified: json['email_verified'] == true,
    createdAt: _parseTime(json['created_at']),
  );

  final String userId;
  final String email;

  /// 邮箱是否已经用验证码确认；未确认时找回密码收不到重设验证码。
  final bool emailVerified;
  final DateTime? createdAt;
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
  final List<ServerChange> changes;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'device_id': deviceId,
    'schema_version': schemaVersion,
    'actor': actor,
    'action': action,
    'created_at': createdAt,
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

/// 今天的模型用量与额度。
class ServerQuota {
  const ServerQuota({
    required this.day,
    required this.usedTokens,
    required this.dailyTokens,
  });

  factory ServerQuota.fromJson(Map<String, Object?> json) => ServerQuota(
    day: json['day'] as String? ?? '',
    usedTokens: (json['used_tokens'] as num?)?.toInt() ?? 0,
    dailyTokens: (json['daily_tokens'] as num?)?.toInt() ?? 0,
  );

  final String day;
  final int usedTokens;
  final int dailyTokens;
}

/// 服务端代理允许的模型列表。
class ServerModel {
  const ServerModel(this.id);

  final String id;
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
    size: (json['size'] as num?)?.toInt() ?? 0,
    minVersion: json['min_version'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
  );

  final String platform;
  final String version;
  final int build;
  final String url;
  final String publishedAt;
  final String sha256;
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

  /// 注册并登录当前设备；邮箱已被占用时抛出 `email_taken`。
  Future<ServerTokens> register({
    required String email,
    required String password,
    String deviceName = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/auth/register',
      body: {
        'email': email,
        'password': password,
        if (deviceName.isNotEmpty) 'device_name': deviceName,
      },
    );
    return ServerTokens.fromJson(json);
  }

  Future<ServerTokens> login({
    required String email,
    required String password,
    String deviceName = '',
  }) async {
    final json = await _json(
      'POST',
      '/v1/auth/login',
      body: {
        'email': email,
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

  /// 给当前账号的邮箱发验证码；已经确认时服务端返回 204，不重复发信。
  Future<void> requestEmailVerification(String accessToken) =>
      _send('POST', '/v1/auth/email/verify/request', accessToken: accessToken);

  /// 用六位验证码确认当前账号的邮箱。
  Future<void> confirmEmailVerification(String accessToken, String code) =>
      _send(
        'POST',
        '/v1/auth/email/verify/confirm',
        accessToken: accessToken,
        body: {'code': code},
      );

  /// 向已验证的邮箱发重设验证码；邮箱不存在或未验证时服务端同样返回 204。
  Future<void> requestPasswordReset(String email) => _send(
    'POST',
    '/v1/auth/password/forgot',
    body: {'email': email.trim().toLowerCase()},
  );

  /// 用验证码重设密码；成功后这个账号的全部会话都被作废。
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) => _send(
    'POST',
    '/v1/auth/password/reset',
    body: {
      'email': email.trim().toLowerCase(),
      'code': code,
      'new_password': newPassword,
    },
  );

  /// 删除该账号的全部云端备份，账号保留。
  Future<void> deleteAllBackups(String accessToken) =>
      _send('DELETE', '/v1/backups', accessToken: accessToken);

  /// 清空该账号的同步序列，服务端位置回到 0；账号与备份保留。
  Future<void> deleteSyncLog(String accessToken) =>
      _send('DELETE', '/v1/sync/commits', accessToken: accessToken);

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
        if (deviceName.isNotEmpty) 'X-Device-Name': deviceName,
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
    return [
      for (final item in (json['data'] as List? ?? const []))
        if (item is Map && item['id'] is String)
          ServerModel(item['id']! as String),
    ];
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
