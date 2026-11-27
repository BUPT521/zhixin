import 'dart:convert';

import '../../ai/llm_config.dart' show SecretStore;
import '../../domain/models/account_models.dart';
import '../../domain/rules/uuid_v7.dart';

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
