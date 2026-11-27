import 'package:path/path.dart' as p;

import '../atomic_file.dart';

/// 编译时确定的默认服务地址：正式包指向项目组的第一套实例，本地联调用
/// `--dart-define=ZHIXIN_SERVER_URL=http://127.0.0.1:8080` 覆盖。
///
/// 账号可选，登录默认连接项目组提供的实例。开发者模式可以改用自建知新实例。
const String defaultServerBaseUrl = String.fromEnvironment(
  'ZHIXIN_SERVER_URL',
  defaultValue: 'https://zhixin.chensiyuan.work',
);

/// 设备级云服务偏好：服务地址与开发者模式。
///
/// 这两项属于这台设备，不随账号空间切换：一台设备上只有一个服务地址，开发者
/// 模式也只在当前安装里有效。文件放在应用私有目录根下，与空间级的同步偏好
/// [SyncPreferencesStore] 用两个不同的文件名：装配时漏传一个目录，也不会把
/// 另一类偏好的内容覆盖掉。
class DevicePreferencesStore {
  DevicePreferencesStore({required this.filesDir});

  static const String fileName = 'device.json';

  final String filesDir;

  String get path => p.join(filesDir, fileName);

  AtomicJsonFile get _file => AtomicJsonFile(path);

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

  Future<bool> developerMode() async =>
      (await _file.read())['developer_mode'] == true;

  Future<void> setDeveloperMode(bool enabled) => _file.update((raw) {
    raw['developer_mode'] = enabled;
  });
}
