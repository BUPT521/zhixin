import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';

/// 外观偏好保存在应用私有目录的一个小文件里。
///
/// 不放进数据库，因为主题要在第一帧就生效，而数据库是异步打开的；外观也只
/// 属于这台手机，不随数据包导出或恢复。文件缺失或读不出来时由调用方退回
/// 跟随系统。
///
/// 写入先落临时文件再改名，同一文件上的写入排队，连续切换外观时不会读出只写了
/// 一半的内容。
class ThemeModeStore {
  const ThemeModeStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'theme_mode');

  AtomicFile get _file => AtomicFile(path);

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

  Future<void> write(String value) => _file.writeText(value);
}
