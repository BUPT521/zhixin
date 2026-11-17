import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 匿名活跃上报的本机状态（ADR-0019）：安装标识、上次上报的日期、首次说明是否
/// 看过，以及开关。
///
/// 文件写在应用私有目录，不进入数据库、数据包与整库备份：安装标识属于这台设备
/// 的安装，换机或恢复备份之后应当重新生成，而不是沿用别的设备或另一次安装的
/// 标识。卸载应用或清空应用数据时文件一起删除。
class TelemetryStore {
  const TelemetryStore({required this.filesDir});

  final String filesDir;

  static const String fileName = 'telemetry.json';

  String get path => p.join(filesDir, fileName);

  /// 读一次全部状态；文件不存在、内容损坏或读不出来时按空状态处理，下一次写入
  /// 会重新生成文件。统计是附加信息，不值得因为它报错打断启动。
  Future<Map<String, Object?>> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, Object?> data) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  /// 安装标识：首次读取时生成 32 位十六进制并保存。只含随机数，不含设备编号、
  /// 账号、IP 或任何学习内容；上报时服务端只保存它的 HMAC-SHA256。
  Future<String> installId() async {
    final data = await read();
    final existing = data['install_id'];
    if (existing is String && existing.length >= 16) return existing;
    final created = _randomHex(16);
    data['install_id'] = created;
    await _write(data);
    return created;
  }

  /// 是否允许匿名上报，默认开启；用户关闭之后不再上报，已经上报的记录保留。
  Future<bool> enabled() async => (await read())['enabled'] != false;

  Future<void> setEnabled(bool value) async {
    final data = await read();
    data['enabled'] = value;
    await _write(data);
  }

  /// 上次成功上报的日期（本机自然日）；同一天不再重复上报。
  Future<String?> lastReportDay() async {
    final value = (await read())['last_report_day'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> setLastReportDay(String day) async {
    final data = await read();
    data['last_report_day'] = day;
    await _write(data);
  }

  /// 首次使用的说明是否已经看过；没看过之前不上报，见 [ActiveReportService]。
  Future<bool> noticeSeen() async => (await read())['notice_seen'] == true;

  Future<void> markNoticeSeen() async {
    final data = await read();
    data['notice_seen'] = true;
    await _write(data);
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
