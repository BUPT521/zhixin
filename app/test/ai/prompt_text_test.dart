import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/prompt_text.dart';

void main() {
  test('提示词资源覆盖系统提示、模式与请求文本', () {
    final text = PromptText.instance;
    for (final key in [
      'system.intro',
      'system.rule.grounded',
      'system.rule.study_steps',
      'system.memories',
      'mode.chat',
      'mode.plan',
      'request.hint',
      'request.study_steps',
      'request.previous_line',
      'tool.propose_memories',
      'tool.read_material_page',
      'tool.submit_probe',
    ]) {
      expect(text[key], isNotEmpty, reason: '缺少段落：$key');
    }
  });

  test('占位符替换不把替换值里的花括号当成占位符', () {
    final text = PromptText.instance;
    expect(
      text.format('system.time', {'time': '2026-11-16 {{clock}}'}),
      '当前时间：2026-11-16 {{clock}}',
    );
  });

  test('单遍替换：替换值里出现的另一个占位符不会被再展开一次', () {
    final text = PromptText.instance;
    // 用户写下的目标名里带着 {{due}}，它不能被当成归属段落的截止日期占位符。
    expect(
      text.format('system.goal', {'title': '复习 {{due}} 的定义', 'due': ''}),
      '本次讨论归属：复习 {{due}} 的定义',
    );
  });

  test('缺少替换值时拒绝生成半截提示词', () {
    expect(
      () => PromptText.instance.format('system.time', const {}),
      throwsStateError,
    );
  });
}
