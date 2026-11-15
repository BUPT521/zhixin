import 'dart:convert';
import 'dart:typed_data';

import '../domain/rules/content_identity.dart';
import '../domain/rules/text.dart';
import 'llm_config.dart';
import 'llm_failure.dart';

/// 一张随消息上传的图片；默认按 JPEG 处理，原图已经压缩到长边 1600。
class LlmImage {
  LlmImage({required Uint8List bytes, this.mimeType = 'image/jpeg'})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  final String mimeType;

  /// 与本机附件对象共用按原始字节计算的标识。
  late final String id = contentHash(bytes);
  late final String _base64 = base64Encode(bytes);
}

class LlmMessage {
  const LlmMessage({
    this.id,
    required this.role,
    required this.content,
    this.images = const [],
    this.toolCalls = const [],
    this.reasoningItems = const [],
  }) : toolCallId = null,
       toolIsError = false;

  const LlmMessage.toolResult({
    required String callId,
    required this.content,
    this.toolIsError = false,
  }) : role = 'tool',
       id = 'tool-result:$callId',
       toolCallId = callId,
       images = const [],
       toolCalls = const [],
       reasoningItems = const [];

  /// 本轮内的消息标识，用于合并历史。线协议按各接口的格式组装。
  final String? id;

  /// `user`、`assistant` 或 `tool`；system 单独传。
  final String role;
  final String content;

  /// 非空时 content 按数组发送，文字在前、图片在后。
  final List<LlmImage> images;
  final List<LlmToolCall> toolCalls;
  final List<Map<String, Object?>> reasoningItems;
  final String? toolCallId;
  final bool toolIsError;
}

/// 一个可调用的工具；参数是一个 JSON Schema 对象。
class LlmTool {
  const LlmTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

// ---------------------------------------------------------------------------
// 公共小工具
// ---------------------------------------------------------------------------
/// 服务端在响应体或流式片段里带的错误说明；没有说明时给一句通用的话。
String errorTextOf(Object? error) {
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.trim().isNotEmpty) {
      return _clip(message.trim());
    }
  }
  if (error is String && error.trim().isNotEmpty) {
    return _clip(error.trim());
  }
  return '模型服务出错';
}

String? errorMessageOf(String body) {
  final text = body.trim();
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, Object?>) {
      final error = decoded['error'];
      if (error is Map) return errorTextOf(error);
      if (error is String) return errorTextOf(error);
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) {
        return _clip(message.trim());
      }
    }
  } on FormatException {
    // 不是 JSON：当纯文本说明读。
  }
  // HTML 错误页不整页塞进提示。
  if (text.startsWith('<')) return null;
  return _clip(text);
}

String _clip(String text) => truncateCodePoints(text, 200);

/// 正文可能是字符串，也可能是内容块数组：多模态的兼容实现会按 OpenAI 的
/// 新格式发 `[{"type":"text","text":"…"}]`。
String _textOf(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is Map && part['text'] is String) {
      buffer.write(part['text'] as String);
    }
  }
  return buffer.toString();
}

String _dataUrl(LlmImage image) =>
    'data:${image.mimeType};base64,${image._base64}';
// ---------------------------------------------------------------------------
// 三种线格式
// ---------------------------------------------------------------------------

LlmWire llmWireFor(LlmApi api) => switch (api) {
  LlmApi.chat => const _ChatWire(),
  LlmApi.responses => const _ResponsesWire(),
  LlmApi.anthropic => const _AnthropicWire(),
};

abstract class LlmWire {
  const LlmWire();

  Map<String, String> headers(LlmConfig config, {required bool stream});

  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  });

  LlmDecoder decoder();
}

