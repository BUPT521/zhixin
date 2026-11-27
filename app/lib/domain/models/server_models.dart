import '../../domain/rules/time_format.dart' show waitText;

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

  /// 拉取位置落在已经压缩的区间：客户端要按快照重新克隆（ADR-0043）。
  bool get isHistoryCompacted => status == 410 || code == 'history_compacted';

  /// 给界面看的一句说明；未知错误保持笼统，不把 `detail` 带进界面。
  String get userMessage => switch (code) {
    'offline' => '无法连接服务端，请检查网络与服务地址',
    'unauthorized' => '登录状态已失效，请重新登录',
    'invalid_credentials' => '邮箱或密码不正确',
    'invalid_code' => '验证码不正确或已经过期，可以重新获取',
    'identifier_taken' => '这个邮箱已经注册过，可以直接登录',
    'email_domain_not_allowed' => _emailDomainMessage,
    'rate_limited' => _rateLimitedMessage,
    'payload_too_large' =>
      extra['resource'] == 'sync' ? '单条同步提交超过服务端允许的大小' : '文件超过服务端允许的大小',
    'contact_unverified' => '请先在账号页验证一种登录方式',
    'history_compacted' => '云端历史已经压缩，这台设备要用云端快照重新克隆',
    'storage_full' => _storageFullMessage,
    'conflict' => '云端数据已经变化，请先同步再试',
    'model_not_allowed' => '服务端不允许使用这个模型',
    'quota_exceeded' => _quotaExceededMessage,
    'not_found' => '云端没有这条记录',
    'invalid_request' => '服务端没有接受这次请求',
    'redirect_blocked' => '服务地址发生了跨域跳转，已停止这次请求',
    'unavailable' || 'upstream_failed' => '服务端暂时不可用，请稍后再试',
    'not_implemented' => '服务端还没有实现这个操作',
    _ => '服务端没有完成这次请求',
  };

  /// 内测期间注册限定邮箱后缀时，用服务端给出的清单说明；客户端不写死域名，
  /// 公测放开或换学校时不用发版。
  String get _emailDomainMessage {
    final allowed = extra['allowed_domains'];
    final suffixes = allowed is List
        ? allowed.whereType<String>().map((domain) => '@$domain').toList()
        : const <String>[];
    if (suffixes.isEmpty) return '内测期间这个邮箱不能注册，请换一个学校邮箱再试';
    return '内测期间只接受 ${suffixes.join('、')} 的邮箱注册';
  }

  /// 限流说明按时长换单位：验证码的收信预算用完之后要等几个小时，直接写秒数
  /// 用户读不出还剩多久。
  String get _rateLimitedMessage {
    final seconds = retryAfterSeconds;
    if (seconds == null || seconds <= 0) return '尝试过于频繁，请稍后再试';
    return '尝试过于频繁，请 ${waitText(seconds)}后再试';
  }

  /// 聊天与嵌入的共享额度用完时，按服务端给出的原因说明怎么继续。
  ///
  /// 原因由服务端在 `extra.reason` 里给出，缺失时按模型额度用完的一般口径说明；
  /// 余额副本正在同步时说明稍后重试即可，不引导购买（ADR-0073）。
  String get _quotaExceededMessage {
    return switch (extra['reason']) {
      'instance' => '实例今天的模型预算已经用完，请稍后再试',
      'syncing' => '积分余额正在同步，请稍后重试',
      'points' => '积分余额不足，可以在账号页购买积分之后继续，也可以等次日恢复',
      'account' => '今天的免费模型额度已经用完，可以在账号页购买积分之后继续，也可以等次日恢复',
      _ => '今天的模型额度已经用完，可以在账号页购买积分之后继续，也可以等次日恢复',
    };
  }

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
/// 本机摘要（同步方案 3.5）。[tableDigests] 是同一份摘要按表拆开的映射，与
/// [stateDigest] 一起带，各表值之和恒等于它（ADR-0054 决定第 1 条）。
class ServerCommit {
  const ServerCommit({
    required this.uid,
    required this.deviceId,
    required this.schemaVersion,
    required this.kind,
    required this.actor,
    required this.action,
    required this.changes,
    this.seq,
    this.createdAt,
    this.receivedAt,
    this.stateDigest,
    this.tableDigests,
  });

