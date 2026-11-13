import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/data/db/app_database.dart';
import 'package:zhixin/data/db/database_gate.dart';
import 'package:zhixin/data/db/guarded_database.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

/// Dart VM 上的粗略计时，只作为 Android 真机测量的参照，不设通过阈值。
///
/// 运行：`cd app && flutter test test/data/revision_benchmark_test.dart -r expanded`
void main() {
  setUpAll(sqfliteFfiInit);

  test('Dart VM 基准：提交、图片写入与整版恢复', () async {
    final dir = await Directory.systemTemp.createTemp('zhixin_benchmark_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final path = '${dir.path}/zhixin.db';
    final raw = await openZhixinDatabase(path: path);
    addTearDown(raw.close);
    final engine = RevisionEngine();
    final db = GuardedDatabase(
      gate: DatabaseGate(),
      resolve: () => raw,
      revisions: engine,
    );
    final rssBefore = ProcessInfo.currentRss;

    const commits = 200;
    final watch = Stopwatch()..start();
    for (var index = 0; index < commits; index++) {
      await db.insert('memory', {
        'kind': 'preference',
        'content': '第 $index 条记忆',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10T10:00:00',
        'updated_at': '2026-11-10T10:00:00',
      });
    }
    watch.stop();
    final commitMs = watch.elapsedMicroseconds / commits / 1000;

    final image = Uint8List.fromList(
      List<int>.generate(1024 * 1024, (index) => index % 251),
    );
    final hash = AssetStore.hashBytes(image);
    final imageWatch = Stopwatch()..start();
    final conversation = await db.insert('conversation', {
      'title': '基准图片',
      'entry_kind': 'photo',
      'status': 'open',
      'created_at': '2026-11-10T10:00:00',
      'updated_at': '2026-11-10T10:00:00',
    });
    await db.transaction((txn) async {
      await engine.assets.putBytes(txn.raw, hash, image);
      await txn.insert('message', {
        'conversation_id': conversation,
        'role': 'user',
        'content': '',
        'image_paths_json': '["$hash"]',
        'created_at': '2026-11-10T10:00:00',
      });
    });
    imageWatch.stop();

    final head = await engine.headId(raw.rawDb);
    final restoreWatch = Stopwatch()..start();
    await engine.restore(raw.rawDb, 50, expectedHead: head);
    restoreWatch.stop();

    final page = await raw.rawQuery('PRAGMA page_count');
    final size = await raw.rawQuery('PRAGMA page_size');
    final pageCount = page.first.values.first! as int;
    final pageSize = size.first.values.first! as int;
    final wal = File('$path-wal');
    final rssAfter = ProcessInfo.currentRss;

    // ignore: avoid_print
    print('Dart VM 基准（不是 Android 真机数据）');
    // ignore: avoid_print
    print('提交次数：$commits');
    // ignore: avoid_print
    print('单次提交平均：${commitMs.toStringAsFixed(3)} ms');
    // ignore: avoid_print
    print('1 MB 图片写入并提交：${imageWatch.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('整版恢复到第 50 条提交：${restoreWatch.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('数据库大小：${(pageCount * pageSize / 1024).toStringAsFixed(1)} KB');
    if (wal.existsSync()) {
      // ignore: avoid_print
      print('WAL 大小：${(wal.lengthSync() / 1024).toStringAsFixed(1)} KB');
    }
    // ignore: avoid_print
    print(
      '进程常驻内存：${(rssBefore / 1024 / 1024).toStringAsFixed(1)} MB → '
      '${(rssAfter / 1024 / 1024).toStringAsFixed(1)} MB',
    );
    expect(head, greaterThan(commits));
  }, timeout: Timeout.none);
}