/// OpenAI 兼容的 `/chat/completions`，DeepSeek 与多数中转站都属于这一类。
final class _ChatWire extends LlmWire {
  const _ChatWire();

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'Authorization': 'Bearer ${config.apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  /// DeepSeek 的思考模式默认打开，推理内容同样计入输出上限，还会让指定工具的
  /// `tool_choice` 直接返回 400；知新的回答只要三到五句，所以按服务商关掉。
  /// 输出上限在 OpenAI 官方换成了 `max_completion_tokens`，其余兼容实现仍用
  /// `max_tokens`。
  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': system},
        for (final message in messages) _message(message),
      ],
      'temperature': 0.5,
      if (config.isDeepSeek) 'thinking': const {'type': 'disabled'},
      if (stream) 'stream': true,
      if (stream) 'stream_options': const {'include_usage': true},
      if (config.isOpenAi)
        'max_completion_tokens': config.outputTokenLimit
      else
        'max_tokens': config.outputTokenLimit,
      if (tools.isNotEmpty) 'tools': [for (final tool in tools) tool.toJson()],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? 'none'
            : forceTool == null
            ? 'auto'
            : {
                'type': 'function',
                'function': {'name': forceTool},
              },
    };
  }

  Map<String, Object?> _message(LlmMessage message) {
    if (message.toolCallId case final id?) {
      return {'role': 'tool', 'tool_call_id': id, 'content': message.content};
    }
    if (message.toolCalls.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': message.content.isEmpty ? null : message.content,
        'tool_calls': [
          for (final call in message.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {'name': call.name, 'arguments': call.arguments},
            },
        ],
      };
    }
    if (message.images.isEmpty) {
      return {'role': message.role, 'content': message.content};
    }
    return {
      'role': message.role,
      'content': [
        {'type': 'text', 'text': message.content},
        for (final image in message.images)
          {
            'type': 'image_url',
            'image_url': {'url': _dataUrl(image)},
          },
      ],
    };
  }

  @override
  LlmDecoder decoder() => _ChatDecoder();
}

/// OpenAI 与 DeepSeek 的 `/responses`：system 放 `instructions`，输入是条目数组。
final class _ResponsesWire extends LlmWire {
  const _ResponsesWire();

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'Authorization': 'Bearer ${config.apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'instructions': system,
      'input': [for (final message in messages) ..._input(message)],
      if (config.isDeepSeek) 'reasoning': const {'effort': 'none'},
      if (config.isOpenAi) ...{
        'store': false,
        'include': const ['reasoning.encrypted_content'],
      },
      'stream': stream,
      'max_output_tokens': config.outputTokenLimit,
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
              'strict': false,
            },
        ],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? 'none'
            : forceTool == null
            ? 'auto'
            : {'type': 'function', 'name': forceTool},
    };
  }

  /// 用户消息用 `input_text`／`input_image`，助手历史用 `output_text`。
  List<Object?> _input(LlmMessage message) {
    if (message.toolCallId case final id?) {
      return [
        {
          'type': 'function_call_output',
          'call_id': id,
          'output': message.content,
        },
      ];
    }
    final assistant = message.role == 'assistant';
    final parts = <Object?>[
      {
        'type': assistant ? 'output_text' : 'input_text',
        'text': message.content,
      },
      if (!assistant)
        for (final image in message.images)
          {'type': 'input_image', 'image_url': _dataUrl(image)},
    ];
    return [
      ...message.reasoningItems,
      if (message.content.isNotEmpty || message.toolCalls.isEmpty)
        {'role': message.role, 'content': parts},
      for (final call in message.toolCalls)
        {
          'type': 'function_call',
          'call_id': call.id,
          'name': call.name,
          'arguments': call.arguments,
        },
    ];
  }

  @override
  LlmDecoder decoder() => _ResponsesDecoder();
}

/// Anthropic Messages：system 是顶层字段，鉴权用 `x-api-key`。
final class _AnthropicWire extends LlmWire {
  const _AnthropicWire();

