import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';

import 'answer_quality_cases.dart';

/// 第一版回答质量对照评测：检查样例本身完整，并确认构建出的提示词带上
/// 每例需要的上下文与边界。真实模型下的回答按 02 第 8.4 节的四项打分表
/// 另行记录，不在自动化测试里伪造通过。
void main() {
  test('评测集覆盖 V1、V3、V6 与 V11，并保留四项打分', () {
    expect(
      answerQualityCases.map((item) => item.scenario).toSet(),
      containsAll(['V1', 'V3', 'V6', 'V11']),
    );
    expect(answerQualityDimensions, hasLength(4));
    expect(
      answerQualityCases.map((item) => item.id).toSet(),
      hasLength(answerQualityCases.length),
    );
    for (final item in answerQualityCases) {
      expect(item.userText, isNotEmpty, reason: '${item.id} 缺少输入');
      expect(item.expected, isNotEmpty, reason: '${item.id} 缺少通过条件');
    }
  });

  for (final item in answerQualityCases) {
    test('${item.id}：提示词覆盖样例条件', () {
      final prompt = buildBuddySystemPrompt(item.context());
      for (final fragment in item.requiredText) {
        expect(prompt, contains(fragment), reason: '${item.id} 缺少：$fragment');
      }
      for (final fragment in item.forbiddenText) {
        expect(
          prompt,
          isNot(contains(fragment)),
          reason: '${item.id} 不应出现：$fragment',
        );
      }
      var last = -1;
      for (final fragment in item.orderedText) {
        final at = prompt.indexOf(fragment);
        expect(at, greaterThan(last), reason: '${item.id} 的顺序不对：$fragment');
        last = at;
      }
    });
  }

  test('V1 工具参数无效：保留正文，丢弃无效建议', () async {
    final tools = BuddyTurnTools(
      BuddyContext(now: DateTime(2026, 11, 16, 9), mode: BuddyMode.chat),
    );
    final budget = LlmRequestBudget(timeout: const Duration(seconds: 1));
    final prepared = tools.registry.prepare(const [
      LlmToolCall(
        id: 'broken',
        name: proposeNextStepsTool,
        arguments: '{"steps": [{"title":',
      ),
    ], budget);
    await tools.registry.execute(prepared, budget, extraResultTokens: 0);
    final reply = tools.finish('正文保留。');
    expect(reply.text, '正文保留。');
    expect(reply.nextSteps, isEmpty);
  });
}
