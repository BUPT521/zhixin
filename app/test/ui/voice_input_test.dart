import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ui/voice_input_button.dart';

void main() {
  test('语音识别失败按错误码给出能照着做的下一步', () {
    expect(voiceErrorText('error_permission'), contains('麦克风权限'));
    expect(voiceErrorText('error_client'), contains('语音识别服务'));
    expect(voiceErrorText('error_network'), contains('联网'));
  });

  test('认不出的错误只说可以改用键盘，不把平台原文放进界面', () {
    final unknown = voiceErrorText('error_unknown');
    expect(unknown, '语音识别没有完成，可以改用键盘输入。');
    expect(unknown, isNot(contains('error_')));
  });
}
