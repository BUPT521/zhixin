import 'package:path/path.dart' as p;

import '../application/crash_reporting.dart';
import '../data/atomic_file.dart';

/// 崩溃报告开关：写在应用私有目录的小文件里，下次启动时应用。
///
/// 关闭后不再把异常交给 Sentry；本机诊断文件仍照常写入，便于离线排查。
///
/// 读写都走 [AtomicFile]：写入先落临时文件再改名，同一文件上的写入排队，设置页
/// 连续切换时不会读出只写了一半的内容；读不出来时返回 [fallback]，与文件不存在
/// 时的处理相同。
class DiagnosticsStore implements CrashReportingSwitch {
  const DiagnosticsStore(this.filesDir);

  final String filesDir;

  String get path => p.join(filesDir, 'diagnostics_reporting');

  AtomicFile get _file => AtomicFile(path);

  /// 读开关；文件不存在、内容损坏或读不出来时返回 [fallback]。
  @override
  Future<bool> read({bool fallback = true}) async {
    final value = await _file.readText();
    if (value == null) return fallback;
    return value.trim() == 'on';
  }

  @override
  Future<void> write(bool enabled) => _file.writeText(enabled ? 'on' : 'off');
}
