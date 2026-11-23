part of 'sync_service.dart';

extension SyncDeviceRoster on SyncService {
  /// 名册的副本，按最近出现时间倒序；还没读过或没登录时为空。
  List<SyncRosterDevice> get devices => List.unmodifiable(_devices);

  /// 一台设备的别名；名册里没有这台设备或它没有别名时为空。
  ///
  /// 界面据此决定显示别名还是设备标识前 8 位，不改写提交里的设备标识。
  String? deviceAlias(String deviceId) {
    final value = _deviceAliases[deviceId.trim()];
    return value == null || value.isEmpty ? null : value;
  }

  /// 拉一次设备名册并替换缓存。
  ///
  /// 未登录时清空缓存；读取失败只记一条诊断，不影响同步结果与页面其他内容
  /// （ADR-0048）。每次同步成功之后由 [syncNow] 调用，账号页与数据版本页打开
  /// 时也各调用一次。
  Future<void> refreshDevices() async {
    try {
      final snapshot = await account.snapshot();
      if (!snapshot.signedIn) {
        _devices.clear();
        _deviceAliases.clear();
        return;
      }
      final deviceId = await account.deviceId();
      final roster = await account.call(
        (client, token) => client.devices(token, deviceId: deviceId),
      );
      _devices
        ..clear()
        ..addAll([
          for (final device in roster) SyncRosterDevice.fromServer(device),
        ])
        ..sort(_byRecentDevice);
      _rememberDeviceAliases();
    } catch (error, stack) {
      recordFailure(error, stack, kind: 'cloud_sync_devices');
    }
  }

  /// 改一台设备的别名，成功之后用服务端返回的设备对象更新缓存。
  ///
  /// 失败向上抛出，由界面按统一的失败说明提示；缓存保持原样（ADR-0048）。
  Future<void> renameDevice(String deviceId, String alias) async {
    final snapshot = await account.snapshot();
    if (!snapshot.signedIn) throw const AccountSignedOut();
    final updated = await account.call(
      (client, token) =>
          client.renameDevice(token, deviceId: deviceId, alias: alias),
    );
    _putDevice(SyncRosterDevice.fromServer(updated));
  }

  /// 把整份名册的别名重建进索引。
  void _rememberDeviceAliases() {
    _deviceAliases
      ..clear()
      ..addEntries([
        for (final device in _devices)
          if (device.trimmedAlias.isNotEmpty)
            MapEntry(device.deviceId, device.trimmedAlias),
      ]);
  }

  /// 用一台设备的最新状态替换或插入缓存，并按最近出现时间重排。
  void _putDevice(SyncRosterDevice device) {
    final index = _devices.indexWhere(
      (item) => item.deviceId == device.deviceId,
    );
    if (index >= 0) {
      _devices[index] = device;
    } else {
      _devices.add(device);
    }
    _devices.sort(_byRecentDevice);
    if (device.trimmedAlias.isEmpty) {
      _deviceAliases.remove(device.deviceId);
    } else {
      _deviceAliases[device.deviceId] = device.trimmedAlias;
    }
  }

  /// 名册排序：最近出现的在前，读不出时间的排在最后。
  static int _byRecentDevice(SyncRosterDevice a, SyncRosterDevice b) {
    final left = a.lastSeen;
    final right = b.lastSeen;
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return right.compareTo(left);
  }
}
