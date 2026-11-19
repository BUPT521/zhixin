import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_config.dart';

/// 测试使用的内存 SecretStore：不碰平台通道。
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// 进程内的假服务端：只实现客户端接云时会用到的路由，按契约返回 JSON 与 problem。
///
/// 测试用来验证登录、令牌刷新、备份、提交序列与附件的往返；服务端自己的行为
/// 由 server/ 下的 Go 用例覆盖，这里不重复实现业务规则。
class FakeServer {
  FakeServer({this.schemaVersion = 27});

  final int schemaVersion;

  final Map<String, String> _passwords = {};
  final Map<String, String> _userIds = {};
  final Set<String> _verified = {};
  final Map<String, _FakeCode> _codes = {};
  int _nextUser = 1;
  int _nextCode = 100000;

  /// 测试取出最近一次发出的验证码；客户端拿不到邮件正文。
  String? codeFor(String email, String purpose) =>
      _codes['$email|$purpose']?.code;

  final Map<String, _Session> _access = {};
  final Map<String, _Session> _refresh = {};

  /// 已经轮换、仍在宽限期内的刷新令牌：记下原请求标识与当时的响应，用来模拟
  /// 服务端把“同一标识的重试”和“旧刷新令牌被盗用”区分开。
  final Map<String, _RefreshReplay> _refreshReplays = {};

  /// 每次刷新请求的刷新令牌与 request_id，用例据此核对重试是否同号。
  final List<({String refreshToken, String requestId})> refreshRequests = [];

  /// 打开之后下一次刷新在服务端完成轮换、但响应在返回客户端之前断开。
  bool dropNextRefreshResponse = false;

  /// 刷新请求先等这个信号再处理；用例用它把刷新卡在途中，模拟切换身份。
  Future<void>? delayRefresh;

  /// 附件上传先等这个信号再处理，用来模拟上传途中切换实例或账号。
  Future<void>? delayBlobUpload;

  /// 登录请求先等这个信号再处理，用来模拟登录途中切换实例。
  Future<void>? delayLogin;

  /// 收到的登录请求次数，配合 [delayLogin] 判断请求已经发出。
  int loginRequests = 0;

  int _nextToken = 1;

  /// 打开之后下一次带令牌的请求返回 401，客户端应当先刷新再重试。
  bool expireAccess = false;

  /// 删除账号时密码错误的次数；用例据此确认密码错误没有触发令牌刷新重试。
  int deleteAttempts = 0;

  final Map<String, List<Map<String, Object?>>> commits = {};
  final Map<String, List<FakeBackup>> backups = {};
  final Map<String, Map<String, Uint8List>> blobs = {};

  /// 单个附件的上限与单账号附件总量上限；为空时不限制，与契约里的两个环境
  /// 变量对应。超限时分别返回 `payload_too_large` 与 `storage_full`。
  int? maxAttachmentBytes;
  int? storageLimitBytes;

  /// 收到的附件 PUT 次数，用例据此确认超限之后没有再上传后面的附件。
  int blobUploadAttempts = 0;

  /// `DELETE /v1/cloud` 的请求次数；[cloudClearConflicts] 控制接下来几次返回
  /// 409，模拟上一次清除还没结束。
  int cloudClearRequests = 0;
  int cloudClearConflicts = 0;

  /// 发布清单与收到的反馈；两者都是公开接口，不需要登录。
  final List<Map<String, Object?>> releases = [];
  final List<Map<String, Object?>> feedbacks = [];

  /// 收到的匿名活跃上报；同样是公开接口。
  final List<Map<String, Object?>> actives = [];

  /// 嵌入请求带的访问令牌，按到达顺序记录；用来核对每次请求都换成了当前令牌。
  final List<String> embeddingTokens = [];

  /// 嵌入当天已用；假服务端按输入字数累计。
  int embeddingUsedTokens = 0;

  /// 打开之后嵌入请求一律返回 429 quota_exceeded。
  bool embeddingQuotaExceeded = false;

  int headOf(String userId) => commits[userId]?.length ?? 0;

