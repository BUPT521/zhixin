import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/model_api_key.dart';
import '../../domain/models/quota_purchase.dart';
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

  /// 限流说明按时长换单位：验证码的收信预算用完之后要等几个小时，直接写秒数
  /// 用户读不出还剩多久。
  String get _rateLimitedMessage {
    final seconds = retryAfterSeconds;
    if (seconds == null || seconds <= 0) return '尝试过于频繁，请稍后再试';
    return '尝试过于频繁，请 ${waitText(seconds)}后再试';
  }

  /// 额度用完按用途与原因分别说明：聊天的免费额度与积分用完之后可以购买积分继续，
  /// 实例预算用完只能稍后重试，嵌入按原始 token 计、不能用积分支付，只说明次日恢复。
  ///
  /// 原因由服务端在 `extra.reason` 里给出，缺失时按聊天额度用完的一般口径说明；
  /// 余额副本正在同步时说明稍后重试即可，不引导购买（ADR-0073）。
  String get _quotaExceededMessage {
    if (extra['kind'] == 'embedding') {
      return '今天的嵌入额度已经用完，次日恢复';
    }
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

/// 今天的模型用量与额度；聊天与嵌入分开计。
class ServerQuota {
  const ServerQuota({
    required this.day,
    required this.usedTokens,
    required this.dailyTokens,
    this.embeddingUsedTokens = 0,
    this.embeddingDailyTokens = 0,
    this.tokensPerPoint,
    this.chargedPoints,
    this.remainingPoints,
  });

  factory ServerQuota.fromJson(Map<String, Object?> json) => ServerQuota(
    day: json['day'] as String? ?? '',
    usedTokens: (json['used_tokens'] as num?)?.toInt() ?? 0,
    dailyTokens: (json['daily_tokens'] as num?)?.toInt() ?? 0,
    embeddingUsedTokens: (json['embedding_used_tokens'] as num?)?.toInt() ?? 0,
    embeddingDailyTokens:
        (json['embedding_daily_tokens'] as num?)?.toInt() ?? 0,
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

  /// 聊天当天已用与每日额度，按计费 token 计；界面按 [tokensPerPoint] 折成积分。
  /// 已用不含还在途的请求，服务端结算之后才算进来。
  final int usedTokens;
  final int dailyTokens;

  /// 嵌入当天已用与每日额度；旧版服务端没有这两项，读作 0。
  final int embeddingUsedTokens;
  final int embeddingDailyTokens;

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
