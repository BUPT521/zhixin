import 'dart:math';

import 'package:path/path.dart' as p;

import '../atomic_file.dart';

/// 匿名活跃上报的本机状态（ADR-0019）：安装标识、上次上报的日期、首次说明是否
/// 看过，以及开关。
///
/// 文件写在应用私有目录，不进入数据库、数据包与整库备份：安装标识属于这台设备
/// 的安装，换机或恢复备份之后应当重新生成，而不是沿用别的设备或另一次安装的
/// 标识。卸载应用或清空应用数据时文件一起删除。
///
/// 读写走 [AtomicJsonFile]：先写临时文件再改名，同一文件上的读改写排队，写一半
/// 崩掉不会留下半份 JSON，两个动作同时改也不会互相覆盖。
class TelemetryStore {
  const TelemetryStore({required this.filesDir});

  final String filesDir;

  static const String fileName = 'telemetry.json';

  String get path => p.join(filesDir, fileName);

  AtomicJsonFile get _file => AtomicJsonFile(path);

  /// 读一次全部状态；文件不存在、内容损坏或读不出来时按空状态处理，下一次写入
  /// 会重新生成文件。统计是附加信息，不值得因为它报错打断启动。
  Future<Map<String, Object?>> read() => _file.read();

  /// 安装标识：首次读取时生成 32 位十六进制并保存。只含随机数，不含设备编号、
  /// 账号、IP 或任何学习内容；上报时服务端只保存它的 HMAC-SHA256。
  ///
  /// 已经有了就直接返回，不重写文件；需要生成时才排进队列，队列里再确认一次，
  /// 两个调用同时走到这里时也只会生成一个。
  Future<String> installId() async {
    final existing = (await read())['install_id'];
    if (existing is String && existing.length >= 16) return existing;
    return _file.updateAndGet((data) {
      final raced = data['install_id'];
      if (raced is String && raced.length >= 16) return raced;
      final created = _randomHex(16);
      data['install_id'] = created;
      return created;
    });
  }

  /// 是否允许匿名上报，默认开启；用户关闭之后不再上报，已经上报的记录保留。
  Future<bool> enabled() async => (await read())['enabled'] != false;

  Future<void> setEnabled(bool value) => _file.update((data) {
    data['enabled'] = value;
  });

  /// 上次成功上报的日期（本机自然日）；同一天不再重复上报。
  Future<String?> lastReportDay() async {
    final value = (await read())['last_report_day'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> setLastReportDay(String day) => _file.update((data) {
    data['last_report_day'] = day;
  });

  /// 首次使用的说明是否已经看过；没看过之前不上报，见 [ActiveReportService]。
  Future<bool> noticeSeen() async => (await read())['notice_seen'] == true;

  Future<void> markNoticeSeen() => _file.update((data) {
    data['notice_seen'] = true;
  });

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