  String userIdOf(String email) => _userIds[email]!;

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final method = request.method;
    final isJson =
        (request.headers['content-type'] ?? '').contains('application/json') &&
        request.body.isNotEmpty;
    final body = isJson
        ? (jsonDecode(request.body) as Map).cast<String, Object?>()
        : const <String, Object?>{};

    if (method == 'GET' && path == '/readyz') {
      return _json(200, {'status': 'ready', 'schema_version': schemaVersion});
    }
    if (method == 'POST' && path == '/v1/auth/register') {
      return _register(body);
    }
    if (method == 'POST' && path == '/v1/auth/login') {
      return _login(body);
    }
    if (method == 'POST' && path == '/v1/auth/refresh') {
      return _refreshToken(body);
    }
    if (method == 'POST' && path == '/v1/auth/password/forgot') {
      return _forgotPassword(body);
    }
    if (method == 'POST' && path == '/v1/auth/password/reset') {
      return _resetPassword(body);
    }
    if (method == 'GET' && path == '/v1/app/releases') {
      return _json(200, {'releases': releases});
    }
    if (method == 'POST' && path == '/v1/feedback') {
      final content = (body['content'] as String? ?? '').trim();
      if (content.isEmpty) return _problem(400, 'invalid_request');
      feedbacks.add(body);
      return _json(201, {
        'id': 'feedback-${feedbacks.length}',
        'created_at': '2026-11-18T10:00:00Z',
      });
    }
    if (method == 'POST' && path == '/v1/telemetry/active') {
      final installId = (body['install_id'] as String? ?? '').trim();
      if (installId.length < 16) return _problem(400, 'invalid_request');
      actives.add(body);
      return http.Response('', 204);
    }

    final token = _bearer(request);
    final session = token == null ? null : _access[token];
    if (expireAccess && session != null) {
      expireAccess = false;
      _access.remove(token);
      return _problem(401, 'unauthorized');
    }
    if (session == null) return _problem(401, 'unauthorized');
    final userId = session.userId;

