import 'llm_client.dart';

/// 将一次完整的模型响应交给循环，正文增量可以提前用于展示。
class LlmReplyReader {
  LlmReplyReader({
    required this.client,
    required this.system,
    required this.tools,
    required this.budget,
    this.forceTool,
    this.onTextDelta,
  }) : _streaming = onTextDelta != null;

  final LlmClient client;
  final String system;
  final List<LlmTool> tools;
  final LlmRequestBudget budget;
  final String? forceTool;
  final void Function(String delta)? onTextDelta;
  bool _streaming;

  Future<LlmReply> read(
    List<LlmMessage> messages, {
    required bool allowToolCalls,
  }) async {
    if (_streaming) {
      final draft = _ReplyDraft();
      try {
        await for (final delta in client.stream(
          system: system,
          messages: messages,
          tools: tools,
          forceTool: forceTool,
          allowToolCalls: allowToolCalls,
          budget: budget,
        )) {
          budget.check();
          draft.add(delta);
          if (delta.text.isNotEmpty) onTextDelta!(delta.text);
        }
        return draft.finish();
      } on LlmException catch (error) {
        if (error.failure != LlmFailure.badResponse || draft.hasOutput) rethrow;
        // 同一个模型步骤沿用原请求，后续步骤也使用兼容的普通请求。
        _streaming = false;
      }
    }
    return client.complete(
      system: system,
      messages: messages,
      tools: tools,
      forceTool: forceTool,
      allowToolCalls: allowToolCalls,
      budget: budget,
    );
  }
}

class _ReplyDraft {
  final _text = StringBuffer();
  final _calls = <int, _CallDraft>{};
  final _reasoningItems = <Map<String, Object?>>[];
  var _truncated = false;
  var hasOutput = false;

  void add(LlmDelta delta) {
    _text.write(delta.text);
    _truncated |= delta.truncated;
    hasOutput |= delta.hasOutput || delta.truncated;
    _reasoningItems.addAll(delta.reasoningItems);
    for (final call in delta.toolCalls) {
      _calls.putIfAbsent(call.index, _CallDraft.new).add(call);
    }
  }

  LlmReply finish() {
    final indexes = _calls.keys.toList()..sort();
    return LlmReply(
      text: _text.toString().trim(),
      toolCalls: [
        if (!_truncated)
          for (final index in indexes)
            if (_calls[index]!.name.isNotEmpty) _calls[index]!.finish(),
      ],
      truncated: _truncated,
      reasoningItems: _reasoningItems,
    );
  }
}

class _CallDraft {
  String id = '';
  String name = '';
  final arguments = StringBuffer();

  void add(LlmToolCallDelta delta) {
    if (delta.id case final value? when value.isNotEmpty) id = value;
    if (delta.name case final value? when value.isNotEmpty) name = value;
    if (delta.replaceArguments) arguments.clear();
    arguments.write(delta.arguments);
  }

  LlmToolCall finish() =>
      LlmToolCall(id: id, name: name, arguments: arguments.toString());
}
