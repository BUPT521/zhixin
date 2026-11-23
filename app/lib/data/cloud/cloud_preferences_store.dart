import 'package:path/path.dart' as p;

import '../atomic_file.dart';

/// 增量同步的账号标识：这个账号在这个服务实例上已经初始化过同步，下次同步
/// 按增量走，不再上传首次基线。
///
/// 同步位置随库保存在当前空间的 `revision_cursor` 表里。[serverOrigin] 与
/// [userId] 用于核对偏好文件的同步状态属于当前账号和实例（ADR-0056）。
class SyncState {
  const SyncState({
    required this.userId,
    required this.serverOrigin,
    this.syncedAt,
    this.digestMismatch = false,
    this.differentTables = const [],
  });

  factory SyncState.fromJson(Map<String, Object?> json) => SyncState(
    userId: json['user_id'] as String? ?? '',
    serverOrigin: json['server_origin'] as String? ?? '',
    syncedAt: DateTime.tryParse(json['synced_at'] as String? ?? ''),
    digestMismatch: json['digest_mismatch'] == true,
    differentTables: (json['different_tables'] as List? ?? const [])
        .whereType<String>()
        .toList(),
  );

  final String userId;

  /// 游标所属服务实例的来源（协议、主机与端口）。
  final String serverOrigin;
  final DateTime? syncedAt;

  /// 上次同步比较摘要时发现本机与云端不一致（同步方案 3.5）。
  ///
  /// 只有两件事会改它：拉取到带摘要的最后一条提交、且本机没有待推送提交时
  /// 重新比较；两个修复入口成功之后清掉。它只说明“两边内容不同”，不是一个
  /// 错误状态，所以同步照常继续，账号页据此显示修复入口。
  final bool digestMismatch;
  final List<String> differentTables;

  SyncState copyWith({
    DateTime? syncedAt,
    bool? digestMismatch,
    List<String>? differentTables,
  }) => SyncState(
    userId: userId,
    serverOrigin: serverOrigin,
    syncedAt: syncedAt ?? this.syncedAt,
    digestMismatch: digestMismatch ?? this.digestMismatch,
    differentTables: differentTables ?? this.differentTables,
  );

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'server_origin': serverOrigin,
    'synced_at': syncedAt?.toUtc().toIso8601String(),
    'digest_mismatch': digestMismatch,
    if (differentTables.isNotEmpty) 'different_tables': differentTables,
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

/// 云同步相关的本机偏好：服务地址、是否自动同步，以及当前账号的同步状态。
///
/// 这里只保存这台设备自己的配置与账号标识。同步位置属于库内数据，存在
/// `revision_cursor` 表里，随整库备份与恢复一起走；换机时按当前数据重新对齐，
/// 而不是沿用别的设备的位置（ADR-0039）。文件写在应用私有目录，卸载应用时
/// 一起删除。
///
/// 写按文件排队、先写临时文件再改名，口径见 [AtomicJsonFile]：界面切换自动同步与
/// 同步收尾写状态可能同时发生，两个动作各自在这份文件上读改写。
class CloudPreferencesStore {
  CloudPreferencesStore({required this.filesDir, String? spaceFilesDir})
    : spaceFilesDir = spaceFilesDir ?? filesDir;

  static const String fileName = 'cloud.json';

  final String filesDir;
  final String spaceFilesDir;

  String get path => p.join(filesDir, fileName);

  AtomicJsonFile get _file => AtomicJsonFile(path);

  AtomicJsonFile get _spaceFile =>
      AtomicJsonFile(p.join(spaceFilesDir, fileName));

  Future<Map<String, Object?>> _read() => _spaceFile.read();

  /// 读最新的内容、改一个键再整体写回，这一段在这份文件的队列里独占执行。
  Future<void> _mutate(void Function(Map<String, Object?> raw) change) =>
      _spaceFile.update(change);

  /// 本机保存的地址；没有保存过时为空，调用方据此区分默认地址与用户改过的地址。
  Future<String> storedServerBaseUrl() async {
    final raw = await _file.read();
    final value = raw['server_base_url'];
    return value is String ? value.trim() : '';
  }

  Future<bool> usesDefaultServerBaseUrl() async =>
      (await storedServerBaseUrl()).isEmpty;

  Future<String> serverBaseUrl() async {
    final stored = await storedServerBaseUrl();
    return stored.isEmpty ? defaultServerBaseUrl : stored;
  }

  Future<void> setServerBaseUrl(String value) => _file.update((raw) {
    raw['server_base_url'] = value.trim();
  });

  Future<bool> autoSync() async {
    final raw = await _read();
    return raw['auto_sync'] != false;
  }

  Future<void> setAutoSync(bool value) => _mutate((raw) {
    raw['auto_sync'] = value;
  });

  /// 上一次登录的身份（实例来源与账号）；用它判断这次登录是不是换了账号，
  /// 换了账号就把自动同步先停下来，等用户确认之后再恢复。
  Future<String> lastIdentity() async {
    final raw = await _read();
    final value = raw['last_identity'];
    return value is String ? value.trim() : '';
  }

  Future<void> setLastIdentity(String value) => _mutate((raw) {
    raw['last_identity'] = value.trim();
  });

  Future<SyncState?> syncState() async {
    final raw = await _read();
    final state = raw['sync_state'];
    if (state is! Map) return null;
    final decoded = SyncState.fromJson(state.cast<String, Object?>());
    return decoded.userId.isEmpty || decoded.serverOrigin.isEmpty
        ? null
        : decoded;
  }

  Future<void> saveSyncState(SyncState state) => _mutate((raw) {
    raw['sync_state'] = state.toJson();
  });

  Future<void> clearSyncState() => _mutate((raw) {
    raw.remove('sync_state');
  });

  /// 上次冲刷记忆使用统计的时刻；没有记录过时为空。
  ///
  /// 冲刷间隔是“一天”，跨进程也要算数，所以记在本机偏好文件里，与同步状态
  /// 同一份文件、同一套排队写（ADR-0051 决定第 8 条）。
  Future<DateTime?> memoryUsageFlushedAt() async {
    final raw = await _read();
    final value = raw['memory_usage_flushed_at'];
    if (value is! String) return null;
    return DateTime.tryParse(value);
  }

  Future<void> setMemoryUsageFlushedAt(DateTime at) => _mutate((raw) {
    raw['memory_usage_flushed_at'] = at.toUtc().toIso8601String();
  });
}
