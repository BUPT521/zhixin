import 'server_models.dart' show ServerAccount, ServerIdentity;

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