  static const String _version = '2023-06-01';

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'x-api-key': config.apiKey.trim(),
    'anthropic-version': _version,
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  @override
  Map<String, Object?> body({
    required LlmConfig config,
    required String system,
    required List<LlmMessage> messages,
    required List<LlmTool> tools,
    required String? forceTool,
    required bool allowToolCalls,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'max_tokens': config.outputTokenLimit,
      'system': system,
      'messages': _messages(messages),
      'stream': stream,
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
        ],
      if (tools.isNotEmpty)
        'tool_choice': !allowToolCalls
            ? const {'type': 'none'}
            : forceTool == null
            ? const {'type': 'auto'}
            : {'type': 'tool', 'name': forceTool},
    };
  }

  List<Object?> _messages(List<LlmMessage> messages) {
    final result = <Object?>[];
    List<Object?>? toolResults;
    for (final message in messages) {
      if (message.toolCallId case final id?) {
        if (toolResults == null) {
          toolResults = [];
          result.add({'role': 'user', 'content': toolResults});
        }
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': id,
          'content': message.content,
          if (message.toolIsError) 'is_error': true,
        });
      } else {
        toolResults = null;
        result.add(_message(message));
      }
    }
    return result;
  }

  Map<String, Object?> _message(LlmMessage message) {
    final parts = <Object?>[
      if (message.content.trim().isNotEmpty)
        {'type': 'text', 'text': message.content},
      if (message.role != 'assistant')
        for (final image in message.images)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': image.mimeType,
              'data': image._base64,
            },
          },
      for (final call in message.toolCalls)
        {
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': call.argumentsObject ?? const <String, Object?>{},
        },
    ];
    // Anthropic 不接受空 content；图片被关掉时仍要保留这一轮的占位文字。
    if (parts.isEmpty) {
      parts.add({'type': 'text', 'text': '[发了一张图片]'});
    }
    return {'role': message.role, 'content': parts};
  }

  @override
  LlmDecoder decoder() => _AnthropicDecoder();
}
// ---------------------------------------------------------------------------
// 流式解码
// ---------------------------------------------------------------------------

/// 一次流式回答的解码状态；不同协议的结束标记与事件形状在这里各自处理。
abstract class LlmDecoder {
  bool done = false;
  bool truncated = false;
  bool sawText = false;
  bool sawOutput = false;

  /// 一个 SSE 事件转成增量；服务端报错时抛出 [LlmException]。
  List<LlmDelta> accept(String? event, String data);

  /// 流结束时检查：没有正文按格式错误抛出。
  void verify() {
    if (!sawOutput) {
      throw const LlmException(LlmFailure.badResponse, '流式响应没有内容');
    }
  }

  LlmReply decodeBody(String body);
}

