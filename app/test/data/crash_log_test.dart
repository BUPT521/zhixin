import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zhixin/data/diagnostics/crash_log.dart';
import 'package:zhixin/platform/diagnostics_store.dart';

void main() {
  test('SQLite 异常在本机记录里只保留数字错误码', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_crash_');
    addTearDown(() => dir.delete(recursive: true));
    final log = CrashLog(filesDir: dir.path);
    log.record(
      SqliteException(
        extendedResultCode: 2067,
        message: '示例学习正文',
        causingStatement: 'INSERT INTO message(content) VALUES (?)',
        parametersToStatement: ['示例绑定值'],
      ),
      null,
      kind: 'database',
    );
    expect(log.summary().crashes.single.message, 'SqliteException(2067)');
  });

  test('上报只保留异常类型、分类和代码位置', () {
    final previous = CrashLog.reportEnabled;
    addTearDown(() => CrashLog.reportEnabled = previous);
    final event = SentryEvent(
      throwable: SqliteException(extendedResultCode: 2067, message: '学习内容'),
      release: 'zhixin@test',
      request: SentryRequest(url: 'https://example.test/?q=学习内容'),
      user: SentryUser(email: 'example@example.test'),
      breadcrumbs: [Breadcrumb(message: '学习内容')],
      exceptions: [
        SentryException(
          type: 'SqliteException',
          value: '学习内容',
          mechanism: Mechanism(
            type: 'PlatformDispatcher.onError',
            handled: false,
          ),
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                absPath: 'package:zhixin/app.dart',
                fileName: 'app.dart',
                function: 'read',
                contextLine: '学习内容',
              ),
              SentryStackFrame(absPath: 'file:///tmp/private/answer.dart'),
            ],
          ),
        ),
      ],
    );
    final hint = Hint.withAttachment(
      SentryAttachment.fromUint8List(utf8.encode('学习内容'), 'answer.txt'),
    );

    CrashLog.reportEnabled = false;
    expect(prepareCrashReport(event, hint), isNull);
    CrashLog.reportEnabled = true;
    final filtered = prepareCrashReport(event, hint)!;
    final json = jsonEncode(filtered.toJson());
    expect(filtered.release, 'zhixin@test');
    expect(filtered.exceptions!.single.mechanism!.handled, isFalse);
    expect(json, contains('SQLite 2067'));
    expect(json, contains('package:zhixin/app.dart'));
    expect(json, isNot(contains('学习内容')));
    expect(json, isNot(contains('example.test')));
    expect(json, isNot(contains('answer.dart')));
    expect(hint.attachments, isEmpty);
  });

  test('崩溃报告开关损坏或无法读取时关闭上报', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_diagnostics_');
    addTearDown(() => dir.delete(recursive: true));
    final store = DiagnosticsStore(dir.path);
    expect(await store.read(fallback: false), isFalse);
    expect(await store.read(), isTrue);
    await store.write(true);
    expect(await store.read(fallback: false), isTrue);
    await File(store.path).writeAsBytes([255, 255]);
    expect(await store.read(), isFalse);
    await File(store.path).writeAsString('invalid');
    expect(await store.read(), isFalse);
  });

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
