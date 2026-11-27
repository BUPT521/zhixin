import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/data/db/app_database.dart' show zhixinSchemaVersion;
import 'package:zhixin/data/db/drift/tables.dart' show revisionKinds;

/// 契约里提交类型的合法取值：与客户端 `RevisionKind` 的取值一致，没有
/// `remote`（审查 S23、V18）。
final Set<String> _commitKinds = {...revisionKinds};

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
  FakeServer({this.schemaVersion = zhixinSchemaVersion});

  final int schemaVersion;

  final Map<String, String> _passwords = {};
  final Map<String, String> _userIds = {};
  // 假服务端每个账号只有一条邮箱登录方式，key 是账号 id。
  final Map<String, String> _identityIds = {};
  final Set<String> _verified = {};
  final Map<String, _FakeCode> _codes = {};
  int _nextUser = 1;
  int _nextCode = 100000;

  /// 测试取出最近一次发出的验证码；客户端拿不到邮件正文。
  String? codeFor(String identifier, String purpose) =>
      _codes['$identifier|$purpose']?.code;

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

  /// 接下来几次推送（`POST /v1/sync/commits`）返回 503 `unavailable`。
  ///
  /// 用例用它模拟“拉取成功、推送失败”：断网、限流与三次 409 之后都可能停在
  /// 这个状态，下一轮同步不能把被覆盖的旧提交再推一次。
  int pushFailures = 0;

  /// 收到 `GET /v1/sync/head` 之前调用的回调。
  ///
  /// 用例用它模拟“同步途中用户又写了一次”：拉取已经应用、推送还没开始算，
  /// 这时写下的提交是同步过程中新产生的本机修改。
  Future<void> Function()? onHead;

  /// 收到 `GET /v1/sync/commits`（拉取）之前调用的回调。
  Future<void> Function()? onPull;

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

  /// 每个账号已经压缩删除到哪个序号：保留下界等于它加一（ADR-0043）。
  final Map<String, int> trimmedThrough = {};

  /// 每个账号当前登记的快照指针；没有登记时为空。
  final Map<String, FakeSnapshot> snapshots = {};

  /// 每个账号的设备名册，key 是设备标识；按请求头记录最近出现时间与能力。
  final Map<String, Map<String, FakeDevice>> devices = {};

  /// 收到的同步请求头，按到达顺序记录：方法、路径、设备标识与能力声明。
  ///
  /// 只记录带 `X-Device-Id` 的请求，用例据此核对四个同步请求都带了两个头。
  final List<
    ({String method, String path, String deviceId, List<String> capabilities})
  >
  syncDeviceHeaders = [];

  /// 名册里设备的最近出现时间按这个计数递增，用例里的先后顺序因此确定。
  int _deviceTicks = 0;

  /// 直接往名册里放一台设备，不经过同步请求：用例用它构造“账号里已有设备”。
  void putDevice(
    String userId, {
    required String deviceId,
    String alias = '',
    List<String> capabilities = const ['snapshot'],
    int syncedSeq = 0,
    String lastSeen = '2026-11-20T10:00:00Z',
  }) {
    devices.putIfAbsent(userId, () => {})[deviceId] = FakeDevice(
      deviceId: deviceId,
      alias: alias,
      capabilities: capabilities,
      syncedSeq: syncedSeq,
      lastSeen: lastSeen,
    );
  }

  /// 账号当前名册，按最近出现时间倒序，最多 50 条。
  List<FakeDevice> rosterOf(String userId) {
    final values = (devices[userId] ?? const <String, FakeDevice>{}).values
        .toList();
    values.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return values.take(50).toList();
  }

  /// 收到的快照登记请求次数，用例据此确认有没有重复登记。
  int snapshotRegistrations = 0;

  /// 接下来几次快照登记返回 503 `unavailable`，用来验证登记失败只记诊断。
  int snapshotFailures = 0;

  /// 接下来几次读取设备名册返回 503 `unavailable`，用来验证读取失败只记诊断。
  int deviceListFailures = 0;

  /// 打开之后快照登记一律返回 409：模拟服务端已有更新的快照。
  bool snapshotAlwaysConflicts = false;

  /// head 响应里声明的压缩开关，默认打开：压缩关闭时客户端不上传整库快照
  /// （ADR-0047）。用例按需关掉它来核对客户端确实没有上传与登记。
  bool compact = true;

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

  /// 保留下界：第一条仍然可以拉取的序号，没有压缩过时为 1。
  int earliestSeqOf(String userId) => (trimmedThrough[userId] ?? 0) + 1;

  /// 账号当前快照指针。
  FakeSnapshot? snapshotOf(String userId) => snapshots[userId];

  /// 模拟保留期到达之后服务端删掉到 [through] 为止的提交。
  void compactThrough(String userId, int through) {
    final current = trimmedThrough[userId] ?? 0;
    if (through > current) trimmedThrough[userId] = through;
  }

  /// 直接登记一份快照，不经过接口：用例用它构造“云端已经有一份快照”的前置状态。
  void putSnapshot(
    String userId, {
    required int seq,
    required Uint8List bytes,
    String? digest,
  }) {
    final hash = _sha256Hex(bytes);
    blobs.putIfAbsent(userId, () => {})[hash] = bytes;
    snapshots[userId] = FakeSnapshot(
      seq: seq,
      sha256: hash,
      digest: digest ?? _sha256Hex(Uint8List(0)),
      createdAt: '2026-11-20T10:00:00Z',
    );
  }

  /// 按登录方式的值取账号 id；假服务端一个账号只有一条邮箱登录方式。
  String userIdOf(String identifier) => _userIds[identifier]!;

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
      final identifier = _identifierOf(userId);
      final identityId = _identityIds[userId] ?? '';
      return _json(200, {
        'user_id': userId,
        'created_at': '2026-11-17T10:00:00Z',
        'identities': [
          {
            'id': identityId,
            'kind': 'email',
            'identifier': identifier,
            'verified': _verified.contains(identityId),
          },
        ],
      });
    }
    if (method == 'GET' && path == '/v1/me/api-keys') {
      // 接口密钥的签发与撤销由服务端 Go 用例覆盖，这里只给界面一个空列表。
      return _json(200, {'keys': <Object?>[]});
    }
    if (path.startsWith('/v1/me/identities/')) {
      final rest = path.substring('/v1/me/identities/'.length);
      final confirm = rest.endsWith('/verification/confirm');
      final identityId = confirm
          ? rest.substring(0, rest.length - '/verification/confirm'.length)
          : rest.substring(0, rest.length - '/verification'.length);
      // 只认当前账号名下的登录方式，与服务端一致。
      if (identityId != _identityIds[userId]) {
        return _problem(404, 'not_found');
      }
      final identifier = _identifierOf(userId);
      if (confirm) {
        if (!_takeCode(
          identifier,
          'verify_contact',
          body['code'] as String? ?? '',
        )) {
          return _problem(400, 'invalid_code');
        }
        _verified.add(identityId);
        return http.Response('', 204);
      }
      if (!_verified.contains(identityId)) {
        _codes['$identifier|verify_contact'] = _newCode();
      }
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/me') {
      final matches = _userIds.entries
          .where((entry) => entry.value == userId)
          .map((entry) => entry.key);
      final identifier = matches.isEmpty ? null : matches.first;
      final password = body['password'] as String? ?? '';
      if (password.isEmpty) return _problem(400, 'invalid_request');
      if (identifier == null || _passwords[identifier] != password) {
        deleteAttempts++;
        return _problem(401, 'invalid_credentials');
      }
      _userIds.removeWhere((_, id) => id == userId);
      _passwords.remove(identifier);
      _verified.remove(_identityIds.remove(userId));
      _codes.removeWhere((key, _) => key.startsWith('$identifier|'));
      commits.remove(userId);
      backups.remove(userId);
      blobs.remove(userId);
      trimmedThrough.remove(userId);
      snapshots.remove(userId);
      devices.remove(userId);
      refs.remove(userId);
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
      trimmedThrough.remove(userId);
      snapshots.remove(userId);
      devices.remove(userId);
      refs.remove(userId);
      return http.Response('', 204);
    }
    if (method == 'DELETE' && path == '/v1/sync/commits') {
      commits[userId] = [];
      trimmedThrough.remove(userId);
      snapshots.remove(userId);
      return http.Response('', 204);
    }
    if (path == '/v1/sync/devices') {
      _touchDevice(userId, request);
      if (method == 'GET') {
        if (deviceListFailures > 0) {
          deviceListFailures--;
          return _problem(503, 'unavailable');
        }
        return _json(200, {
          'devices': [for (final device in rosterOf(userId)) device.toJson()],
        });
      }
      if (method == 'PUT') {
        return _renameDevice(userId, body);
      }
    }
    if (path == '/v1/sync/refs') {
      if (method == 'GET') {
        final rows = refs[userId] ?? const <String, Map<String, Object?>>{};
        return _json(200, {
          'refs': [
            for (final row in rows.values) {...row},
          ],
        });
      }
      if (method == 'PUT') {
        return _putRef(userId, body);
      }
    }
    if (path == '/v1/sync/snapshot') {
      if (method == 'GET') {
        return _json(200, _syncHeadBody(userId));
      }
      if (method == 'PUT') {
        _touchDevice(userId, request);
        return _registerSnapshot(userId, body);
      }
    }
    if (method == 'GET' && path == '/v1/sync/head') {
      _touchDevice(userId, request);
      await onHead?.call();
      return _json(200, _syncHeadBody(userId));
    }
    if (method == 'GET' && path == '/v1/sync/commits') {
      _touchDevice(userId, request);
      await onPull?.call();
      final after =
          int.tryParse(request.url.queryParameters['after'] ?? '0') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '200') ?? 200;
      final log = commits[userId] ?? const [];
      final earliest = earliestSeqOf(userId);
      if (after + 1 < earliest) {
        // 客户端要的下一条已经被压缩删掉：按契约返回 410，extra 带上快照。
        final snapshot = snapshots[userId];
        return _problem(
          410,
          'history_compacted',
          extra: {
            'after': after,
            'earliest_seq': earliest,
            'head': log.length,
            if (snapshot != null) ...{
              'snapshot_seq': snapshot.seq,
              'snapshot_sha256': snapshot.sha256,
              'snapshot_digest': snapshot.digest,
            },
          },
        );
      }
      _advanceDeviceByPull(userId, request);
      final slice = [
        for (final commit in log)
          if ((commit['seq']! as int) > after &&
              (commit['seq']! as int) >= earliest)
            commit,
      ].take(limit).toList();
      return _json(200, {
        ..._syncHeadBody(userId),
        'commits': slice,
        'has_more':
            slice.isNotEmpty &&
            (slice.last['seq']! as int) < (log.last['seq']! as int? ?? 0),
      });
    }
    if (method == 'POST' && path == '/v1/sync/commits') {
      _touchDevice(userId, request);
      if (pushFailures > 0) {
        pushFailures--;
        return _problem(503, 'unavailable');
      }
      final base = (body['base_seq'] as num?)?.toInt() ?? 0;
      final incoming = [
        for (final item in (body['commits'] as List? ?? const []))
          (item as Map).cast<String, Object?>(),
      ];
      // 提交类型是契约的必填字段，取值与客户端一致；缺字段或未知取值按服务端
      // 的口径返回 400（审查 S23、V18）。
      for (final commit in incoming) {
        if (!_commitKinds.contains(commit['kind'])) {
          return _problem(400, 'invalid_request');
        }
      }
      final log = commits.putIfAbsent(userId, () => []);
      final stored = {
        for (final commit in log)
          commit['uid']! as String: commit['seq']! as int,
      };
      final fresh = [
        for (final commit in incoming)
          if (!stored.containsKey(commit['uid'])) commit,
      ];
      final deviceId = (request.headers['x-device-id'] ?? '').trim();
      if (fresh.isEmpty) {
        // 整批都是重放：回当前 head 与每条提交原来的序号，位置只按 base 推进。
        if (deviceId.isNotEmpty) {
          _advanceDevice(userId, deviceId, base, toHead: false);
        }
        return _json(200, {
          'head': log.length,
          'seqs': [for (final commit in incoming) stored[commit['uid']]],
        });
      }
      if (base != log.length) {
        return _problem(409, 'conflict', extra: {'head': log.length});
      }
      final seqs = <int>[];
      for (final commit in incoming) {
        final uid = commit['uid']! as String;
        final known = stored[uid];
        if (known != null) {
          seqs.add(known);
          continue;
        }
        final seq = log.length + 1;
        stored[uid] = seq;
        log.add({...commit, 'seq': seq});
        seqs.add(seq);
      }
      if (deviceId.isNotEmpty) {
        _advanceDevice(userId, deviceId, base, toHead: true);
      }
      return _json(200, {'head': log.length, 'seqs': seqs});
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
        'used_tokens': embeddingUsedTokens,
        'daily_tokens': 400000,
        'embedding_used_tokens': embeddingUsedTokens,
      });
    }
    if (path == '/v1/llm/models') {
      return _json(200, {
        'object': 'list',
        'data': [
          {
            'id': 'zhixin-chat',
            'object': 'model',
            'owned_by': 'zhixin',
            'kind': 'chat',
          },
          {
            'id': 'zhixin-embedding',
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

  /// 记录一次带设备标识的请求并更新名册：最近出现时间写成服务端当前时间，
  /// 能力声明整组替换，别名保持不变；没有设备标识的请求不算同步请求。
  void _touchDevice(String userId, http.Request request) {
    final deviceId = (request.headers['x-device-id'] ?? '').trim();
    if (deviceId.isEmpty) return;
    final capabilities = [
      for (final value in (request.headers['x-sync-capabilities'] ?? '').split(
        ',',
      ))
        if (value.trim().isNotEmpty) value.trim(),
    ];
    syncDeviceHeaders.add((
      method: request.method,
      path: request.url.path,
      deviceId: deviceId,
      capabilities: capabilities,
    ));
    final lastSeen = DateTime.utc(
      2026,
      11,
      21,
      10,
      0,
      0,
    ).add(Duration(seconds: ++_deviceTicks)).toIso8601String();
    final roster = devices.putIfAbsent(userId, () => {});
    final existing = roster[deviceId];
    if (existing == null) {
      roster[deviceId] = FakeDevice(
        deviceId: deviceId,
        alias: '',
        capabilities: capabilities,
        lastSeen: lastSeen,
      );
      return;
    }
    existing.capabilities = capabilities;
    existing.lastSeen = lastSeen;
  }

  /// 按请求里的 after 推进设备位置，与真实服务端一致：取较大值、不超过 head。
  void _advanceDeviceByPull(String userId, http.Request request) {
    final deviceId = (request.headers['x-device-id'] ?? '').trim();
    if (deviceId.isEmpty) return;
    final after =
        int.tryParse(request.url.queryParameters['after'] ?? '0') ?? 0;
    _advanceDevice(userId, deviceId, after, toHead: false);
  }

  /// 推进名册里一台设备的位置：取较大值，不超过当前 head；[toHead] 为真时推到
  /// 当前 head（确有新提交写入时）。
  void _advanceDevice(
    String userId,
    String deviceId,
    int base, {
    required bool toHead,
  }) {
    final device = devices[userId]?[deviceId];
    if (device == null) return;
    final target = toHead ? headOf(userId) : base;
    final capped = target > headOf(userId) ? headOf(userId) : target;
    if (capped > device.syncedSeq) device.syncedSeq = capped;
  }

  /// 改别名：只认名册里已有的设备，别名去掉首尾空白后 0–64 字符，空串表示清除。
  http.Response _renameDevice(String userId, Map<String, Object?> body) {
    final deviceId = (body['device_id'] as String? ?? '').trim();
    final alias = (body['alias'] as String? ?? '').trim();
    if (deviceId.isEmpty || alias.length > 64) {
      return _problem(400, 'invalid_request');
    }
    final device = devices[userId]?[deviceId];
    if (device == null) return _problem(404, 'not_found');
    device.alias = alias;
    return _json(200, device.toJson());
  }

  /// 同步 head、快照查询与拉取响应的公共字段：最新位置、保留下界与快照指针。
  Map<String, Object?> _syncHeadBody(String userId) {
    final snapshot = snapshots[userId];
    return {
      'head': headOf(userId),
      'schema_version': schemaVersion,
      'earliest_seq': earliestSeqOf(userId),
      'compact': compact,
      if (snapshot != null) 'snapshot': snapshot.toJson(),
    };
  }

  /// 登记快照：校验位置、两个哈希与附件归属，位置比已登记的小时返回 409。
  http.Response _registerSnapshot(String userId, Map<String, Object?> body) {
    snapshotRegistrations++;
    if (snapshotFailures > 0) {
      snapshotFailures--;
      return _problem(503, 'unavailable');
    }
    final seq = (body['seq'] as num?)?.toInt() ?? 0;
    final sha = body['sha256'] as String? ?? '';
    final digest = body['digest'] as String? ?? '';
    final hex = RegExp(r'^[0-9a-f]{64}$');
    if (seq < 1 ||
        seq > headOf(userId) ||
        !hex.hasMatch(sha) ||
        !hex.hasMatch(digest)) {
      return _problem(400, 'invalid_request');
    }
    if (!(blobs[userId]?.containsKey(sha) ?? false)) {
      return _problem(400, 'invalid_request');
    }
    final current = snapshots[userId];
    if (snapshotAlwaysConflicts || (current != null && seq < current.seq)) {
      return _problem(
        409,
        'conflict',
        extra: {'snapshot_seq': current?.seq ?? headOf(userId)},
      );
    }
    snapshots[userId] = FakeSnapshot(
      seq: seq,
      sha256: sha,
      digest: digest,
      createdAt: '2026-11-21T10:00:00Z',
    );
    return _json(200, _syncHeadBody(userId));
  }

  http.Response _register(Map<String, Object?> body) {
    final identifier = (body['identifier'] as String? ?? '')
        .trim()
        .toLowerCase();
    if (_passwords.containsKey(identifier)) {
      return _problem(409, 'identifier_taken');
    }
    _passwords[identifier] = body['password'] as String? ?? '';
    final userId = 'user-${_nextUser++}';
    _userIds[identifier] = userId;
    _identityIds[userId] = 'identity-$userId';
    return _tokens(userId, body['device_name'] as String? ?? '');
  }

  Future<http.Response> _login(Map<String, Object?> body) async {
    loginRequests++;
    final gate = delayLogin;
    if (gate != null) await gate;
    final identifier = (body['identifier'] as String? ?? '')
        .trim()
        .toLowerCase();
    if (_passwords[identifier] == null ||
        _passwords[identifier] != (body['password'] as String? ?? '')) {
      return _problem(401, 'invalid_credentials');
    }
    return _tokens(_userIds[identifier]!, body['device_name'] as String? ?? '');
  }

  /// 命名版本：名字到一行（name、commit_uid、note、updated_at、deleted_at）；按
  /// 账号分开，墓碑永久保留。
  final Map<String, Map<String, Map<String, Object?>>> refs = {};

  /// 每个账号当次请求的时间戳计数，用例里的先后顺序因此确定。
  int _refTicks = 0;

  http.Response _putRef(String userId, Map<String, Object?> body) {
    final name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty || name.runes.length > 30) {
      return _problem(400, 'invalid_request');
    }
    final delete = body['delete'] == true;
    final commitUid = (body['commit_uid'] as String? ?? '').trim();
    if (!delete && commitUid.isEmpty) return _problem(400, 'invalid_request');
    final rows = refs.putIfAbsent(userId, () => {});
    final existing = rows[name];
    final deletedAt = existing?['deleted_at'] as String?;
    final now = DateTime.utc(
      2026,
      11,
      22,
      9,
    ).add(Duration(seconds: ++_refTicks)).toIso8601String();
    final sourceUpdatedAt = body['source_updated_at'] as String? ?? now;
    if (deletedAt != null &&
        (delete ||
            !DateTime.parse(sourceUpdatedAt)
                .isAfter(DateTime.parse(deletedAt)))) {
      // 比删除时间更早的写入不复活名字：回已存的墓碑。
      return _json(200, {...existing!});
    }
    final live = rows.values.where((row) => row['deleted_at'] == null).length;
    if (!delete && (existing == null || deletedAt != null) && live >= 200) {
      return _problem(400, 'invalid_request');
    }
    final row = <String, Object?>{
      'name': name,
      'commit_uid': delete ? (existing?['commit_uid'] ?? '') : commitUid,
      'note': delete
          ? (existing?['note'] ?? '')
          : (body['note'] as String? ?? ''),
      'updated_at': now,
      'deleted_at': delete ? now : null,
    };
    rows[name] = row;
    return _json(200, {...row});
  }

  /// 账号的登录方式取值；假服务端一个账号只有一条。
  String _identifierOf(String userId) =>
      _userIds.entries.firstWhere((entry) => entry.value == userId).key;

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

  bool _takeCode(String identifier, String purpose, String given) {
    final entry = _codes.remove('$identifier|$purpose');
    if (entry == null || entry.code != given.trim()) return false;
    return DateTime.now().isBefore(entry.expiresAt);
  }

  http.Response _forgotPassword(Map<String, Object?> body) {
    final identifier = (body['identifier'] as String? ?? '')
        .trim()
        .toLowerCase();
    final userId = _userIds[identifier];
    if (userId != null && _verified.contains(_identityIds[userId])) {
      _codes['$identifier|reset_password'] = _newCode();
    }
    return http.Response('', 204);
  }

  http.Response _resetPassword(Map<String, Object?> body) {
    final identifier = (body['identifier'] as String? ?? '')
        .trim()
        .toLowerCase();
    final password = body['new_password'] as String? ?? '';
    final userId = _userIds[identifier];
    if (userId == null ||
        !_verified.contains(_identityIds[userId]) ||
        password.length < 8 ||
        !_takeCode(
          identifier,
          'reset_password',
          body['code'] as String? ?? '',
        )) {
      return _problem(400, 'invalid_code');
    }
    _passwords[identifier] = password;
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

/// 假服务端设备名册里的一台设备：标识、别名、能力声明、已应用位置与最近出现时间。
///
/// 契约里能力是布尔字段 `snapshot_capable`，位置是 `synced_seq`；这里保留能力
/// 名列表只是为了沿用用例里按名字写的断言。
class FakeDevice {
  FakeDevice({
    required this.deviceId,
    required this.alias,
    required this.capabilities,
    this.syncedSeq = 0,
    required this.lastSeen,
  });

  final String deviceId;
  String alias;
  List<String> capabilities;
  int syncedSeq;

  /// 是否声明了 snapshot 能力。
  bool get snapshotCapable => capabilities.contains('snapshot');

  /// RFC3339 的 UTC 时间；排序按字符串比较即可。
  String lastSeen;

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'alias': alias,
    'snapshot_capable': snapshotCapable,
    'synced_seq': syncedSeq,
    'last_seen': lastSeen,
  };
}

/// 假服务端保存的快照指针：覆盖到的序号、附件哈希、整库摘要与登记时间。
class FakeSnapshot {
  const FakeSnapshot({
    required this.seq,
    required this.sha256,
    required this.digest,
    required this.createdAt,
  });

  final int seq;
  final String sha256;
  final String digest;
  final String createdAt;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'sha256': sha256,
    'digest': digest,
    'created_at': createdAt,
  };
}

String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