/// Chat Completions：一条 `data:` 放一个 chunk，`[DONE]` 收尾。
final class _ChatDecoder extends LlmDecoder {
  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty) return const [];
    if (payload == '[DONE]') {
      done = true;
      return const [];
    }
    final chunk = _decodeChunk(payload);
    final deltas = <LlmDelta>[];
    if (chunk.reasoningProgress) {
      deltas.add(const LlmDelta(reasoningProgress: true));
    }
    if (chunk.text.isNotEmpty) {
      sawText = true;
      sawOutput = true;
      deltas.add(LlmDelta(text: chunk.text));
    }
    if (chunk.calls.isNotEmpty) {
      sawOutput = true;
      deltas.add(LlmDelta(toolCalls: chunk.calls));
    }
    final finish = chunk.finish;
    if (finish != null) {
      done = true;
      if (_incomplete(finish)) truncated = true;
      if (finish == 'content_filter') {
        throw const LlmException(LlmFailure.server, '回答被内容过滤');
      }
    }
    return deltas;
  }

  _Chunk _decodeChunk(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error) {
      throw LlmException(
        LlmFailure.badResponse,
        '流式片段不是 JSON：${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const LlmException(LlmFailure.badResponse, '流式片段不是 JSON object');
    }
    final error = decoded['error'];
    if (error != null) {
      throw LlmException(LlmFailure.server, errorTextOf(error));
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      // 只带用量的片段，没有正文可读。
      return const _Chunk();
    }
    final first = choices.first;
    if (first is! Map<String, Object?>) return const _Chunk();
    final body = first['delta'] is Map<String, Object?>
        ? first['delta'] as Map<String, Object?>
        : first['message'] is Map<String, Object?>
        ? first['message'] as Map<String, Object?>
        : const <String, Object?>{};
    final finish = first['finish_reason'];
    final reasoning = body['reasoning_content'];
    return _Chunk(
      text: _textOf(body['content']),
      calls: _toolCallDeltas(body['tool_calls']),
      finish: finish is String && finish.isNotEmpty ? finish : null,
      reasoningProgress: reasoning is String && reasoning.isNotEmpty,
    );
  }

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw LlmException(LlmFailure.server, errorTextOf(error));
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('没有 choices');
      }
      final first = choices.first;
      final message = first is Map<String, Object?> ? first['message'] : null;
      final content = message is Map<String, Object?>
          ? message['content']
          : null;
      final finish =
          first is Map<String, Object?> && first['finish_reason'] is String
          ? first['finish_reason'] as String
          : null;
      final text = _textOf(content).trim();
      if (finish == 'content_filter') {
        throw const LlmException(LlmFailure.server, '回答被内容过滤');
      }
      final truncated = finish != null && _incomplete(finish);
      if (truncated && text.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      final calls = message is Map<String, Object?>
          ? _toolCalls(message['tool_calls'])
          : const <LlmToolCall>[];
      if (text.isEmpty && calls.isEmpty) {
        throw const FormatException('message.content 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: text,
        toolCalls: truncated ? const [] : calls,
        tokensIn:
            _intOf(usage, 'prompt_tokens') ??
            _intOf(usage, 'input_tokens') ??
            0,
        tokensOut:
            _intOf(usage, 'completion_tokens') ??
            _intOf(usage, 'output_tokens') ??
            0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}

/// Responses：语义事件，正文在 `response.output_text.delta`，结束时带完整 output。
final class _ResponsesDecoder extends LlmDecoder {
  /// 某个工具调用是否已经收到过参数增量；没有收到时用收尾事件里的完整参数。
  final Map<int, String> _finalArguments = {};
  final Map<String, int> _indexByItem = {};
  var _nextToolIndex = 0;
  var _lastToolIndex = 0;
  final StringBuffer _textSent = StringBuffer();

  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty || payload == '[DONE]') return const [];
    final decoded = _decodeObject(payload);
    final type = decoded['type'] is String
        ? decoded['type'] as String
        : (event ?? '');
    final deltas = <LlmDelta>[];
    switch (type) {
      case 'response.output_text.delta':
        final text = decoded['delta'];
        if (text is String && text.isNotEmpty) {
          _textSent.write(text);
          sawText = true;
          sawOutput = true;
          deltas.add(LlmDelta(text: text));
        }
      case 'response.reasoning_text.delta' ||
          'response.reasoning_summary_text.delta':
        final fragment = decoded['delta'];
        if (fragment is String && fragment.isNotEmpty) {
          deltas.add(const LlmDelta(reasoningProgress: true));
        }
      case 'response.function_call_arguments.delta':
        final args = decoded['delta'];
        if (args is String && args.isNotEmpty) {
          final index = _indexFor(_itemId(decoded));
          _lastToolIndex = index;
          if (!_finalArguments.containsKey(index)) {
            deltas.add(
              LlmDelta(
                toolCalls: [LlmToolCallDelta(index: index, arguments: args)],
              ),
            );
          }
        }
      case 'response.function_call_arguments.done':
        _finishArguments(
          deltas,
          _indexFor(_itemId(decoded)),
          decoded['arguments'],
        );
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = decoded['item'];
        if (item is Map<String, Object?> && item['type'] == 'reasoning') {
          final encrypted = item['encrypted_content'];
          deltas.add(
            type == 'response.output_item.done' &&
                    encrypted is String &&
                    encrypted.isNotEmpty
                ? LlmDelta(reasoningItems: [item])
                : const LlmDelta(reasoningProgress: true),
          );
        }
        if (item is Map<String, Object?> && item['type'] == 'function_call') {
          final index = _indexFor(_itemId(item));
          _lastToolIndex = index;
          final id = item['call_id'] is String
              ? item['call_id'] as String
              : null;
          final name = item['name'] is String ? item['name'] as String : null;
          if (name != null || id != null) {
            sawOutput = true;
            deltas.add(
              LlmDelta(
                toolCalls: [LlmToolCallDelta(index: index, id: id, name: name)],
              ),
            );
          }
          if (type == 'response.output_item.done') {
            _finishArguments(deltas, index, item['arguments']);
          }
        }
      case 'response.completed' || 'response.incomplete':
        final response = decoded['response'];
        if (response is Map<String, Object?>) {
          final status = response['status'];
          final incomplete =
              type == 'response.incomplete' || status == 'incomplete';
          if (incomplete) truncated = true;
          deltas.addAll(_reconcile(response));
        }
        done = true;
      case 'response.failed':
        final response = decoded['response'];
        final error = response is Map<String, Object?>
            ? response['error']
            : null;
        throw LlmException(LlmFailure.server, errorTextOf(error ?? '回答生成失败'));
      case 'error':
        throw LlmException(
          LlmFailure.server,
          errorTextOf(decoded['error'] ?? decoded),
        );
      default:
        // reasoning、web search 等事件不影响正文。
        break;
    }
    return deltas;
  }

  /// 有的网关在工具调用前后不发正文增量，只在收尾事件里给出完整 output：
  /// 正文只补还没发过的后缀，完整工具参数覆盖已有分片。
  List<LlmDelta> _reconcile(Map<String, Object?> response) {
    final output = response['output'];
    if (output is! List) return const [];
    final deltas = <LlmDelta>[];
    final reasoningItems = _reasoningItems(output);
    if (reasoningItems.isNotEmpty) {
      deltas.add(LlmDelta(reasoningItems: reasoningItems));
    }
    final fullText = StringBuffer();
    for (final item in output) {
      if (item is Map<String, Object?> && item['type'] == 'message') {
        fullText.write(_textOf(item['content']));
      }
    }
    final complete = fullText.toString();
    final sent = _textSent.toString();
    if (complete.length > sent.length && complete.startsWith(sent)) {
      final suffix = complete.substring(sent.length);
      _textSent.write(suffix);
      sawText = true;
      sawOutput = true;
      deltas.add(LlmDelta(text: suffix));
    }
    for (final item in output) {
      if (item is! Map<String, Object?>) continue;
      final type = item['type'];
      if (type == 'function_call') {
        final itemId = _itemId(item);
        final index = _indexFor(itemId);
        final id = item['call_id'] is String ? item['call_id'] as String : null;
        final name = item['name'] is String ? item['name'] as String : null;
        if (name != null || id != null) {
          sawOutput = true;
          deltas.add(
            LlmDelta(
              toolCalls: [LlmToolCallDelta(index: index, id: id, name: name)],
            ),
          );
        }
        _finishArguments(deltas, index, item['arguments']);
      }
    }
    return deltas;
  }

  void _finishArguments(List<LlmDelta> deltas, int index, Object? value) {
    if (value is! String || value.isEmpty || _finalArguments[index] == value) {
      return;
    }
    _finalArguments[index] = value;
    sawOutput = true;
    deltas.add(
      LlmDelta(
        toolCalls: [
          LlmToolCallDelta(
            index: index,
            arguments: value,
            replaceArguments: true,
          ),
        ],
      ),
    );
  }

  String? _itemId(Map<String, Object?> value) {
    final itemId = value['item_id'];
    if (itemId is String && itemId.isNotEmpty) return itemId;
    final id = value['id'];
    if (id is String && id.isNotEmpty) return id;
    final outputIndex = value['output_index'];
    if (outputIndex is int) return 'output:$outputIndex';
    return null;
  }

  int _indexFor(String? itemId) {
    if (itemId == null) return _lastToolIndex;
    final existing = _indexByItem[itemId];
    if (existing != null) return existing;
    final index = _nextToolIndex++;
    _indexByItem[itemId] = index;
    return index;
  }

  List<Map<String, Object?>> _reasoningItems(List<Object?> output) => [
    for (final item in output)
      if (item is Map<String, Object?> && item['type'] == 'reasoning') item,
  ];

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw LlmException(LlmFailure.server, errorTextOf(error));
      }
      final output = decoded['output'];
      if (output is! List) throw const FormatException('没有 output');
      final text = StringBuffer();
      final calls = <LlmToolCall>[];
      for (final item in output) {
        if (item is! Map<String, Object?>) continue;
        if (item['type'] == 'message') {
          text.write(_textOf(item['content']));
        } else if (item['type'] == 'function_call') {
          final name = item['name'];
          final args = item['arguments'];
          if (name is! String || name.trim().isEmpty) continue;
          calls.add(
            LlmToolCall(
              id: item['call_id'] is String ? item['call_id'] as String : '',
              name: name.trim(),
              arguments: args is String
                  ? args
                  : args == null
                  ? ''
                  : jsonEncode(args),
            ),
          );
        }
      }
      final status = decoded['status'];
      final reason = decoded['incomplete_details'] is Map<String, Object?>
          ? (decoded['incomplete_details'] as Map<String, Object?>)['reason']
          : null;
      final truncated = status == 'incomplete' || reason != null;
      final bodyText = text.toString().trim();
      if (truncated && bodyText.isEmpty && calls.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      if (bodyText.isEmpty && calls.isEmpty) {
        throw const FormatException('output 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: bodyText,
        toolCalls: truncated ? const [] : calls,
        reasoningItems: truncated ? const [] : _reasoningItems(output),
        tokensIn: _intOf(usage, 'input_tokens') ?? 0,
        tokensOut: _intOf(usage, 'output_tokens') ?? 0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}

/// Anthropic Messages：`content_block_*` 增量与 `message_delta.stop_reason`。
final class _AnthropicDecoder extends LlmDecoder {
  final Map<int, int> _toolIndexByBlock = {};
  final Map<int, bool> _argsSeenByBlock = {};
  var _nextToolIndex = 0;
  String? _stopReason;

  @override
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty || payload == '[DONE]') return const [];
    final decoded = _decodeObject(payload);
    final type = decoded['type'] is String
        ? decoded['type'] as String
        : (event ?? '');
    switch (type) {
      case 'content_block_start':
        final block = decoded['content_block'];
        final blockIndex = _intOf(decoded, 'index') ?? 0;
        if (block is! Map<String, Object?>) return const [];
        if (block['type'] == 'text') {
          final text = block['text'];
          if (text is String && text.isNotEmpty) {
            sawText = true;
            sawOutput = true;
            return [LlmDelta(text: text)];
          }
          return const [];
        }
        if (block['type'] == 'tool_use') {
          final index = _nextToolIndex++;
          _toolIndexByBlock[blockIndex] = index;
          final id = block['id'] is String ? block['id'] as String : null;
          final name = block['name'] is String ? block['name'] as String : null;
          final input = block['input'];
          final hasInput = input is Map && input.isNotEmpty;
          if (hasInput) _argsSeenByBlock[blockIndex] = true;
          sawOutput = true;
          return [
            LlmDelta(
              toolCalls: [
                LlmToolCallDelta(
                  index: index,
                  id: id,
                  name: name,
                  arguments: hasInput ? jsonEncode(input) : '',
                ),
              ],
            ),
          ];
        }
        return const [];
      case 'content_block_delta':
        final blockIndex = _intOf(decoded, 'index') ?? 0;
        final delta = decoded['delta'];
        if (delta is! Map<String, Object?>) return const [];
        switch (delta['type']) {
          case 'thinking_delta' || 'signature_delta':
            return const [LlmDelta(reasoningProgress: true)];
          case 'text_delta':
            final text = delta['text'];
            if (text is String && text.isNotEmpty) {
              sawText = true;
              sawOutput = true;
              return [LlmDelta(text: text)];
            }
          case 'input_json_delta':
            final args = delta['partial_json'];
            final index = _toolIndexByBlock[blockIndex];
            if (args is String && args.isNotEmpty && index != null) {
              _argsSeenByBlock[blockIndex] = true;
              sawOutput = true;
              return [
                LlmDelta(
                  toolCalls: [LlmToolCallDelta(index: index, arguments: args)],
                ),
              ];
            }
        }
        return const [];
      case 'message_delta':
        final delta = decoded['delta'];
        if (delta is Map<String, Object?>) {
          final reason = delta['stop_reason'];
          if (reason is String) _stopReason = reason;
        }
        if (_stopReason == 'max_tokens' || _stopReason == 'pause_turn') {
          truncated = true;
        }
        if (_stopReason == 'refusal') {
          throw const LlmException(LlmFailure.server, '模型拒绝回答这个问题');
        }
        return const [];
      case 'message_stop':
        done = true;
        return const [];
      case 'error':
        throw _streamError(decoded['error']);
      default:
        // ping、thinking 与工具调用收尾等事件不影响正文。
        return const [];
    }
  }

  LlmException _streamError(Object? error) {
    if (error is! Map) {
      return LlmException(LlmFailure.server, errorTextOf(error));
    }
    final type = error['type'];
    final message = error['message'];
    final detail = message is String && message.trim().isNotEmpty
        ? _clip(message.trim())
        : '模型服务出错';
    final failure = switch (type) {
      'authentication_error' || 'permission_error' => LlmFailure.auth,
      'rate_limit_error' => LlmFailure.rateLimited,
      'overloaded_error' || 'api_error' => LlmFailure.server,
      'invalid_request_error' || 'not_found_error' => LlmFailure.badResponse,
      _ => LlmFailure.server,
    };
    return LlmException(failure, detail);
  }

  @override
  LlmReply decodeBody(String body) {
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error != null) {
        throw _streamError(error);
      }
      final content = decoded['content'];
      if (content is! List) throw const FormatException('没有 content');
      final text = StringBuffer();
      final calls = <LlmToolCall>[];
      for (final block in content) {
        if (block is! Map<String, Object?>) continue;
        switch (block['type']) {
          case 'text':
            final value = block['text'];
            if (value is String) text.write(value);
          case 'tool_use':
            final name = block['name'];
            if (name is! String || name.trim().isEmpty) continue;
            final input = block['input'];
            calls.add(
              LlmToolCall(
                id: block['id'] is String ? block['id'] as String : '',
                name: name.trim(),
                arguments: input == null ? '' : jsonEncode(input),
              ),
            );
        }
      }
      final reason = decoded['stop_reason'];
      final truncated = reason == 'max_tokens' || reason == 'pause_turn';
      final bodyText = text.toString().trim();
      if (truncated && bodyText.isEmpty && calls.isEmpty) {
        throw const LlmException(LlmFailure.truncated, '达到输出上限');
      }
      if (bodyText.isEmpty && calls.isEmpty) {
        throw const FormatException('content 为空');
      }
      final usage = decoded['usage'];
      return LlmReply(
        text: bodyText,
        toolCalls: truncated ? const [] : calls,
        tokensIn: _intOf(usage, 'input_tokens') ?? 0,
        tokensOut: _intOf(usage, 'output_tokens') ?? 0,
        truncated: truncated,
      );
    } on FormatException catch (error) {
      throw LlmException(LlmFailure.badResponse, error.message);
    }
  }
}
// ---------------------------------------------------------------------------
// 片段与工具调用
// ---------------------------------------------------------------------------

