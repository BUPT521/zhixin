import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 增量同步的本机游标：服务端已经对齐到 [serverHead]，本机编号不超过
/// [pushedThrough] 的提交都已经在服务端序列里。
///
/// [serverOrigin] 与 [userId] 一起标识游标所属的服务实例与账号：切换实例或
/// 账号之后旧游标不能再用，否则会把一个实例的位置带到另一个实例上。
/// [remoteLocalIds] 是拉取远端提交之后在本机新生成的提交编号：它们对应服务端
/// 已有的提交，推送时要跳过，成功推送之后随 [pushedThrough] 一起清空。
class SyncState {
  const SyncState({
    required this.userId,
    required this.serverOrigin,
    required this.serverHead,
    required this.pushedThrough,
    this.remoteLocalIds = const {},
    this.syncedAt,
  });

  factory SyncState.fromJson(Map<String, Object?> json) => SyncState(
    userId: json['user_id'] as String? ?? '',
    serverOrigin: json['server_origin'] as String? ?? '',
    serverHead: (json['server_head'] as num?)?.toInt() ?? 0,
    pushedThrough: (json['pushed_through'] as num?)?.toInt() ?? 0,
    remoteLocalIds: {
      for (final id in (json['remote_local_ids'] as List? ?? const []))
        if (id is num) id.toInt(),
    },
    syncedAt: DateTime.tryParse(json['synced_at'] as String? ?? ''),
  );

  final String userId;

  /// 游标所属服务实例的来源（协议、主机与端口）。
  final String serverOrigin;
  final int serverHead;
  final int pushedThrough;
  final Set<int> remoteLocalIds;
  final DateTime? syncedAt;

  SyncState copyWith({
    int? serverHead,
    int? pushedThrough,
    Set<int>? remoteLocalIds,
    DateTime? syncedAt,
  }) {
    return SyncState(
      userId: userId,
      serverOrigin: serverOrigin,
      serverHead: serverHead ?? this.serverHead,
      pushedThrough: pushedThrough ?? this.pushedThrough,
      remoteLocalIds: remoteLocalIds ?? this.remoteLocalIds,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'server_origin': serverOrigin,
    'server_head': serverHead,
    'pushed_through': pushedThrough,
    'remote_local_ids': remoteLocalIds.toList()..sort(),
    'synced_at': syncedAt?.toUtc().toIso8601String(),
  };
}

/// 编译时确定的默认服务地址：正式包指向项目组的第一套实例，本地联调用
/// `--dart-define=ZHIXIN_SERVER_URL=http://127.0.0.1:8080` 覆盖。
///
/// 账号可选，服务端接入默认就是可用的：用户不必先知道地址才能登录，账号页
/// 仍可以改成别的自建实例。
const String defaultServerBaseUrl = String.fromEnvironment(
  'ZHIXIN_SERVER_URL',
  defaultValue: 'https://zhixin.chensiyuan.work',
);

/// 云同步相关的本机偏好：服务地址、是否自动同步，以及当前账号的同步游标。
///
/// 这些值不进入数据库，也不进数据包与整库备份：服务地址按这台设备重新填写，
/// 同步游标跟着本机提交编号走，换机或恢复备份之后应从头对齐，而不是沿用别的
/// 设备的位置。文件写在应用私有目录，卸载应用时一起删除。
class CloudPreferencesStore {
  CloudPreferencesStore({required this.filesDir});

  static const String fileName = 'cloud.json';

  final String filesDir;

  String get path => p.join(filesDir, fileName);

  Future<Map<String, Object?>> _read() async {
    final file = File(path);
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      return decoded.cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, Object?> value) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.partial');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  /// 本机保存的地址；没有保存过时为空，调用方据此区分默认地址与用户改过的地址。
  Future<String> storedServerBaseUrl() async {
    final raw = await _read();
    final value = raw['server_base_url'];
    return value is String ? value.trim() : '';
  }

  Future<bool> usesDefaultServerBaseUrl() async =>
      (await storedServerBaseUrl()).isEmpty;

  Future<String> serverBaseUrl() async {
    final stored = await storedServerBaseUrl();
    return stored.isEmpty ? defaultServerBaseUrl : stored;
  }

  Future<void> setServerBaseUrl(String value) async {
    final raw = await _read();
    await _write({...raw, 'server_base_url': value.trim()});
  }

  Future<bool> autoSync() async {
    final raw = await _read();
    return raw['auto_sync'] != false;
  }

  Future<void> setAutoSync(bool value) async {
    final raw = await _read();
    await _write({...raw, 'auto_sync': value});
  }

  /// 上一次登录的身份（实例来源与账号）；用它判断这次登录是不是换了账号，
  /// 换了账号就把自动同步先停下来，等用户确认之后再恢复。
  Future<String> lastIdentity() async {
    final raw = await _read();
    final value = raw['last_identity'];
    return value is String ? value.trim() : '';
  }

  Future<void> setLastIdentity(String value) async {
    final raw = await _read();
    await _write({...raw, 'last_identity': value.trim()});
  }

  Future<SyncState?> syncState() async {
    final raw = await _read();
    final state = raw['sync_state'];
    if (state is! Map) return null;
    final decoded = SyncState.fromJson(state.cast<String, Object?>());
    return decoded.userId.isEmpty || decoded.serverOrigin.isEmpty
        ? null
        : decoded;
  }

  Future<void> saveSyncState(SyncState state) async {
    final raw = await _read();
    await _write({...raw, 'sync_state': state.toJson()});
  }

  Future<void> clearSyncState() async {
    final raw = await _read();
    final next = Map<String, Object?>.of(raw)..remove('sync_state');
    await _write(next);
  }
}
