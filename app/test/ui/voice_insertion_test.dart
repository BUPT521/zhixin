import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/voice_input_button.dart';

void main() {
  TextEditingController input(String text, {int? cursor}) {
    final controller = TextEditingController(text: text);
    controller.selection = TextSelection.collapsed(
      offset: cursor ?? text.length,
    );
    return controller;
  }

  test('识别结果写在光标处，后面的文字不丢', () {
    final field = input('开头结尾', cursor: 2);
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('中间');

    expect(field.text, '开头中间结尾');
    expect(field.selection.baseOffset, 4);
  });

  test('先写好的文字不会被识别结果整段替换', () {
    final field = input('这道题不会：');
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('求函数的单调区间');

    expect(field.text, '这道题不会：求函数的单调区间');
  });

  test('同一句的中间结果原位替换，不会重复追加', () {
    final field = input('先写的');
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('今天');
    insertion.write('今天做');
    insertion.write('今天做完');

    expect(field.text, '先写的今天做完');
  });

  test('一句结束之后，下一句接在后面而不是替换这一句', () {
    final field = input('');
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('第一句');
    insertion.commit();
    insertion.write('第二句');

    expect(field.text, '第一句第二句');
  });

  test('识别期间用户改过这一段时，从当前光标续写，不删手写内容', () {
    final field = input('原稿');
    final insertion = VoiceInsertion(field)..begin();
    insertion.write('识别一');

    field.value = const TextEditingValue(
      text: '原稿改过',
      selection: TextSelection.collapsed(offset: 4),
    );
    insertion.write('识别二');

    expect(field.text, '原稿改过识别二');
  });

  test('开始识别前选中的文字会被这次识别结果替换', () {
    final field = TextEditingController(text: '旧的草稿');
    field.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('新的草稿');

    expect(field.text, '新的草稿');
    expect(field.selection.baseOffset, 4);
  });

  test('识别服务返回空内容时不改动输入框', () {
    final field = input('不要动的文字');
    final insertion = VoiceInsertion(field)..begin();

    insertion.write('   ');
    insertion.write('');

    expect(field.text, '不要动的文字');
  });
}
