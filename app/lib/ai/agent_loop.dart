import '../domain/rules/content_identity.dart';
import 'agent_tools.dart';
import 'llm_client.dart';
import 'llm_context_budget.dart';
import 'llm_reply_reader.dart';

class AgentTurn {
  const AgentTurn.completed(this.text) : truncated = false, interruption = null;
  const AgentTurn.truncated(this.text) : truncated = true, interruption = null;
  const AgentTurn.interrupted(this.text, LlmException error)
    : truncated = false,
      interruption = error;

  final String text;
  final bool truncated;
  final LlmException? interruption;
}

/// 驱动一轮回答，每次请求只使用已完成的模型步骤。
class AgentLoop {
  const AgentLoop(this.client);

  static const _maxStalledSteps = 2;
  static const _contextLimit = LlmException(
    LlmFailure.contextLimit,
    '本轮内容超过模型上下文预算',
  );

  final LlmClient client;

  Future<AgentTurn> run({
    required String system,
    required List<LlmMessage> messages,
    required AgentToolSet tools,
    required LlmRequestBudget budget,
    required LlmContextBudget contextBudget,
    void Function(String text)? onText,
  }) async {
    final transcript = _AgentTranscript(messages);
    tools.reserveHistory(transcript.messages);
    final text = _TurnText(onText);
    final requiredTool = tools.requiredTool;
    final schemas = tools.schemas;
    final model = LlmReplyReader(
      client: client,
      system: system,
      tools: schemas,
      forceTool: requiredTool,
      budget: budget,
      onTextDelta: onText == null ? null : text.addDelta,
    );
    var stalledSteps = 0;
    var remaining =
        contextBudget.inputLimit - contextBudget.fixedTokens(system, schemas);
    for (final message in transcript.messages) {
      remaining -= contextBudget.messageTokens(message);
    }
    var closingForContext = false;

    try {
      while (true) {
        budget.check();
        if (remaining < 0) throw _contextLimit;
        final stalled = stalledSteps >= _maxStalledSteps;
        if (stalled && requiredTool != null) {
          throw const LlmException(LlmFailure.toolStalled, '强制工具未提交所需内容');
        }
        closingForContext |=
            requiredTool == null && remaining <= contextBudget.toolHeadroom;
        final allowTools = !stalled && !closingForContext;
        final reply = await model.read(
          List<LlmMessage>.unmodifiable(transcript.messages),
          allowToolCalls: allowTools,
        );
        text.commit(reply.text);
        budget.check();
        if (reply.truncated) {
          throw const LlmException(LlmFailure.truncated, '模型未完成回答');
        }

        if (!allowTools || reply.toolCalls.isEmpty) {
          if (requiredTool == null && reply.text.trim().isNotEmpty) {
            return AgentTurn.completed(text.committed);
          }
          if (closingForContext) throw _contextLimit;
          throw allowTools
              ? const LlmException(LlmFailure.badResponse, '模型未返回所需内容')
              : const LlmException(LlmFailure.toolStalled, '模型未根据已有结果完成回答');
        }

        final calls = tools.prepare(reply.toolCalls, budget);
        final canFinishWithText =
            requiredTool == null &&
            reply.text.trim().isNotEmpty &&
            !calls.any((entry) => entry.tool?.continuesAfterText ?? false);
        final assistant = transcript.assistantFor(reply, calls);
        var nextRemaining = remaining - contextBudget.messageTokens(assistant);
        final extra =
            nextRemaining - tools.reservedResultTokens(calls, contextBudget);
        if (extra < 0 && requiredTool == null && !canFinishWithText) {
          // 本步无法带回完整结果时，沿用已提交的上下文完成正文。
          closingForContext = true;
          continue;
        }

        final batch = await tools.execute(
          calls,
          budget,
          extraResultTokens: extra,
        );
        if (canFinishWithText ||
            (requiredTool != null && batch.concludesWith(requiredTool))) {
          return AgentTurn.completed(text.committed);
        }

        final results = [for (final outcome in batch.outcomes) outcome.message];
        for (final result in results) {
          nextRemaining -= contextBudget.messageTokens(result);
        }
        if (nextRemaining < 0) throw _contextLimit;
        transcript.commitStep(assistant, results);
        remaining = nextRemaining;
        stalledSteps = batch.madeProgress ? 0 : stalledSteps + 1;
      }
    } on LlmException catch (error) {
      if (error.failure == LlmFailure.truncated) {
        if (requiredTool == null && text.committed.isNotEmpty) {
          return AgentTurn.truncated(text.committed);
        }
        rethrow;
      }
      if (error.failure == LlmFailure.cancelled || text.hasVisibleText) {
        return AgentTurn.interrupted(text.finishPreview(), error);
      }
      rethrow;
    }
  }
}

/// 续接上下文只追加完成的助手消息及其整批工具结果。
class _AgentTranscript {
  _AgentTranscript(List<LlmMessage> history)
    : messages = uniqueById(
        history,
        (message) => message.id ?? message,
      ).toList() {
    for (final message in messages) {
      _reasoningIds.addAll(message.reasoningItems.map(_reasoningId));
    }
  }

  final List<LlmMessage> messages;
  final _reasoningIds = <String>{};

  LlmMessage assistantFor(LlmReply reply, List<PreparedToolCall> calls) {
    final seen = {..._reasoningIds};
    return LlmMessage(
      role: 'assistant',
      content: reply.text,
      toolCalls: [for (final entry in calls) entry.call],
      reasoningItems: [
        for (final item in reply.reasoningItems)
          if (seen.add(_reasoningId(item))) item,
      ],
    );
  }

  void commitStep(LlmMessage assistant, List<LlmMessage> results) {
    messages.addAll([assistant, ...results]);
    _reasoningIds.addAll(assistant.reasoningItems.map(_reasoningId));
  }

  static String _reasoningId(Map<String, Object?> item) {
    final id = item['id'];
    if (id is String && id.isNotEmpty) return 'response:$id';
    return contentId('reasoning', [item]);
  }
}

/// 面向界面的正文预览，独立于发给模型的上下文。
class _TurnText {
  _TurnText(this.onText);

  final void Function(String text)? onText;
  final _clock = Stopwatch()..start();
  static const _interval = Duration(milliseconds: 40);
  String committed = '';
  final _pending = StringBuffer();
  String _visible = '';
  Duration _lastEmit = Duration.zero;

  bool get hasVisibleText => _visible.isNotEmpty;

  void addDelta(String delta) {
    _pending.write(delta);
    if (!hasVisibleText || _clock.elapsed - _lastEmit >= _interval) {
      _emit(_join(committed, _pending.toString()));
    }
  }

  void commit(String text) {
    committed = _join(committed, text);
    _pending.clear();
    if (hasVisibleText) _emit(committed);
  }

  String finishPreview() {
    if (!hasVisibleText) return '';
    _emit(_join(committed, _pending.toString()));
    return _visible;
  }

  void _emit(String text) {
    if (text.isEmpty || text == _visible) return;
    _visible = text;
    _lastEmit = _clock.elapsed;
    onText?.call(text);
  }

  static String _join(String prefix, String suffix) {
    final body = suffix.trim();
    if (prefix.isEmpty) return body;
    return body.isEmpty ? prefix : '$prefix\n\n$body';
  }
}
