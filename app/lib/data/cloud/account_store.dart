import 'dart:convert';

import '../../ai/llm_config.dart' show SecretStore;
import '../../domain/rules/uuid_v7.dart';
import '../../domain/models/server_models.dart'
    show ServerAccount, ServerIdentity;

/// 登录之后的会话：两枚令牌只存在 Android Keystore，不进数据库、数据包与日志。
///
/// 会话只按服务实例的来源与账号保存（[serverOrigin]、[userId]）：换了服务实例
/// 之后同一个账号的令牌也不能拿到新实例上使用。邮箱这类资料不在这里，改由
/// [AccountProfile] 单独保存，令牌刷新时因此不会顺带改写资料。
class AccountSession {
  const AccountSession({
    required this.userId,
    required this.serverOrigin,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  factory AccountSession.fromJson(Map<String, Object?> json) => AccountSession(
    userId: json['user_id'] as String? ?? '',
    serverOrigin: json['server_origin'] as String? ?? '',
    accessToken: json['access_token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String? ?? '',
    accessExpiresAt:
        DateTime.tryParse(json['access_expires_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    refreshExpiresAt:
        DateTime.tryParse(json['refresh_expires_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String userId;

  /// 会话所属服务实例的来源（协议、主机与端口），切换实例之后不再复用。
  final String serverOrigin;
  final String accessToken;
  final String refreshToken;

  /// 服务端返回的时间已经换成本机时区。
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;

  bool get isExpired => !DateTime.now().isBefore(refreshExpiresAt);

  AccountSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessExpiresAt,
    DateTime? refreshExpiresAt,
  }) {
    return AccountSession(
      userId: userId,
      serverOrigin: serverOrigin,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessExpiresAt: accessExpiresAt ?? this.accessExpiresAt,
      refreshExpiresAt: refreshExpiresAt ?? this.refreshExpiresAt,
    );
  }

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'server_origin': serverOrigin,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
  };
}

/// 账号的一种登录方式。现在只会有邮箱，以后加手机号或微信时这里多一种 kind，
/// 页面按 [kindLabel] 显示即可。
class AccountIdentity {
  const AccountIdentity({
    required this.id,
    required this.kind,
    required this.identifier,
    required this.verified,
  });

  factory AccountIdentity.fromServer(ServerIdentity identity) =>
      AccountIdentity(
        id: identity.id,
        kind: identity.kind,
        identifier: identity.identifier,
        verified: identity.verified,
      );

  factory AccountIdentity.fromJson(Map<String, Object?> json) =>
      AccountIdentity(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        identifier: json['identifier'] as String? ?? '',
        verified: json['verified'] == true,
      );

  final String id;

  /// 服务端 `user_identity.kind` 的取值：`email`、`phone`、`wechat`。
  final String kind;
  final String identifier;

  /// 这条登录方式是否已经用验证码确认；账号只要有一条确认过就开放托管额度。
  final bool verified;

  String get kindLabel => switch (kind) {
    'email' => '邮箱',
    'phone' => '手机号',
    'wechat' => '微信',
    _ => kind,
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'identifier': identifier,
    'verified': verified,
  };
}

/// 账号资料：登录方式列表。每次调用 `/v1/me` 时刷新，用 Keystore 里单独一个键
/// 保存；退出登录与删除账号时随会话一起清掉。
class AccountProfile {
  const AccountProfile({
    required this.userId,
    required this.serverOrigin,
    required this.identities,
    this.createdAt,
  });

  factory AccountProfile.fromServer(
    ServerAccount account, {
    required String serverOrigin,
  }) => AccountProfile(
    userId: account.userId,
    serverOrigin: serverOrigin,
    identities: [
      for (final identity in account.identities)
        AccountIdentity.fromServer(identity),
    ],
    createdAt: account.createdAt,
  );

  factory AccountProfile.fromJson(Map<String, Object?> json) => AccountProfile(
    userId: json['user_id'] as String? ?? '',
    serverOrigin: json['server_origin'] as String? ?? '',
    identities: [
      for (final item in (json['identities'] as List? ?? const []))
        if (item is Map) AccountIdentity.fromJson(item.cast<String, Object?>()),
    ],
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')
        ?.toLocal(),
  );

  final String userId;

  /// 资料所属服务实例的来源，与会话一致；换了实例之后旧资料不再适用。
  final String serverOrigin;
  final List<AccountIdentity> identities;
  final DateTime? createdAt;

  /// 至少有一种登录方式已经确认。找回密码、托管额度与云端写入都按它判断。
  bool get contactVerified => identities.any((identity) => identity.verified);

  /// 给界面与提示用的一行：优先取已确认的登录方式，没有时取第一条。
  String get displayLabel {
    for (final identity in identities) {
      if (identity.verified) return identity.identifier;
    }
    return identities.isEmpty ? '' : identities.first.identifier;
  }

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'server_origin': serverOrigin,
    'identities': [for (final identity in identities) identity.toJson()],
    if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
  };
}

/// 账号、资料与会话的落盘：令牌与资料各用一个 Keystore 键，设备标识也在这里。
///
/// 设备标识用来在提交序列里区分设备，也是首次同步基线的请求编号前缀；它不随
/// 数据包与整库备份迁移，换机之后会重新生成，两台设备因此不会共用同一个编号。
class AccountStore {
  AccountStore(this._secrets);

  /// 会话的键带上版本号：结构变化之后旧会话读不出来，按未登录处理，用户重新
  /// 注册一次即可（ADR-0001、ADR-0038）。
  static const String sessionKey = 'zhixin.account.session.v2';
  static const String profileKey = 'zhixin.account.profile.v1';
  static const String deviceIdKey = 'zhixin.account.device.v1';

  final SecretStore _secrets;

  /// 读当前会话；传入 [origin] 时只返回属于这个服务实例的会话，换了实例就按
  /// 未登录处理，不会把旧实例的令牌发到新地址上。
  Future<AccountSession?> read({String? origin}) async {
    final decoded = await _readJson(sessionKey);
    if (decoded == null) return null;
    final session = AccountSession.fromJson(decoded);
    if (session.userId.isEmpty ||
        session.refreshToken.isEmpty ||
        session.serverOrigin.isEmpty) {
      return null;
    }
    if (origin != null && session.serverOrigin != origin) return null;
    return session;
  }

  Future<void> save(AccountSession session) =>
      _secrets.write(sessionKey, jsonEncode(session.toJson()));

  /// 读账号资料；与会话一样只认属于 [origin] 的那一份。
  Future<AccountProfile?> readProfile({String? origin}) async {
    final decoded = await _readJson(profileKey);
    if (decoded == null) return null;
    final profile = AccountProfile.fromJson(decoded);
    if (profile.userId.isEmpty ||
        profile.identities.isEmpty ||
        profile.serverOrigin.isEmpty) {
      return null;
    }
    if (origin != null && profile.serverOrigin != origin) return null;
    return profile;
  }

  Future<void> saveProfile(AccountProfile profile) =>
      _secrets.write(profileKey, jsonEncode(profile.toJson()));

  Future<void> clearProfile() => _secrets.delete(profileKey);

  /// 退出登录与删除账号：会话与资料一起清掉。
  Future<void> clear() async {
    await _secrets.delete(sessionKey);
    await _secrets.delete(profileKey);
  }

  /// 本机设备标识；第一次调用时生成并保存，之后一直复用。
  Future<String> deviceId() async {
    final existing = await _secrets.read(deviceIdKey);
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();
    final created = newUuidV7();
    await _secrets.write(deviceIdKey, created);
    return created;
  }

  /// 读一个键并解析成 JSON 对象；Keystore 不可用、内容不是对象或解析失败时返回
  /// null，调用方按“没有这条记录”处理，不把设置页与回答拖垮。
  Future<Map<String, Object?>?> _readJson(String key) async {
    final String? raw;
    try {
      raw = await _secrets.read(key);
    } catch (_) {
      return null;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }
}
