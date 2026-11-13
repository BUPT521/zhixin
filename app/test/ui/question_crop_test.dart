import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/question_crop_page.dart';

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
}
