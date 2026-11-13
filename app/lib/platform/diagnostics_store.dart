import 'dart:io';

import 'package:path/path.dart' as p;

/// 崩溃报告开关：写在应用私有目录的小文件里，下次启动时应用。
///
/// 关闭后不再把异常交给 Sentry；本机诊断文件仍照常写入，便于离线排查。
class DiagnosticsStore {
  const DiagnosticsStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'diagnostics_reporting');

  Future<bool> read({bool fallback = true}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return fallback;
      return (await file.readAsString()).trim() == 'on';
    } catch (_) {
      return false;
    }
  }

  Future<void> write(bool enabled) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(enabled ? 'on' : 'off', flush: true);
  }
}
