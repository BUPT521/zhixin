import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';

/// 主题色与外观偏好放在同一个应用私有目录里，写法也相同：一个小文件、先写
/// 临时文件再改名。
///
/// 与 `theme_mode` 分成两个文件，是因为两件事各自保存：换深浅色不影响选中的
/// 主题色，换主题色也不影响深浅色。文件缺失或读不出来时由调用方回到默认的
/// 蓝色。
class ThemeAccentStore {
  const ThemeAccentStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'theme_accent');

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