/// 一条 Chat Completions 流式片段里的正文、工具调用与结束原因。
class _Chunk {
  const _Chunk({
    this.text = '',
    this.calls = const [],
    this.finish,
    this.reasoningProgress = false,
  });

  final String text;
  final List<LlmToolCallDelta> calls;
  final String? finish;
  final bool reasoningProgress;
}

/// `finish_reason` 里表示“没写完”的取值。
bool _incomplete(String finish) =>
    finish == 'length' ||
    finish == 'aborted' ||
    finish == 'insufficient_system_resource';

Map<String, Object?> _decodeObject(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw LlmException(LlmFailure.badResponse, '响应不是 JSON：${error.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const LlmException(LlmFailure.badResponse, '响应不是 JSON object');
  }
  return decoded;
}

int? _intOf(Object? value, String key) {
  if (value is! Map) return null;
  final found = value[key];
  return found is int ? found : null;
}

List<LlmToolCall> _toolCalls(Object? raw) {
  if (raw is! List) return const [];
  final result = <LlmToolCall>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final function = item['function'];
    if (function is! Map) continue;
    final name = function['name'];
    if (name is! String || name.trim().isEmpty) continue;
    final arguments = function['arguments'];
    result.add(
      LlmToolCall(
        id: item['id'] is String ? item['id'] as String : '',
        name: name.trim(),
        arguments: arguments is String
            ? arguments
            : arguments == null
            ? ''
            : jsonEncode(arguments),
      ),
    );
  }
  return result;
}

List<LlmToolCallDelta> _toolCallDeltas(Object? raw) {
  if (raw is! List) return const [];
  final result = <LlmToolCallDelta>[];
  for (var position = 0; position < raw.length; position++) {
    final item = raw[position];
    if (item is! Map) continue;
    final function = item['function'];
    final name = function is Map ? function['name'] : null;
    final arguments = function is Map ? function['arguments'] : null;
    if (name is! String && arguments is! String) continue;
    result.add(
      LlmToolCallDelta(
        // 有的实现不发 index，按数组位置区分并行调用。
        index: item['index'] is int ? item['index'] as int : position,
        id: item['id'] is String ? item['id'] as String : null,
        name: name is String && name.trim().isNotEmpty ? name.trim() : null,
        arguments: arguments is String
            ? arguments
            : arguments == null
            ? ''
            : jsonEncode(arguments),
      ),
    );
  }
  return result;
}
