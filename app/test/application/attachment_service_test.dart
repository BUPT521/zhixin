import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/attachment_service.dart';
import 'package:zhixin/domain/rules/attachments.dart';

void main() {
  late Directory root;
  late Directory images;
  late AttachmentService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zhixin-attachments-');
    images = Directory('${root.path}/$questionImagesDirName');
    await images.create(recursive: true);
    service = AttachmentService(filesDir: () => root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('同内容图片只占一个发送名额，并说明其他图片的遗漏原因', () async {
    await File('${images.path}/ok.jpg').writeAsBytes([1, 2, 3]);
    await File('${images.path}/copy.jpg').writeAsBytes([1, 2, 3]);
    await File('${images.path}/large.jpg')
        .writeAsBytes(List<int>.filled(4 * 1024 * 1024 + 1, 1));
    await File('${images.path}/third.jpg').writeAsBytes([4]);
    await File('${images.path}/fourth.jpg').writeAsBytes([5]);

    final result = await service.prepare([
      'ok.jpg',
      'copy.jpg',
      'large.jpg',
      'third.jpg',
      'fourth.jpg',
    ], enabled: true);

    expect(result.images.map((image) => image.bytes.toList()), [
      [1, 2, 3],
      [4],
    ]);
    expect(result.images.map((image) => image.id).toSet(), hasLength(2));
    expect(result.omitted.map((item) => item.reason), [
      AttachmentOmissionReason.tooLarge,
      AttachmentOmissionReason.tooMany,
    ]);
    expect(result.notice, contains('超过 4 MB'));
    expect(result.notice, contains('超过两张'));
  });

  test('图片上传关闭或文件缺失时返回原因，不静默略过', () async {
    final disabled = await service.prepare(['missing.jpg'], enabled: false);
    expect(disabled.images, isEmpty);
    expect(disabled.notice, contains('图片上传已关闭'));

    final missing = await service.prepare(['missing.jpg'], enabled: true);
    expect(missing.images, isEmpty);
    expect(missing.notice, contains('图片文件已找不到'));
  });
}
