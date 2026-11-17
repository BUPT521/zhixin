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
  int _nextToken = 1;

  /// 打开之后下一次带令牌的请求返回 401，客户端应当先刷新再重试。
  bool expireAccess = false;

  final Map<String, List<Map<String, Object?>>> commits = {};
  final Map<String, List<FakeBackup>> backups = {};
  final Map<String, Map<String, Uint8List>> blobs = {};

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
      _userIds.removeWhere((_, id) => id == userId);
      if (email != null) {
        _passwords.remove(email);
        _verified.remove(email);
        _codes.removeWhere((key, _) => key.startsWith('$email|'));
      }
      commits.remove(userId);
      backups.remove(userId);
      blobs.remove(userId);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/backups') {
      backups.remove(userId);
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
        final bytes = Uint8List.fromList(request.bodyBytes);
        if (_sha256Hex(bytes) != hash) return _problem(400, 'invalid_request');
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
          'device_name': request.headers['x-device-name'] ?? '',
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
      });
    }
    if (path == '/v1/llm/models') {
      return _json(200, {
        'object': 'list',
        'data': [
          {'id': 'deepseek-flash', 'object': 'model', 'owned_by': 'zhixin'},
        ],
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

  http.Response _login(Map<String, Object?> body) {
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    if (_passwords[email] == null ||
        _passwords[email] != (body['password'] as String? ?? '')) {
      return _problem(401, 'invalid_credentials');
    }
    return _tokens(_userIds[email]!, body['device_name'] as String? ?? '');
  }

  http.Response _refreshToken(Map<String, Object?> body) {
    final refresh = body['refresh_token'] as String? ?? '';
    final session = _refresh.remove(refresh);
    if (session == null) return _problem(401, 'unauthorized');
    _access.remove(session.accessToken);
    return _tokens(session.userId, '', refresh: false);
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

class FakeBackup {
  FakeBackup({required this.meta, required this.bytes});

  final Map<String, Object?> meta;
  final Uint8List bytes;
}

String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
