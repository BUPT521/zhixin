import 'dart:io';

import 'package:path/path.dart' as p;

/// 外观偏好保存在应用私有目录的一个小文件里。
///
/// 不放进数据库，因为主题要在第一帧就生效，而数据库是异步打开的；外观也只
/// 属于这台手机，不随数据包导出或恢复。文件缺失或读不出来时由调用方退回
/// 跟随系统。
class ThemeModeStore {
  const ThemeModeStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'theme_mode');

  Future<String?> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> write(String value) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(value, flush: true);
  }
}