  factory ServerCommit.fromJson(Map<String, Object?> json) => ServerCommit(
    seq: (json['seq'] as num?)?.toInt(),
    uid: json['uid'] as String? ?? '',
    deviceId: json['device_id'] as String? ?? '',
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
    kind: json['kind'] as String? ?? '',
    actor: json['actor'] as String? ?? 'user',
    action: json['action'] as String? ?? '',
    createdAt: json['created_at'] as String?,
    receivedAt: json['received_at'] as String?,
    stateDigest: json['state_digest'] as String?,
    tableDigests: _digestMapOf(json['table_digests']),
    changes: [
      for (final item in (json['changes'] as List? ?? const []))
        if (item is Map) ServerChange.fromJson(item.cast<String, Object?>()),
    ],
  );

  final int? seq;

  /// 提交身份，由客户端在用户动作发生时生成（ADR-0053）。
  final String uid;
  final String deviceId;
  final int schemaVersion;

  /// 提交类型；远端提交沿用它在原来设备上的类型，来源只看 [deviceId]
  /// （审查 S23、契约的 `kind`，必填）。
  final String kind;
  final String actor;
  final String action;
  final String? createdAt;
  final String? receivedAt;
  final String? stateDigest;

  /// 分表摘要；没有带的提交为空。
  final Map<String, String>? tableDigests;
  final List<ServerChange> changes;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'device_id': deviceId,
    'schema_version': schemaVersion,
    'kind': kind,
    'actor': actor,
    'action': action,
    'created_at': createdAt,
    if (stateDigest != null) 'state_digest': stateDigest,
    if (tableDigests != null) 'table_digests': tableDigests,
    'changes': [for (final change in changes) change.toJson()],
  };
}

/// 分表摘要映射；键表名、值 64 位十六进制，缺字段或形状不对时为空。
Map<String, String>? _digestMapOf(Object? raw) {
  if (raw is! Map) return null;
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (entry.key is String && value is String) {
      result[entry.key as String] = value;
    }
  }
  return result;
}

/// 账号当前快照的指针：覆盖到的服务端位置、附件哈希与整库摘要。
///
/// 快照由已经同步到某个位置的设备按检查点格式压缩之后当作附件上传，服务端只
/// 保存字节与指针，不解析内容（ADR-0043）。客户端按 [sha256] 走附件下载接口
/// 取字节，解出投影之后把本机数据换成快照内容，再从 [seq] 继续增量拉取。
class ServerSnapshot {
  const ServerSnapshot({
    required this.seq,
    required this.sha256,
    required this.digest,
    this.createdAt,
  });

  factory ServerSnapshot.fromJson(Map<String, Object?> json) => ServerSnapshot(
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    sha256: json['sha256'] as String? ?? '',
    digest: json['digest'] as String? ?? '',
    createdAt: _parseTime(json['created_at']),
  );

  /// 快照覆盖到的服务端序列位置；快照之后的提交仍然按增量拉取。
  final int seq;

  /// 快照附件的 SHA-256，64 位小写十六进制；下载之后要按它核对字节。
  final String sha256;

  /// 客户端登记时给出的整库摘要（改进方案 3.5），服务端原样保存。
  final String digest;
  final DateTime? createdAt;
}

/// 拉取要的下一条提交已经被服务端压缩删掉：本机要按快照重新克隆。
///
/// 服务端返回 410 `history_compacted`，`extra` 里带保留下界、head 与当前快照
/// 的序号、哈希和摘要（ADR-0043）。[snapshot] 为空表示服务端没有登记快照，
/// 这种情况下客户端无法自动重建，只能给用户明确说明。
class SyncHistoryCompacted implements Exception {
  const SyncHistoryCompacted({
    required this.earliestSeq,
    required this.head,
    this.after = 0,
    this.snapshot,
  });

  /// 从 410 problem 的 `extra` 还原；缺字段时按“读不出”处理，交给调用方判断。
  factory SyncHistoryCompacted.fromProblem(ServerProblem problem) {
    final extra = problem.extra;
    final seq = _intOf(extra['snapshot_seq']);
    final sha256 = _stringOf(extra['snapshot_sha256']);
    final digest = _stringOf(extra['snapshot_digest']);
    return SyncHistoryCompacted(
      earliestSeq: _intOf(extra['earliest_seq']) ?? 2,
      head: _intOf(extra['head']) ?? 0,
      after: _intOf(extra['after']) ?? 0,
      snapshot: seq == null || sha256 == null
          ? null
          : ServerSnapshot(seq: seq, sha256: sha256, digest: digest ?? ''),
    );
  }

