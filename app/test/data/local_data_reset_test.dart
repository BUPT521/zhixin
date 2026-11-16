import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/db/local_data_reset.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zhixin_reset_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> writeFile(String path) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes([1, 2, 3]);
  }

  test('删除库、图片、语义索引与恢复点', () async {
    final dbPath = p.join(root.path, 'zhixin.db');
    await writeFile(dbPath);
    await writeFile('$dbPath-wal');
    await writeFile('$dbPath-shm');
    await writeFile(p.join(root.path, 'question_images', 'a.jpg'));
    await writeFile(
      p.join(root.path, 'vector_index', 'abc123', 'seg_0', 'data'),
    );
    await writeFile(p.join(root.path, 'vector_index', 'abc123.json'));
    await writeFile(p.join(root.path, 'data_versions', 'old.bin'));
    await writeFile(p.join(root.path, 'restore_points', 'point.bin'));
    await writeFile(p.join(root.path, '.restore-1700000000000', 'zhixin.db'));

    await deleteLocalStudyData(
      filesDir: root.path,
      dbPath: dbPath,
      vectorIndexPath: p.join(root.path, 'vector_index'),
    );

    expect(File(dbPath).existsSync(), isFalse);
    expect(File('$dbPath-wal').existsSync(), isFalse);
    expect(File('$dbPath-shm').existsSync(), isFalse);
    expect(
      Directory(p.join(root.path, 'question_images')).existsSync(),
      isFalse,
    );
    expect(Directory(p.join(root.path, 'vector_index')).existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'data_versions')).existsSync(), isFalse);
    expect(
      Directory(p.join(root.path, 'restore_points')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(root.path, '.restore-1700000000000')).existsSync(),
      isFalse,
    );
  });

  test('语义索引目录不在本机数据目录下时拒绝删除', () async {
    final dbPath = p.join(root.path, 'zhixin.db');
    await writeFile(dbPath);

    await expectLater(
      deleteLocalStudyData(
        filesDir: root.path,
        dbPath: dbPath,
        vectorIndexPath: p.join(root.parent.path, 'elsewhere', 'vector_index'),
      ),
      throwsArgumentError,
    );
    // 校验在删除之前完成，库文件仍然在。
    expect(File(dbPath).existsSync(), isTrue);
  });
}
