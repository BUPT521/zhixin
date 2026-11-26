import 'dart:convert';
import 'dart:math' as math;

import 'llm_config.dart';
import 'llm_protocol.dart';

/// 兼容接口没有共用 tokenizer，按实际进入请求的内容估算输入。
///
/// 条目计数与服务端 `estimateChatInput` 一致：请求体固定 32，每条输入条目带 16 的
/// 包装，带工具调用的助手消息在线格式里额外展开成若干 `function_call` 条目（各带
/// 16 的包装与 20 的调用开销），工具结果按实际发送的 JSON 文本估算。`tools` 为空时
/// 请求里不出现这个字段，这里也不计。
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
      (tools.isEmpty
          ? 0
          : estimateLlmTextTokens(
              jsonEncode(tools.map((tool) => tool.toJson()).toList()),
            ));

  int messageTokens(LlmMessage message) =>
      16 +
      (message.toolCallId == null
          ? estimateLlmTextTokens(message.content)
          : estimateLlmTextTokens(toolResultWireText(message))) +
      (message.images.length * 2048) +
      estimateLlmTextTokens(message.toolCallId ?? '') +
      message.toolCalls.fold<int>(
        0,
        (total, call) =>
            total +
            16 +
            20 +
            estimateLlmTextTokens(call.id) +
            estimateLlmTextTokens(call.name) +
            estimateLlmTextTokens(call.arguments),
      );
}

/// 与服务端 `server/internal/llmproxy/estimate.go` 的 `estimateLlmTextTokens`
/// 同一口径：非 ASCII 字符每个记 1，辅助平面记 2，ASCII 每三个字符记 1；图片在
/// [LlmContextBudget.messageTokens] 里每张按 2048 计。改这里时要同时改服务端的
/// 估算函数，否则两端对同一请求的判断会不一致。
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