  /// 保留下界：第一条仍然可以拉取的序号。
  final int earliestSeq;

  /// 服务端当前最新位置。
  final int head;

  /// 这次拉取请求的 `after`。
  final int after;

  /// 服务端登记的当前快照；没有登记时为空。
  final ServerSnapshot? snapshot;

  /// 给界面看的一句说明。
  String get userMessage =>
      snapshot == null ? '云端历史已经压缩，这台设备暂时不能自动重建' : '云端历史已经压缩，这台设备要从云端快照重新克隆';

  @override
  String toString() =>
      'SyncHistoryCompacted(earliest=$earliestSeq, after=$after, '
      'head=$head, snapshot=${snapshot?.seq})';
}

/// 一页远端提交与它到达的服务端位置。
class ServerCommitPage {
  const ServerCommitPage({
    required this.commits,
    required this.head,
    required this.hasMore,
    this.earliestSeq = 1,
    this.snapshot,
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
        earliestSeq: (json['earliest_seq'] as num?)?.toInt() ?? 1,
        snapshot: _snapshotOf(json['snapshot']),
      );

  final List<ServerCommit> commits;
  final int head;
  final bool hasMore;

  /// 保留下界：第一条仍然可以拉取的序号，没有删除过提交时为 1。
  final int earliestSeq;

  /// 当前快照指针；没有登记时为空。
  final ServerSnapshot? snapshot;
}

/// 一次推送的结果：推送之后的服务端位置，与请求逐条对应的服务端序号。
class ServerPushResult {
  const ServerPushResult({required this.head, this.seqs = const []});

  final int head;
  final List<int> seqs;
}

/// 账号级命名版本的一行；[deletedAt] 非空表示这个名字已被删除（墓碑）。
class SyncRefRow {
  const SyncRefRow({
    required this.name,
    required this.commitUid,
    this.note = '',
    this.updatedAt,
    this.deletedAt,
  });

  factory SyncRefRow.fromJson(Map<String, Object?> json) => SyncRefRow(
    name: json['name'] as String? ?? '',
    commitUid: json['commit_uid'] as String? ?? '',
    note: json['note'] as String? ?? '',
    updatedAt: _parseTime(json['updated_at']),
    deletedAt: _parseTime(json['deleted_at']),
  );

  final String name;
  final String commitUid;
  final String note;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
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

/// 服务端序列的最新位置、保留下界、压缩开关与当前快照。
class ServerHead {
  const ServerHead({
    required this.head,
    required this.schemaVersion,
    this.earliestSeq = 1,
    this.compact = false,
    this.snapshot,
  });

  factory ServerHead.fromJson(Map<String, Object?> json) => ServerHead(
    head: (json['head'] as num?)?.toInt() ?? 0,
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
    earliestSeq: (json['earliest_seq'] as num?)?.toInt() ?? 1,
    compact: json['compact'] == true,
    snapshot: _snapshotOf(json['snapshot']),
  );

  final int head;
  final int schemaVersion;

  /// 保留下界：第一条仍然可以拉取的序号，没有删除过提交时为 1。
  final int earliestSeq;

  /// 服务端有没有打开快照压缩：关闭时登记只写指针、不删提交，客户端因此不上传
  /// 整库快照，避免白占附件配额（ADR-0047）。旧版服务端没有这个字段时按关闭处理。
  final bool compact;

  /// 当前快照指针；没有登记时为空。
  final ServerSnapshot? snapshot;

  /// 拉取位置之后的提交是否已经被压缩删掉；为真时要从快照重建。
  bool get historyCompacted => earliestSeq > 1;
}

/// 账号设备名册里的一台设备：设备标识、用户设置的别名、能力声明与最近出现时间。
///
/// 名册按最近出现时间倒序返回，最多 50 条；别名由用户设置，空串表示还没有别名，
/// 界面此时退回显示设备标识的前 8 位（ADR-0048）。能力声明现在只有快照一种，
/// 服务端存成布尔列；[syncedSeq] 是这台设备已经应用到的服务端序号，常规压缩
/// 不越过活跃窗口内设备的最小值（ADR-0054 决定第 3 条）。
class ServerDevice {
  const ServerDevice({
    required this.deviceId,
    this.alias = '',
    this.snapshotCapable = false,
    this.syncedSeq = 0,
    this.lastSeen,
  });

