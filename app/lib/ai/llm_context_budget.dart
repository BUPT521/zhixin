import 'dart:convert';
import 'dart:math' as math;

import 'llm_client.dart';
import 'llm_config.dart';

/// 兼容接口没有共用 tokenizer，按实际进入请求的内容估算输入。
class LlmContextBudget {
  const LlmContextBudget(this.config);

  final LlmConfig config;

  // 给不同接口的消息包装和估算误差留余量。
  int get inputLimit =>
      config.contextWindowTokens - config.outputTokenLimit - 256;

  // 留出一次助手消息与工具结果的空间，接近上限时直接请求正文。
  int get toolHeadroom => math.min(config.outputTokenLimit, 2048);

  int fixedTokens(String system, List<LlmTool> tools) =>
      32 +
      estimateLlmTextTokens(system) +
      estimateLlmTextTokens(
        jsonEncode(tools.map((tool) => tool.toJson()).toList()),
      );

  int messageTokens(LlmMessage message) =>
      16 +
      estimateLlmTextTokens(message.content) +
      (message.images.length * 2048) +
      estimateLlmTextTokens(message.toolCallId ?? '') +
      message.toolCalls.fold<int>(
        0,
        (total, call) =>
            total +
            20 +
            estimateLlmTextTokens(call.id) +
            estimateLlmTextTokens(call.name) +
            estimateLlmTextTokens(call.arguments),
      ) +
      (message.reasoningItems.isEmpty
          ? 0
          : estimateLlmTextTokens(jsonEncode(message.reasoningItems)));
}

int estimateLlmTextTokens(String text) {
  var ascii = 0;
  var tokens = 0;
  for (final rune in text.runes) {
    if (rune < 128) {
      ascii++;
    } else {
      tokens += rune > 0xffff ? 2 : 1;
    }
  }
  return tokens + (ascii + 2) ~/ 3;
}
