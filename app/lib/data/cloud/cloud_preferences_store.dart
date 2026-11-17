import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 增量同步的本机游标：服务端已经对齐到 [serverHead]，本机编号不超过
/// [pushedThrough] 的提交都已经在服务端序列里。
///
/// [remoteLocalIds] 是拉取远端提交之后在本机新生成的提交编号：它们对应服务端
/// 已有的提交，推送时要跳过，成功推送之后随 [pushedThrough] 一起清空。
class SyncState {
  const SyncState({
    required this.userId,
    required this.serverHead,
    required this.pushedThrough,
    this.remoteLocalIds = const {},
    this.syncedAt,
  });

  factory SyncState.fromJson(Map<String, Object?> json) => SyncState(
    userId: json['user_id'] as String? ?? '',
    serverHead: (json['server_head'] as num?)?.toInt() ?? 0,
    pushedThrough: (json['pushed_through'] as num?)?.toInt() ?? 0,
    remoteLocalIds: {
      for (final id in (json['remote_local_ids'] as List? ?? const []))
        if (id is num) id.toInt(),
    },
    syncedAt: DateTime.tryParse(json['synced_at'] as String? ?? ''),
  );

  final String userId;
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
      serverHead: serverHead ?? this.serverHead,
      pushedThrough: pushedThrough ?? this.pushedThrough,
      remoteLocalIds: remoteLocalIds ?? this.remoteLocalIds,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'server_head': serverHead,
    'pushed_through': pushedThrough,
    'remote_local_ids': remoteLocalIds.toList()..sort(),
    'synced_at': syncedAt?.toUtc().toIso8601String(),
  };
}

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

  Future<String> serverBaseUrl() async {
    final raw = await _read();
    final value = raw['server_base_url'];
    return value is String ? value.trim() : '';
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

  Future<SyncState?> syncState() async {
    final raw = await _read();
    final state = raw['sync_state'];
    if (state is! Map) return null;
    final decoded = SyncState.fromJson(state.cast<String, Object?>());
    return decoded.userId.isEmpty ? null : decoded;
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