  factory ServerDevice.fromJson(Map<String, Object?> json) => ServerDevice(
    deviceId: json['device_id'] as String? ?? '',
    alias: json['alias'] as String? ?? '',
    snapshotCapable: json['snapshot_capable'] == true,
    syncedSeq: (json['synced_seq'] as num?)?.toInt() ?? 0,
    lastSeen: _parseTime(json['last_seen']),
  );

  final String deviceId;

  /// 用户设置的别名；去掉首尾空白之后为空表示没有别名。
  final String alias;

  /// 这台设备是否声明了 snapshot 能力。
  final bool snapshotCapable;

  /// 这台设备已经应用到的服务端序号。
  final int syncedSeq;

  /// 服务端最后一次收到这台设备请求的时间。
  final DateTime? lastSeen;
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

/// 一次备份下载的结果：写入的字节数、实际哈希与服务端声明的哈希。
///
/// 文件已经落在调用方给的路径上，字节只经过一次拷贝；声明值与实际值不一致时
/// 由下载方法直接失败并删掉文件，不会返回半个包。
class BackupDownload {
  const BackupDownload({
    required this.length,
    required this.sha256,
    this.declaredSha256,
  });

  final int length;
  final String sha256;
  final String? declaredSha256;
}

/// 今天的共享额度和已结算用量。
class ServerQuota {
  const ServerQuota({
    required this.day,
    required this.usedTokens,
    required this.dailyTokens,
    this.embeddingUsedTokens = 0,
    this.tokensPerPoint,
    this.chargedPoints,
    this.remainingPoints,
  });

  factory ServerQuota.fromJson(Map<String, Object?> json) => ServerQuota(
    day: json['day'] as String? ?? '',
    usedTokens: (json['used_tokens'] as num?)?.toInt() ?? 0,
    dailyTokens: (json['daily_tokens'] as num?)?.toInt() ?? 0,
    embeddingUsedTokens: (json['embedding_used_tokens'] as num?)?.toInt() ?? 0,
    tokensPerPoint: _ratio(json['tokens_per_point']),
    // 没有开通收款时服务端不回这两项，界面不显示积分那一行。
    chargedPoints: _points(json['charged_points']),
    remainingPoints: _points(json['remaining_points']),
  );

  /// 比例缺失或不是正数时按缺失处理，界面退回按 token 显示，不显示成 0 积分。
  static int? _ratio(Object? value) {
    final number = (value as num?)?.toInt();
    return number != null && number > 0 ? number : null;
  }

  /// 积分字段缺失或为 null 时按未开通收款处理；0 是有效值。
  static int? _points(Object? value) => (value as num?)?.toInt();

  final String day;

  /// 两类模型的当日已用合计与每日共享额度，按计费 token 计；界面按 [tokensPerPoint] 折成积分。
  /// 已用不含还在途的请求，服务端结算之后才算进来。
  final int usedTokens;
  final int dailyTokens;

  /// 嵌入当天已结算的计费 token。
  final int embeddingUsedTokens;

  int get chatUsedTokens => usedTokens - embeddingUsedTokens;

  /// 一个积分覆盖的计费 token 数；旧版服务端不返回时为 null，这时界面只显示 token。
  final int? tokensPerPoint;

  /// 当天已经核销成功的积分与余额副本里还可以使用的积分；没有开通收款时为 null。
  final int? chargedPoints;
  final int? remainingPoints;
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

DateTime? _parseTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

/// problem 的 `extra` 里可能是数字，也可能是字符串形式的数字。
int? _intOf(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text.trim()),
  _ => null,
};

String? _stringOf(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// 响应里的 `snapshot` 字段：对象时解析，缺失或为空时返回空。
ServerSnapshot? _snapshotOf(Object? value) => switch (value) {
  final Map map => ServerSnapshot.fromJson(map.cast<String, Object?>()),
  _ => null,
};
