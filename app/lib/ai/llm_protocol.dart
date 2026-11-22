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

  /// 本轮内的消息标识，用于合并历史；线协议组装请求体时带上。
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
// 整段响应的收尾判定
// ---------------------------------------------------------------------------

/// 整段响应共用的收尾：空回答按格式错误，因输出上限截断且没有留下有效内容
/// 时按截断失败，其余情况返回同一份回复。
LlmReply _replyFromParts({
  required String text,
  required List<LlmToolCall> toolCalls,
  required bool truncated,
  required String emptyDetail,
  required int tokensIn,
  required int tokensOut,
}) {
  if (truncated && text.isEmpty) {
    throw const LlmException(LlmFailure.truncated, '达到输出上限');
  }
  final empty = text.isEmpty && toolCalls.isEmpty;
  if (empty) {
    throw FormatException(emptyDetail);
  }
  return LlmReply(
    text: text,
    toolCalls: truncated ? const [] : toolCalls,
    tokensIn: tokensIn,
    tokensOut: tokensOut,
    truncated: truncated,
    reasoningItems: const [],
  );
}

// ---------------------------------------------------------------------------
// Chat Completions 线格式
// ---------------------------------------------------------------------------

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

/// 客户端只用知新服务，接口固定为 OpenAI 兼容的 `/chat/completions`。
final class ChatWire extends LlmWire {
  const ChatWire();

  @override
  Map<String, String> headers(LlmConfig config, {required bool stream}) => {
    'Authorization': 'Bearer ${config.apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };

  /// 知新服务背后的提供方按模型名配置，DeepSeek 的思考模式默认打开，推理内容
  /// 同样计入输出上限，还会让指定工具的 `tool_choice` 直接返回 400；知新的回答
  /// 只要三到五句，所以按模型名关掉。`max_tokens` 是各提供方都认的字段。
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
      if (config.reasoningDisabled) 'thinking': const {'type': 'disabled'},
      if (stream) 'stream': true,
      if (stream) 'stream_options': const {'include_usage': true},
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
  LlmDecoder decoder() => ChatDecoder();
}

// ---------------------------------------------------------------------------
// 流式解码
// ---------------------------------------------------------------------------

/// 一次流式回答的解码状态：结束标记、截断与是否已经给出内容都在这里记下，
/// 读流的代码据此决定保留正文还是按失败处理。
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
final class ChatDecoder extends LlmDecoder {
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
      final calls = message is Map<String, Object?>
          ? _toolCalls(message['tool_calls'])
          : const <LlmToolCall>[];
      final usage = decoded['usage'];
      return _replyFromParts(
        text: text,
        toolCalls: calls,
        truncated: truncated,
        emptyDetail: 'message.content 为空',
        tokensIn:
            _intOf(usage, 'prompt_tokens') ??
            _intOf(usage, 'input_tokens') ??
            0,
        tokensOut:
            _intOf(usage, 'completion_tokens') ??
            _intOf(usage, 'output_tokens') ??
            0,
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
