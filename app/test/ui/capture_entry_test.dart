import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/capture_entry.dart';

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
}
