import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/diagnostics/crash_log.dart';

void main() {
  test('诊断记录清除 SQL 文本与绑定参数', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_crash_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final log = CrashLog(
      filesDir: dir.path,
      clock: () => DateTime(2026, 11, 10, 10),
    );
    log.record(
      StateError(
        "database error sql 'INSERT INTO message(content) VALUES (?)' "
        'args [真正的学习正文] parameters: [真正的学习正文]',
      ),
      null,
      kind: 'database',
    );
    final raw = File(log.path).readAsStringSync();
    expect(raw, isNot(contains('真正的学习正文')));
    expect(raw, contains('已清除'));
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    expect(decoded['crashes'], hasLength(1));
  });

  test('诊断记录清除本机绝对路径，保留服务地址', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_crash_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final log = CrashLog(
      filesDir: dir.path,
      clock: () => DateTime(2026, 11, 10, 10),
    );
    log.record(
      StateError(
        r'读取失败 C:\Users\olive\zhixin\question_images\原题.jpg '
        '与 /data/user/0/com.zhixin.app/files/images/题目.jpg，'
        '服务地址 https://api.example.com/v1/chat 不变',
      ),
      null,
      kind: 'read',
    );
    final raw = File(log.path).readAsStringSync();
    expect(raw, isNot(contains(r'C:\Users\olive')));
    expect(raw, isNot(contains('/data/user/0/com.zhixin.app')));
    expect(raw, contains('https://api.example.com/v1/chat'));
    expect(raw, contains('[路径已清除]'));
  });

  test('诊断记录清除服务端错误里带出的密钥', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_crash_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final log = CrashLog(
      filesDir: dir.path,
      clock: () => DateTime(2026, 11, 10, 10),
    );
    log.record(
      StateError(
        '401 invalid key sk-live-1234567890 '
        'Authorization: Bearer token-abcdef '
        'api_key=plain-secret',
      ),
      null,
      kind: 'model_call',
    );
    final raw = File(log.path).readAsStringSync();
    expect(raw, isNot(contains('sk-live-1234567890')));
    expect(raw, isNot(contains('token-abcdef')));
    expect(raw, isNot(contains('plain-secret')));
    expect(raw, contains('[密钥已清除]'));
  });
}
