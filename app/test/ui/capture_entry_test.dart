import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/ui/capture_entry.dart';
import 'package:zhixin/ui/theme.dart';

void main() {
  test('相机与相册的失败换成照着做的说明', () {
    String text(String code) => captureErrorText(PlatformException(code: code));

    expect(text('camera_access_denied'), contains('相机权限'));
    expect(text('photo_access_denied'), contains('相册权限'));
    expect(text('no_available_camera'), contains('从相册选择'));
    expect(text('already_active'), contains('还没有关闭'));
    expect(text('invalid_image'), contains('换一张'));
  });

  test('认不出的错误只说明可以换一张，不把平台原文放进界面', () {
    final unknown = captureErrorText(
      PlatformException(code: 'unknown', message: '读取失败'),
    );
    expect(unknown, '这张图片没有读取成功，可以换一张再试。');
    expect(unknown, isNot(contains('读取失败')));
    expect(captureErrorText(StateError('文件已损坏')), contains('换一张'));
  });

  testWidgets('缩略图的移除按钮有 44 的可点区域，点一下移除对应那张', (tester) async {
    final handle = tester.ensureSemantics();
    final dir = Directory.systemTemp.createTempSync('capture-strip-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'shot.jpg'))
      ..writeAsBytesSync(
        Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
      );
    final removed = <int>[];

    await tester.pumpWidget(
      forui.FTheme(
        data: zhixinForuiTheme,
        child: MaterialApp(
          theme: zhixinTheme,
          home: Scaffold(
            body: Center(
              child: CapturePhotoStrip(
                photos: [XFile(file.path)],
                onRemove: removed.add,
              ),
            ),
          ),
        ),
      ),
    );

    final target = find.bySemanticsLabel('移除图片');
    expect(target, findsOneWidget);
    expect(tester.getSize(target), const Size(44, 44));
    await tester.tap(target);
    expect(removed, [0]);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
