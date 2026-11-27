import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/data/atomic_file.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin_atomic_file');
  });

  tearDown(() async {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  String filePath(String name) => p.join(directory.path, 'nested', name);

  test('异步读写走同一个入口，临时文件用同一种后缀', () async {
    final file = AtomicFile(filePath('settings'));
    expect(await file.readText(), isNull);

    await file.writeText('first');
    expect(await file.readText(), 'first');
    await file.writeText('second');
    expect(await file.readText(), 'second');
    expect(
      File('${file.path}${AtomicFile.temporarySuffix}').existsSync(),
      isFalse,
    );
  });

  test('同步读写给不等异步的调用方使用，失败时按没有这个文件处理', () async {
    final file = AtomicFile(filePath('crash'));
    expect(file.readTextSync(), isNull);

    file.writeTextSync('record');
    expect(file.readTextSync(), 'record');
    expect(
      File('${file.path}${AtomicFile.temporarySuffix}').existsSync(),
      isFalse,
    );

    // 内容不是合法文本时按读不出来处理，由调用方给兜底值。
    File(file.path).writeAsBytesSync([255, 255]);
    expect(file.readTextSync(), isNull);
    expect(await file.readText(), isNull);
  });

  test('写字节与写文本共用一条队列与同一种临时后缀', () async {
    final file = AtomicFile(filePath('attachment'));
    await file.writeBytes([1, 2, 3]);
    expect(await File(file.path).readAsBytes(), [1, 2, 3]);
    expect(
      File('${file.path}${AtomicFile.temporarySuffix}').existsSync(),
      isFalse,
    );

    // 写入失败时同样不留半份临时文件。
    final blocked = AtomicFile(filePath('blocked'));
    await Directory(blocked.path).create(recursive: true);
    await expectLater(
      blocked.writeBytes([4, 5]),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      File('${blocked.path}${AtomicFile.temporarySuffix}').existsSync(),
      isFalse,
    );
  });

  test('JSON 对象文件复用同一份读取与原子替换', () async {
    final file = AtomicJsonFile(filePath('prefs'));
    expect(await file.read(), isEmpty);

    await file.update((data) {
      data['stage'] = 'login';
    });
    expect((await file.read())['stage'], 'login');

    await File(file.path).writeAsString('不是 JSON');
    expect(await file.read(), isEmpty);
    expect(
      File('${file.path}${AtomicFile.temporarySuffix}').existsSync(),
      isFalse,
    );
  });
}
