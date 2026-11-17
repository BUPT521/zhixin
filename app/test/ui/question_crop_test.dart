import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:zhixin/ui/question_crop_page.dart';
import 'package:zhixin/ui/theme.dart';

void main() {
  test('按归一化坐标裁出区域，长边超过上限时等比缩小', () {
    final source = img.Image(width: 120, height: 80);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final leftHalf = x < source.width ~/ 2;
        source.setPixelRgb(x, y, leftHalf ? 220 : 30, 30, leftHalf ? 30 : 220);
      }
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(source, quality: 100));

    final left = img.decodeJpg(
      cropToJpeg(jpeg, const Rect.fromLTRB(0, 0, 0.5, 1)),
    )!;
    expect(left.width, 60);
    expect(left.height, 80);
    final pixel = left.getPixel(30, 40);
    expect(pixel.r, greaterThan(pixel.b));
    expect(pixel.r, greaterThan(150));

    final right = img.decodeJpg(
      cropToJpeg(jpeg, const Rect.fromLTRB(0.5, 0, 1, 1)),
    )!;
    final rightPixel = right.getPixel(30, 40);
    expect(rightPixel.b, greaterThan(rightPixel.r));

    final small = img.decodeJpg(
      cropToJpeg(jpeg, const Rect.fromLTRB(0, 0, 1, 1), maxSide: 48),
    )!;
    expect(math.max(small.width, small.height), 48);
    expect(small.width, greaterThan(small.height));
  });

  test('越界的选框夹回图片范围内', () {
    final source = img.Image(width: 40, height: 30);
    final jpeg = Uint8List.fromList(img.encodeJpg(source));

    final cropped = img.decodeJpg(
      cropToJpeg(jpeg, const Rect.fromLTRB(-1, -1, 2, 2)),
    )!;
    expect(cropped.width, 40);
    expect(cropped.height, 30);
  });

  test('相机原图压到取图上限，没超过时保持原尺寸', () async {
    final source = img.Image(width: 1200, height: 800);
    final jpeg = Uint8List.fromList(img.encodeJpg(source, quality: 100));

    final shrunk = img.decodeJpg(await shrinkCaptureImage(jpeg, maxSide: 600))!;
    expect(shrunk.width, 600);
    expect(shrunk.height, 400);

    final kept = img.decodeJpg(await shrinkCaptureImage(jpeg, maxSide: 1600))!;
    expect(kept.width, 1200);
    expect(kept.height, 800);
  });

  testWidgets('从相机进来时底栏给出重拍与使用这张图，放弃只留标题栏的 X', (tester) async {
    await _pumpCrop(tester, allowRetake: true);

    expect(find.byKey(const ValueKey('question-crop-footer')), findsOneWidget);
    expect(find.widgetWithText(forui.FButton, '重拍'), findsOneWidget);
    expect(find.widgetWithText(forui.FButton, '使用这张图'), findsOneWidget);
    // 放弃只留在标题栏的 X 上，底栏不再有一个“取消”。
    expect(find.widgetWithText(forui.FButton, '取消'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从相册进来时没有重拍，底栏只确认这张图', (tester) async {
    await _pumpCrop(tester, allowRetake: false);

    expect(find.widgetWithText(forui.FButton, '重拍'), findsNothing);
    expect(find.widgetWithText(forui.FButton, '使用这张图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 起一个框选页：原图用临时目录里真实的小图，读完再断言，测试结束时文件已经
/// 释放，删除临时目录不会因为读取还没结束而失败。
Future<void> _pumpCrop(WidgetTester tester, {required bool allowRetake}) async {
  final dir = Directory.systemTemp.createTempSync('crop-footer-test');
  addTearDown(() async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 上删不掉时把临时目录交给系统清理，不影响用例结果。
    }
  });
  final file = File(p.join(dir.path, 'shot.jpg'))
    ..writeAsBytesSync(
      Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
    );
  await tester.runAsync(() async {
    await tester.pumpWidget(
      _host(
        QuestionCropPage(
          sourcePath: file.path,
          outputDir: dir.path,
          allowRetake: allowRetake,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

Widget _host(Widget child) => forui.FTheme(
  data: zhixinForuiTheme,
  child: MaterialApp(
    theme: zhixinTheme,
    localizationsDelegates: const [
      ...GlobalMaterialLocalizations.delegates,
      forui.FLocalizations.delegate,
    ],
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    home: child,
  ),
);
