import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../domain/models/diagnostics.dart';
import '../../domain/rules/time_format.dart';

/// 本机崩溃记录：一个 JSON 文件，记启动次数与最近几次未捕获错误；配置了 DSN 时
/// 同一份脱敏后的说明与调用栈也上报自建 Sentry。
///
/// 不联网、不进数据包、不写学习内容；文件写不进去时静默放弃，不能因为记录
/// 崩溃而让应用起不来。清空全部学习数据时保留这个文件，用户可在设置里单独清。
class CrashLog {
  CrashLog({required this.filesDir, DateTime Function()? clock, this.keep = 20})
    : _clock = clock ?? DateTime.now;

  static const String fileName = 'diagnostics.json';

  final String filesDir;

  /// 最多保留几条错误，超出后丢最旧的。
  final int keep;
  final DateTime Function() _clock;

  /// 一条错误里最多保留多少字符，避免调用栈把文件撑大。
  static const int maxMessageLength = 300;
  static const int maxStackLength = 3000;

  String get path => p.join(filesDir, fileName);

  /// 读当前汇总；文件缺失或损坏时当作空记录，不抛异常。
  CrashSummary summary() {
    final data = _read();
    final raw = data['crashes'];
    final crashes = <CrashEntry>[];
    if (raw is List) {
      for (final item in raw) {
        final entry = _entryFrom(item);
        if (entry != null) crashes.add(entry);
      }
    }
    crashes.sort((a, b) => b.at.compareTo(a.at));
    return CrashSummary(launches: _intOf(data['launches']), crashes: crashes);
  }

  /// 每次启动加一；与 [record] 一样在应用启动时调用。
  void recordLaunch() {
    final data = _read();
    data['launches'] = _intOf(data['launches']) + 1;
    _write(data);
  }

  /// 记一条错误。崩溃时进程可能马上结束，所以同步写盘，写完再返回。
  void record(Object error, StackTrace? stack, {String kind = 'platform'}) {
    final data = _read();
    final raw = data['crashes'];
    final crashes = <Object?>[
      if (raw is List) ...raw,
      {
        'at': formatDateTime(_clock()),
        'kind': kind,
        'message': _clip(_sanitize(error.toString()), maxMessageLength),
        'stack': _clip(stack?.toString() ?? '', maxStackLength),
      },
    ];
    data['crashes'] = crashes.length > keep
        ? crashes.sublist(crashes.length - keep)
        : crashes;
    _write(data);
    _report(error, stack, kind);
  }

  /// 上报脱敏后的类型与说明，不把 SQL、绑定参数或学习正文交给 Sentry。
  void _report(Object error, StackTrace? stack, String kind) {
    try {
      unawaited(
        Sentry.captureException(
          DiagnosticError(
            kind,
            _clip(_sanitize(error.toString()), maxMessageLength),
          ),
          stackTrace: stack,
        ),
      );
    } catch (_) {
      // 上报失败不能影响本机记录。
    }
  }

  /// 只清错误，保留启动次数，崩溃率的分母不变。
  void clear() {
    final data = _read();
    data['crashes'] = <Object?>[];
    _write(data);
  }

  /// 导出给测试排查用的字节；文件读不到时给当前汇总，不导出空文件。
  Uint8List bytes() {
    try {
      final file = File(path);
      if (file.existsSync()) return file.readAsBytesSync();
    } catch (_) {
      // 读不到就退回下面的汇总。
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'launches': summary().launches,
          'crashes': const <Object?>[],
        }),
      ),
    );
  }

  Map<String, Object?> _read() {
    try {
      final file = File(path);
      if (!file.existsSync()) return <String, Object?>{};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return <String, Object?>{};
      return decoded;
    } catch (_) {
      return <String, Object?>{};
    }
  }

  /// 先写临时文件再替换，写到一半被杀时旧的记录还在。
  void _write(Map<String, Object?> data) {
    final temp = File('$path.tmp');
    try {
      final directory = Directory(filesDir);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      temp.writeAsStringSync(jsonEncode(data), flush: true);
      temp.renameSync(path);
    } catch (_) {
      // 记录诊断信息失败不影响应用使用。
    }
  }

  CrashEntry? _entryFrom(Object? item) {
    if (item is! Map) return null;
    final at = DateTime.tryParse(item['at']?.toString() ?? '');
    if (at == null) return null;
    return CrashEntry(
      at: at,
      kind: item['kind']?.toString() ?? 'platform',
      message: item['message']?.toString() ?? '',
      stack: item['stack']?.toString() ?? '',
    );
  }

  int _intOf(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _clip(String value, int max) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…';
  }

  /// 诊断只用于排障：去掉 SQL 文本、参数、绑定值、本机绝对路径与密钥，避免
  /// 学习正文、用户文件位置与 API Key 进入日志。服务地址保留，`https://` 这类
  /// 写法不当作路径。
  String _sanitize(String value) {
    var text = value;
    text = text.replaceAll(
      RegExp(r"sql\s*'(?:[^']|'')*'", caseSensitive: false),
      "sql '[已清除]'",
    );
    text = text.replaceAll(
      RegExp(r'parameters:\s*\[[^\]]*\]', caseSensitive: false),
      'parameters: [已清除]',
    );
    text = text.replaceAll(
      RegExp(r'\bargs\s*\[[^\]]*\]', caseSensitive: false),
      'args [已清除]',
    );
    text = text.replaceAll(RegExp(r'file://\S+'), '[路径已清除]');
    text = text.replaceAll(RegExp(r'[A-Za-z]:\\[^\s，。；、)）\]】]+'), '[路径已清除]');
    text = text.replaceAll(
      RegExp(r'(?<![:\w/])/(?:[^\s/]+/)+[^\s，。；、)）\]】]+'),
      '[路径已清除]',
    );
    // 服务端错误原样带出 key 时也不要留在诊断记录里。
    text = text.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_\-]{4,}'), '[密钥已清除]');
    text = text.replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      'Bearer [密钥已清除]',
    );
    text = text.replaceAll(
      RegExp(r'api[_-]?key\s*[=:]\s*\S+', caseSensitive: false),
      'api_key=[密钥已清除]',
    );
    return text;
  }
}

/// 上报给 Sentry 的脱敏错误：只保留类型与清理过的说明，不带原始正文。
class DiagnosticError implements Exception {
  const DiagnosticError(this.kind, this.message);

  final String kind;
  final String message;

  @override
  String toString() => 'DiagnosticError(): ';
}
