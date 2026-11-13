import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/backup/restore_point_store.dart';

void main() {
  late Directory dir;
  late DateTime now;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zhixin_restore_points_');
    now = DateTime(2026, 11, 11, 10);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> writeBytes(String path) async {
    await File(path).writeAsBytes([1, 2, 3]);
  }

  test('保存恢复点写包与说明，列表按时间倒序', () async {
    final store = RestorePointStore(filesDir: dir.path, clock: () => now);
    final first = await store.capture(
      write: writeBytes,
      head: 10,
      commitCount: 3,
      namedCount: 1,
      reason: '第一次',
    );
    now = now.add(const Duration(minutes: 1));
    final second = await store.capture(
      write: writeBytes,
      head: 12,
      commitCount: 4,
      namedCount: 2,
      reason: '第二次',
    );

    expect(await File(first.path).length(), 3);
    final points = await store.list();
    expect(points.map((point) => point.path), [second.path, first.path]);
    expect(points.first.head, 12);
    expect(points.first.commitCount, 4);
    expect(points.first.namedCount, 2);
    expect(points.first.reason, '第二次');
    expect(await store.read(first), [1, 2, 3]);
  });

  test('超过保留份数时删除最早的恢复点', () async {
    final store = RestorePointStore(
      filesDir: dir.path,
      clock: () => now,
      keep: 2,
    );
    final saved = <RestorePoint>[];
    for (var i = 0; i < 3; i++) {
      saved.add(
        await store.capture(
          write: writeBytes,
          head: i,
          commitCount: i,
          namedCount: 0,
          reason: '第 $i 份',
        ),
      );
      now = now.add(const Duration(minutes: 1));
    }

    final points = await store.list();
    expect(points, hasLength(2));
    expect(points.map((point) => point.head), [2, 1]);
    final oldest = saved.first.path;
    expect(await File(oldest).exists(), isFalse);
    expect(
      await File('${oldest.substring(0, oldest.length - 4)}.json').exists(),
      isFalse,
    );
  });

  test('写包失败时不发布半成品，目录里不留恢复点', () async {
    final store = RestorePointStore(filesDir: dir.path, clock: () => now);
    await expectLater(
      store.capture(
        write: (path) async {
          await File(path).writeAsBytes([1]);
          throw StateError('写不进去');
        },
        head: 1,
        commitCount: 0,
        namedCount: 0,
        reason: '',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await store.list(), isEmpty);
  });

  test('删除恢复点时说明文件一起删除', () async {
    final store = RestorePointStore(filesDir: dir.path, clock: () => now);
    final point = await store.capture(
      write: writeBytes,
      head: 1,
      commitCount: 1,
      namedCount: 0,
      reason: '',
    );

    await store.delete(point);
    expect(await File(point.path).exists(), isFalse);
    expect(
      await Directory('${dir.path}${Platform.pathSeparator}restore_points')
          .list()
          .toList(),
      isEmpty,
    );
  });
}
