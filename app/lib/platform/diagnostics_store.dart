import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/atomic_file.dart';

/// 崩溃报告开关：写在应用私有目录的小文件里，下次启动时应用。
///
/// 关闭后不再把异常交给 Sentry；本机诊断文件仍照常写入，便于离线排查。
///
/// 写入先落临时文件再改名，同一文件上的写入排队，设置页连续切换时不会读出只写了
/// 一半的内容。
class DiagnosticsStore {
  const DiagnosticsStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'diagnostics_reporting');

  AtomicFile get _file => AtomicFile(path);

  Future<bool> read({bool fallback = true}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return fallback;
      return (await file.readAsString()).trim() == 'on';
    } catch (_) {
      return false;
    }
  }

  Future<void> write(bool enabled) => _file.writeText(enabled ? 'on' : 'off');
}
