import 'dart:convert';

import '../../ai/llm_config.dart' show SecretStore;
import '../../domain/rules/uuid_v7.dart';

/// 登录之后的会话：两枚令牌只存在 Android Keystore，不进数据库、数据包与日志。
class AccountSession {
  const AccountSession({
    required this.userId,
    required this.email,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  factory AccountSession.fromJson(Map<String, Object?> json) => AccountSession(
    userId: json['user_id'] as String? ?? '',
    email: json['email'] as String? ?? '',
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
  final String email;
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
      email: email,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessExpiresAt: accessExpiresAt ?? this.accessExpiresAt,
      refreshExpiresAt: refreshExpiresAt ?? this.refreshExpiresAt,
    );
  }

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'email': email,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at': accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
  };
}

/// 账号与会话的落盘：令牌在 Keystore，设备标识也在 Keystore。
///
/// 设备标识用来在提交序列里区分设备，也是首次同步基线的请求编号前缀；它不随
/// 数据包与整库备份迁移，换机之后会重新生成，两台设备因此不会共用同一个编号。
class AccountStore {
  AccountStore(this._secrets);

  static const String sessionKey = 'zhixin.account.session.v1';
  static const String deviceIdKey = 'zhixin.account.device.v1';

  final SecretStore _secrets;

  Future<AccountSession?> read() async {
    final String? raw;
    try {
      raw = await _secrets.read(sessionKey);
    } catch (_) {
      // Keystore 暂时不可用时按未登录处理，不把设置页与回答拖垮。
      return null;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final session = AccountSession.fromJson(decoded.cast<String, Object?>());
      if (session.userId.isEmpty || session.refreshToken.isEmpty) return null;
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(AccountSession session) =>
      _secrets.write(sessionKey, jsonEncode(session.toJson()));

  Future<void> clear() => _secrets.delete(sessionKey);

  /// 本机设备标识；第一次调用时生成并保存，之后一直复用。
  Future<String> deviceId() async {
    final existing = await _secrets.read(deviceIdKey);
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();
    final created = newUuidV7();
    await _secrets.write(deviceIdKey, created);
    return created;
  }
}