    if (method == 'POST' && path == '/v1/auth/logout') {
      _access.remove(token);
      _refresh.remove(session.refreshToken);
      return http.Response('', 204);
    }
    if (method == 'GET' && path == '/v1/me') {
      final email = _userIds.entries.firstWhere((e) => e.value == userId).key;
      return _json(200, {
        'user_id': userId,
        'email': email,
        'email_verified': _verified.contains(email),
        'created_at': '2026-11-17T10:00:00Z',
      });
    }
    if (method == 'POST' && path == '/v1/auth/email/verify/request') {
      final email = _userIds.entries.firstWhere((e) => e.value == userId).key;
      if (!_verified.contains(email)) {
        _codes['$email|verify_email'] = _newCode();
      }
      return http.Response('', 204);
    }
    if (method == 'POST' && path == '/v1/auth/email/verify/confirm') {
      final email = _userIds.entries.firstWhere((e) => e.value == userId).key;
      if (!_takeCode(email, 'verify_email', body['code'] as String? ?? '')) {
        return _problem(400, 'invalid_code');
      }
      _verified.add(email);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/me') {
      final matches = _userIds.entries
          .where((entry) => entry.value == userId)
          .map((entry) => entry.key);
      final email = matches.isEmpty ? null : matches.first;
      final password = body['password'] as String? ?? '';
      if (password.isEmpty) return _problem(400, 'invalid_request');
      if (email == null || _passwords[email] != password) {
        deleteAttempts++;
        return _problem(401, 'invalid_credentials');
      }
      _userIds.removeWhere((_, id) => id == userId);
      _passwords.remove(email);
      _verified.remove(email);
      _codes.removeWhere((key, _) => key.startsWith('$email|'));
      commits.remove(userId);
      backups.remove(userId);
      blobs.remove(userId);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/backups') {
      backups.remove(userId);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/cloud') {
      cloudClearRequests++;
      if (cloudClearConflicts > 0) {
        cloudClearConflicts--;
        return _problem(409, 'conflict');
      }
      // 一次清空备份、提交序列、附件与遗留对象，可重复调用；账号保留。
      backups.remove(userId);
      commits[userId] = [];
      blobs.remove(userId);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/sync/commits') {
      commits[userId] = [];
      return http.Response('', 204);
    }
    if (method == 'GET' && path == '/v1/sync/head') {
      return _json(200, {
        'head': headOf(userId),
        'schema_version': schemaVersion,
      });
    }
    if (method == 'GET' && path == '/v1/sync/commits') {
      final after =
          int.tryParse(request.url.queryParameters['after'] ?? '0') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '200') ?? 200;
      final log = commits[userId] ?? const [];
      final slice = log.skip(after).take(limit).toList();
      return _json(200, {
        'commits': slice,
        'head': log.length,
        'has_more': after + slice.length < log.length,
      });
    }
    if (method == 'POST' && path == '/v1/sync/commits') {
      final base = (body['base_seq'] as num?)?.toInt() ?? 0;
      final incoming = [
        for (final item in (body['commits'] as List? ?? const []))
          (item as Map).cast<String, Object?>(),
      ];
      final log = commits.putIfAbsent(userId, () => []);
      final seen = {for (final commit in log) commit['request_id']! as String};
      final fresh = [
        for (final commit in incoming)
          if (!seen.contains(commit['request_id'])) commit,
      ];
      if (fresh.isEmpty) return _json(200, {'head': log.length});
      if (base != log.length) {
        return _problem(409, 'conflict', extra: {'head': log.length});
      }
      for (final commit in fresh) {
        log.add({...commit, 'seq': log.length + 1});
      }
      return _json(200, {'head': log.length});
    }
    if (path.startsWith('/v1/blobs/')) {
      final hash = path.substring('/v1/blobs/'.length);
      final userBlobs = blobs.putIfAbsent(userId, () => {});
      if (method == 'PUT') {
        blobUploadAttempts++;
        final gate = delayBlobUpload;
        if (gate != null) await gate;
        final bytes = Uint8List.fromList(request.bodyBytes);
        if (_sha256Hex(bytes) != hash) return _problem(400, 'invalid_request');
        final singleLimit = maxAttachmentBytes;
        if (singleLimit != null && bytes.length > singleLimit) {
          return _problem(413, 'payload_too_large');
        }
        final totalLimit = storageLimitBytes;
        final used = userBlobs.values.fold<int>(
          0,
          (sum, current) => sum + current.length,
        );
        if (totalLimit != null &&
            !userBlobs.containsKey(hash) &&
            used + bytes.length > totalLimit) {
          return _problem(
            413,
            'storage_full',
            extra: {'used_bytes': used, 'limit_bytes': totalLimit},
          );
        }
        userBlobs[hash] = bytes;
        return http.Response('', 201);
      }
      if (method == 'HEAD') {
        final bytes = userBlobs[hash];
        return bytes == null
            ? http.Response('', 404)
            : http.Response(
                '',
                200,
                headers: {'content-length': '${bytes.length}'},
              );
      }
      if (method == 'GET') {
        final bytes = userBlobs[hash];
        return bytes == null
            ? _problem(404, 'not_found')
            : http.Response.bytes(
                bytes,
                200,
                headers: {'x-content-sha256': hash},
              );
      }
    }
    if (path == '/v1/backups') {
      if (method == 'POST') {
        final bytes = Uint8List.fromList(request.bodyBytes);
        final sha = request.headers['x-content-sha256'] ?? '';
        if (request.headers['x-schema-version'] != '$schemaVersion') {
          return _problem(400, 'invalid_request');
        }
        final meta = {
          'id': 'backup-${(_backupSeq++)}',
          'sha256': sha,
          'size': bytes.length,
          'schema_version': schemaVersion,
          // 设备名按 UTF-8 百分号编码放在头里，与服务端一样解码后保存。
          'device_name': Uri.decodeComponent(
            request.headers['x-device-name'] ?? '',
          ),
          'created_at': '2026-11-17T10:00:00Z',
        };
        backups
            .putIfAbsent(userId, () => [])
            .add(FakeBackup(meta: meta, bytes: bytes));
        return _json(201, meta);
      }
      if (method == 'GET') {
        return _json(200, {
          'backups': [
            for (final backup in (backups[userId] ?? const <FakeBackup>[]))
              backup.meta,
          ],
        });
      }
    }
    if (path.startsWith('/v1/backups/')) {
      final id = path.substring('/v1/backups/'.length);
      final list = backups[userId] ?? const <FakeBackup>[];
      final index = list.indexWhere((backup) => backup.meta['id'] == id);
      if (index < 0) return _problem(404, 'not_found');
      if (method == 'DELETE') {
        list.removeAt(index);
        return http.Response('', 204);
      }
      if (method == 'GET') {
        return http.Response.bytes(
          list[index].bytes,
          200,
          headers: {
            'x-content-sha256': list[index].meta['sha256']! as String,
            'x-schema-version': '$schemaVersion',
          },
        );
      }
    }
    if (path == '/v1/llm/quota') {
      return _json(200, {
        'day': '2026-11-17',
        'used_tokens': 0,
        'daily_tokens': 200000,
        'embedding_used_tokens': embeddingUsedTokens,
        'embedding_daily_tokens': 2000000,
      });
    }
    if (path == '/v1/llm/models') {
      return _json(200, {
        'object': 'list',
        'data': [
          {
            'id': 'deepseek-flash',
            'object': 'model',
            'owned_by': 'zhixin',
            'kind': 'chat',
          },
          {
            'id': 'bge-m3',
            'object': 'model',
            'owned_by': 'zhixin',
            'kind': 'embedding',
            'dimensions': 4,
          },
        ],
      });
    }
    if (method == 'POST' && path == '/v1/llm/embeddings') {
      embeddingTokens.add(_bearer(request) ?? '');
      if (embeddingQuotaExceeded) return _problem(429, 'quota_exceeded');
      final input = body['input'];
      final texts = input is String ? [input] : (input as List).cast<String>();
      embeddingUsedTokens += texts.fold(0, (sum, text) => sum + text.length);
      return _json(200, {
        'object': 'list',
        'model': body['model'],
        'data': [
          for (var index = 0; index < texts.length; index++)
            {
              'object': 'embedding',
              'index': index,
              'embedding': [texts[index].length.toDouble(), 1.0, 0.0, 0.0],
            },
        ],
        'usage': {'prompt_tokens': 1, 'total_tokens': 1},
      });
    }
    return _problem(404, 'not_found');
  }

  int _backupSeq = 1;

  http.Response _register(Map<String, Object?> body) {
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    if (_passwords.containsKey(email)) return _problem(409, 'email_taken');
    _passwords[email] = body['password'] as String? ?? '';
    final userId = 'user-${_nextUser++}';
    _userIds[email] = userId;
    return _tokens(userId, body['device_name'] as String? ?? '');
  }

  Future<http.Response> _login(Map<String, Object?> body) async {
    loginRequests++;
    final gate = delayLogin;
    if (gate != null) await gate;
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    if (_passwords[email] == null ||
        _passwords[email] != (body['password'] as String? ?? '')) {
      return _problem(401, 'invalid_credentials');
    }
    return _tokens(_userIds[email]!, body['device_name'] as String? ?? '');
  }

  Future<http.Response> _refreshToken(Map<String, Object?> body) async {
    final refresh = body['refresh_token'] as String? ?? '';
    final requestId = (body['request_id'] as String? ?? '').trim();
    refreshRequests.add((refreshToken: refresh, requestId: requestId));
    final gate = delayRefresh;
    if (gate != null) await gate;
    return _refreshTokenResponse(refresh, requestId);
  }

  http.Response _refreshTokenResponse(String refresh, String requestId) {
    final replay = _refreshReplays[refresh];
    if (replay != null) {
      if (requestId.isEmpty ||
          requestId != replay.requestId ||
          DateTime.now().isAfter(replay.expiresAt)) {
        // 换了标识、没带标识或超过宽限期：按旧刷新令牌被盗用处理，撤销会话。
        _revoke(replay.userId);
        _refreshReplays.remove(refresh);
        return _problem(401, 'unauthorized');
      }
      return replay.response;
    }
    final session = _refresh.remove(refresh);
    if (session == null) return _problem(401, 'unauthorized');
    _access.remove(session.accessToken);
    final response = _tokens(session.userId, '', refresh: false);
    _refreshReplays[refresh] = _RefreshReplay(
      userId: session.userId,
      requestId: requestId,
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      response: response,
    );
    if (dropNextRefreshResponse) {
      dropNextRefreshResponse = false;
      throw http.ClientException('连接在刷新响应返回之前断开');
    }
    return response;
  }

  void _revoke(String userId) {
    _access.removeWhere((_, session) => session.userId == userId);
    _refresh.removeWhere((_, session) => session.userId == userId);
  }

  _FakeCode _newCode() {
    final code = '${_nextCode++}';
    return _FakeCode(
      code: code,
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  bool _takeCode(String email, String purpose, String given) {
    final entry = _codes.remove('$email|$purpose');
    if (entry == null || entry.code != given.trim()) return false;
    return DateTime.now().isBefore(entry.expiresAt);
  }

  http.Response _forgotPassword(Map<String, Object?> body) {
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    if (_passwords.containsKey(email) && _verified.contains(email)) {
      _codes['$email|reset_password'] = _newCode();
    }
    return http.Response('', 204);
  }

  http.Response _resetPassword(Map<String, Object?> body) {
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    final password = body['new_password'] as String? ?? '';
    if (!_passwords.containsKey(email) ||
        !_verified.contains(email) ||
        password.length < 8 ||
        !_takeCode(email, 'reset_password', body['code'] as String? ?? '')) {
      return _problem(400, 'invalid_code');
    }
    _passwords[email] = password;
    final userId = _userIds[email]!;
    _access.removeWhere((_, session) => session.userId == userId);
    _refresh.removeWhere((_, session) => session.userId == userId);
    return http.Response('', 204);
  }

  http.Response _tokens(
    String userId,
    String deviceName, {
    bool refresh = true,
  }) {
    final access = 'access-${_nextToken++}';
    final refreshToken = 'refresh-${_nextToken++}';
    final session = _Session(
      userId: userId,
      accessToken: access,
      refreshToken: refreshToken,
    );
    _access[access] = session;
    if (refresh) _refresh[refreshToken] = session;
    return _json(200, {
      'access_token': access,
      'refresh_token': refreshToken,
      'token_type': 'Bearer',
      'access_expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'refresh_expires_at': DateTime.now()
          .add(const Duration(days: 30))
          .toUtc()
          .toIso8601String(),
      'user_id': userId,
    });
  }

  String? _bearer(http.Request request) {
    final value =
        request.headers['authorization'] ?? request.headers['Authorization'];
    if (value == null || !value.startsWith('Bearer ')) return null;
    return value.substring('Bearer '.length).trim();
  }

  http.Response _json(int status, Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _problem(
    int status,
    String code, {
    Map<String, Object?> extra = const {},
  }) => http.Response(
    jsonEncode({
      'type': 'urn:zhixin:problem:$code',
      'title': code,
      'status': status,
      'code': code,
      'extra': extra,
    }),
    status,
    headers: {'content-type': 'application/problem+json'},
  );
}

class _FakeCode {
  const _FakeCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;
}

class _Session {
  _Session({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
  });

  final String userId;
  final String accessToken;
  final String refreshToken;
}

/// 一次已经完成的刷新：原刷新令牌、请求标识、当时的响应与重试宽限期。
class _RefreshReplay {
  const _RefreshReplay({
    required this.userId,
    required this.requestId,
    required this.expiresAt,
    required this.response,
  });

  final String userId;
  final String requestId;
  final DateTime expiresAt;
  final http.Response response;
}

class FakeBackup {
  FakeBackup({required this.meta, required this.bytes});

  final Map<String, Object?> meta;
  final Uint8List bytes;
}

String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
