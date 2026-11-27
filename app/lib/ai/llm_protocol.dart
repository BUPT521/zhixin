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

/// 本轮发出的一条消息。线格式里每一段可能展开成多个条目：带图片的消息是一个
/// `message`，带工具调用的助手消息是一个 `message` 加若干 `function_call`，
/// 工具结果是一条 `function_call_output`。
class LlmMessage {
  const LlmMessage({
    this.id,
    required this.role,
    required this.content,
    this.images = const [],
    this.toolCalls = const [],
  }) : toolCallId = null,
       compileArgs = true;

  const LlmMessage.toolResult({
    required String callId,
    required this.content,
    this.compileArgs = true,
  }) : role = 'tool',
       id = _toolResultIdPrefix + callId,
       toolCallId = callId,
       images = const [],
       toolCalls = const [];

  /// 本轮内的消息标识，用于合并历史。
  final String? id;

  /// `user`、`assistant` 或 `tool`；系统提示单独放在请求的 `instructions` 里。
  final String role;
  final String content;

  /// 非空时 `content` 按内容块发送，文字在前、图片在后。
  final List<LlmImage> images;
  final List<LlmToolCall> toolCalls;

  /// 工具调用编号；只有工具结果消息有。
  final String? toolCallId;

  /// 工具结果的文字是否按结果发送。当场执行的工具给出 JSON 文本，按结果发送；
  /// 讨论历史里保存的原文可能不是 JSON，原样发送。
  final bool compileArgs;
}

/// 工具结果消息在轮内合并历史上的标识前缀。
///
/// 它只用于本轮的工具交换：历史消息的标识是 `message:<讨论>:<消息>`，两者
/// 格式不同，不能按前缀反推消息类型，因此这里不再提供反向解析。
const String _toolResultIdPrefix = 'tool-result:';

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

  /// Responses 的工具声明是扁平对象，名字、简介与参数都放在顶层。
  Map<String, Object?> toJson() => {
    'type': 'function',
    'name': name,
    'description': description,
    'parameters': parameters,
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

String _dataUrl(LlmImage image) =>
    'data:${image.mimeType};base64,${image._base64}';

Map<String, Object?> _object(Object? value) =>
    value is Map<String, Object?> ? value : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

// ---------------------------------------------------------------------------
// 请求体
// ---------------------------------------------------------------------------

/// Responses 的请求体。客户端只用知新服务，接口固定为
/// `POST <服务地址>/v1/llm/responses`。
///
/// 请求里不写 `temperature` 与 `top_p`：采样参数由上游模型自己的默认值决定，
/// 部分推理模型不接受这两个字段（ADR-0055）。
Map<String, Object?> responsesBody({
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
    'input': [for (final message in messages) ..._items(message)],
    'max_output_tokens': config.outputTokenLimit,
    // 客户端不依赖服务端保存会话，每一轮都把完整上下文重新发一次。
    'store': false,
    if (stream) 'stream': true,
    if (tools.isNotEmpty) 'tools': [for (final tool in tools) tool.toJson()],
    if (tools.isNotEmpty)
      'tool_choice': !allowToolCalls
          ? 'none'
          : forceTool == null
          ? 'auto'
          : {'type': 'function', 'name': forceTool},
  };
}

/// 工具结果在请求里的 `output` 文本：当场执行的工具按结果编码成 JSON，讨论历史里
/// 保存的原文原样发送。估算输入时也用这一份，客户端与服务端读到的才是同一段文字。
String toolResultWireText(LlmMessage message) => message.compileArgs
    ? jsonEncode(_toolOutput(message.content))
    : message.content;

/// 一条消息展开成请求里的条目：工具结果单独成条，其余按角色生成 `message`，
/// 助手消息发起的工具调用跟在正文之后。
///
/// 条目里的 `arguments` 是 JSON 文本：当场执行的调用由客户端自己编码，历史
/// 记录里按代码写下的文字原样发出。工具结果的 `output` 是结果的 JSON 文本，
/// 历史记录里保存的原文原样发出。
List<Map<String, Object?>> _items(LlmMessage message) {
  if (message.toolCallId case final id?) {
    return [
      {
        'type': 'function_call_output',
        'call_id': id,
        'output': toolResultWireText(message),
      },
    ];
  }
  final role = message.role == 'assistant' ? 'assistant' : 'user';
  final items = <Map<String, Object?>>[
    if (message.images.isEmpty)
      {'type': 'message', 'role': role, 'content': message.content}
    else
      {
        'type': 'message',
        'role': role,
        'content': [
          {'type': 'input_text', 'text': message.content},
          for (final image in message.images)
            {'type': 'input_image', 'image_url': _dataUrl(image)},
        ],
      },
  ];
  for (final call in message.toolCalls) {
    items.add({
      'type': 'function_call',
      'call_id': call.id,
      'name': call.name,
      'arguments': call.arguments.isEmpty ? '{}' : call.arguments,
    });
  }
  return items;
}

/// 工具结果的文字按 JSON 对象读；读不出来时包成一段说明，模型仍然看得见。
Map<String, Object?> _toolOutput(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // 不是 JSON：按普通文字回传。
  }
  return {'result': content};
}

// ---------------------------------------------------------------------------
// 流式增量
// ---------------------------------------------------------------------------

/// 一次流式回答的解码状态：结束标记、截断与是否已经给出内容都在这里记下，
/// 读流的代码据此决定保留正文还是按失败处理。
///
/// 事件按 `event:` 名称分支，正文、工具参数、完整工具调用与结束四种事件之外
/// 的事件一律忽略；服务端省略 `event:` 时按负载里的 `type` 判断。
class LlmStream {
  bool done = false;
  bool truncated = false;
  bool sawText = false;
  bool sawOutput = false;

  /// 已经开始、还没有完成条目的工具调用序号。
  final _openCalls = <int>{};

  /// 已经收到完整条目的工具调用序号；推测一个空位时不再分配给它们。
  final _doneIndexes = <int>{};

  /// 一个 SSE 事件转成增量；服务端报错时抛出 [LlmException]。
  List<LlmDelta> accept(String? event, String data) {
    final payload = data.trim();
    if (payload.isEmpty || payload == '[DONE]') return const [];
    final decoded = _decodeObject(payload);
    final error = decoded['error'];
    if (error != null) {
      throw LlmException(LlmFailure.server, errorTextOf(error));
    }
    final name = _eventName(decoded, event);
    return switch (name) {
      'response.output_text.delta' => _text(_string(decoded['delta'])),
      'response.function_call_arguments.delta' => _arguments([
        LlmToolCallDelta(
          index: _indexOf(decoded),
          arguments: _string(decoded['delta']),
        ),
      ]),
      'response.output_item.done' => _doneItem(
        decoded: decoded,
        item: _object(decoded['item']),
      ),
      'response.refusal.delta' => throw LlmException(
        LlmFailure.refused,
        _string(decoded['delta']),
      ),
      'response.completed' => _finish(reason: null),
      'response.incomplete' => _finish(reason: _incompleteReason(decoded)),
      'response.failed' => throw LlmException(
        LlmFailure.server,
        _failureText(decoded),
      ),
      'error' => throw LlmException(
        LlmFailure.server,
        errorTextOf(decoded['error'] ?? decoded['message']),
      ),
      _ => const [],
    };
  }

  /// 流结束时检查：没有正文也没有工具调用按格式错误抛出。
  void verify() {
    if (!sawOutput) {
      throw const LlmException(LlmFailure.badResponse, '流式响应没有内容');
    }
  }

  List<LlmDelta> _text(String delta) {
    if (delta.isEmpty) return const [];
    sawText = true;
    sawOutput = true;
    return [LlmDelta(text: delta)];
  }

  List<LlmDelta> _arguments(List<LlmToolCallDelta> calls) {
    for (final call in calls) {
      if (call.arguments.isEmpty) continue;
      sawOutput = true;
      _openCalls.add(call.index);
    }
    return calls.any((call) => call.arguments.isNotEmpty)
        ? [LlmDelta(toolCalls: calls)]
        : const [];
  }

  /// 条目完成事件缺少序号时，取一个已经由参数增量开始、还没有完成过的序号；
  /// 都没有时取最小的未用序号。已经取走的序号不再参与分配，避免两个调用换位。
  int _freeIndex() {
    final pending = <int>[
      for (final index in _openCalls)
        if (!_doneIndexes.contains(index)) index,
    ]..sort();
    if (pending.isNotEmpty) {
      final index = pending.first;
      _openCalls.remove(index);
      return index;
    }
    var index = 0;
    while (_doneIndexes.contains(index)) {
      index++;
    }
    return index;
  }

  /// 一个输出条目完成：函数调用收下完整参数，正文条目在这里确认结束。
  ///
  /// 序号先取事件顶层的 `output_index`，再退到条目自己的 `output_index`，最后
  /// 才按未完成序号的插入顺序推测。两个调用按相反顺序完成时，只有顶层序号能
  /// 把完整参数、调用编号与工具名写回自己的那一项。
  List<LlmDelta> _doneItem({
    required Map<String, Object?> decoded,
    required Map<String, Object?> item,
  }) {
    switch (item['type']) {
      case 'function_call':
        final name = _string(item['name']).trim();
        if (name.isEmpty) return const [];
        final callId = _string(item['call_id']);
        final index =
            _optionalIndex(decoded['output_index']) ??
            _optionalIndex(item['output_index']) ??
            _freeIndex();
        _openCalls.remove(index);
        _doneIndexes.add(index);
        sawOutput = true;
        return [
          LlmDelta(
            toolCalls: [
              LlmToolCallDelta(
                index: index,
                id: callId.isEmpty ? null : callId,
                name: name,
                arguments: _string(item['arguments']),
                replaceArguments: true,
              ),
            ],
          ),
        ];
      case 'message':
        // 官方事件顺序里，正文增量之后还会有一条带完整 message 的条目完成
        // 事件；增量已经把正文交给界面，这里若再发一遍就会出现“正文 + 正文”。
        // 只有一条正文增量都没收到时才用完整条目补回，供不带增量的来源使用。
        if (sawText) return const [];
        final text = _outputText(item['content']);
        return text.isEmpty ? const [] : _text(text);
      default:
        return const [];
    }
  }

  /// 结束事件：`response.completed` 不带原因，`response.incomplete` 带
  /// `incomplete_details.reason`。
  ///
  /// 只有 `max_output_tokens` 才是“回答过长”，可以保留正文；内容被过滤或
  /// 模型主动停下时正文不完整，按服务端错误报告，不能提示用户“回答过长”。
  List<LlmDelta> _finish({required String? reason}) {
    done = true;
    if (reason == null) return const [];
    if (reason != _incompleteMaxTokens) {
      throw LlmException(LlmFailure.server, '模型没有完成回答：$reason');
    }
    truncated = true;
    // 截断时正文保留，工具参数多半不完整，交给调用方丢掉。
    return sawText ? const [LlmDelta(truncated: true)] : const [];
  }

  /// `response.incomplete` 的 `incomplete_details.reason`；字段缺失时按输出
  /// 上限处理，与官方文档里该原因的默认含义一致。
  static String? _incompleteReason(Map<String, Object?> decoded) {
    final response = _object(decoded['response']);
    final details = _object(response['incomplete_details']);
    final reason = details['reason'];
    return reason is String && reason.isNotEmpty
        ? reason
        : _incompleteMaxTokens;
  }

  static String _failureText(Map<String, Object?> decoded) {
    final response = _object(decoded['response']);
    final error = response['error'] ?? decoded['error'];
    if (error != null) return errorTextOf(error);
    final status = response['status'];
    return status is String ? '响应状态为 $status' : '模型服务出错';
  }

  /// 服务端省略 `event:` 时，负载仍可能带 `output_index` 与 `sequence_number`。
  static String _eventName(Map<String, Object?> decoded, String? event) {
    if (event != null && event.isNotEmpty) return event;
    final type = decoded['type'];
    return type is String ? type : '';
  }
}

// ---------------------------------------------------------------------------
// 整段响应
// ---------------------------------------------------------------------------

/// 服务端忽略 `stream` 直接返回整段 JSON 时，按输出条目读出同样的增量。
LlmReply decodeResponse(String body) {
  try {
    final decoded = _decodeObject(body);
    final error = decoded['error'];
    if (error != null) {
      throw LlmException(LlmFailure.server, errorTextOf(error));
    }
    final status = decoded['status'];
    if (status == 'failed') {
      throw LlmException(
        LlmFailure.server,
        errorTextOf(decoded['error'] ?? _object(decoded['response'])['error']),
      );
    }
    final buffer = StringBuffer();
    final refusals = StringBuffer();
    final calls = <LlmToolCall>[];
    for (final entry in _list(decoded['output'])) {
      final item = _object(entry);
      switch (item['type']) {
        case 'message':
          buffer.write(_outputText(item['content']));
          refusals.write(_refusalText(item['content']));
        case 'refusal':
          refusals.write(_string(item['refusal']));
        case 'function_call':
          final name = _string(item['name']).trim();
          if (name.isEmpty) continue;
          final arguments = item['arguments'];
          calls.add(
            LlmToolCall(
              id: _string(item['call_id']),
              name: name,
              arguments: arguments is String
                  ? arguments
                  : arguments == null
                  ? '{}'
                  : jsonEncode(arguments),
            ),
          );
      }
    }
    // 模型按内容政策拒答时没有正文，只有 refusal 块。把它当成空回答会让界面
    // 提示“没有内容”，用户不知道是被拒答了。
    if (buffer.isEmpty && refusals.isNotEmpty) {
      throw LlmException(LlmFailure.refused, refusals.toString());
    }
    final incomplete = _object(decoded['incomplete_details'])['reason'];
    final truncated =
        status == 'incomplete' &&
        (incomplete is! String || incomplete == _incompleteMaxTokens);
    if (status == 'incomplete' && !truncated) {
      throw LlmException(
        LlmFailure.server,
        '模型没有完成回答：${incomplete is String ? incomplete : status}',
      );
    }
    return _replyFromParts(
      text: buffer.toString().trim(),
      toolCalls: calls,
      truncated: truncated,
      emptyDetail: 'output 里没有正文与工具调用',
      usage: _object(decoded['usage']),
    );
  } on FormatException catch (error) {
    throw LlmException(LlmFailure.badResponse, error.message);
  }
}

/// 整段响应共用的收尾：空回答按格式错误，因输出上限截断且没有留下有效内容
/// 时按截断失败，其余情况返回同一份回复。
LlmReply _replyFromParts({
  required String text,
  required List<LlmToolCall> toolCalls,
  required bool truncated,
  required String emptyDetail,
  required Map<String, Object?> usage,
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
    tokensIn: _intOf(usage, 'input_tokens'),
    tokensOut: _intOf(usage, 'output_tokens'),
    truncated: truncated,
  );
}

// ---------------------------------------------------------------------------
// 条目读取
// ---------------------------------------------------------------------------

Map<String, Object?> _decodeObject(String payload) {
  Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException catch (error) {
    throw LlmException(LlmFailure.badResponse, '响应不是 JSON：${error.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const LlmException(LlmFailure.badResponse, '响应不是 JSON object');
  }
  return decoded;
}

String _string(Object? value) => value is String ? value : '';

/// `response.incomplete` 里表示“输出达到上限”的原因值；其余原因不属于回答被
/// 截断，见 [LlmStream._finish]。
const String _incompleteMaxTokens = 'max_output_tokens';

int _indexOf(Map<String, Object?> event) =>
    _optionalIndex(event['output_index']) ?? 0;

/// 读出来的 `output_index`；没有这个字段或不是整数时为 null，由调用方决定
/// 退到哪个默认值。
int? _optionalIndex(Object? value) => switch (value) {
  final int index => index,
  _ => null,
};

int _intOf(Map<String, Object?> usage, String key) => switch (usage[key]) {
  final int value => value,
  _ => 0,
};

/// 助手消息的内容块数组：只取 `output_text` 的文字，其余块忽略。
String _outputText(Object? content) {
  if (content is String) return content;
  final buffer = StringBuffer();
  for (final part in _list(content)) {
    final block = _object(part);
    if (block['type'] == 'output_text' && block['text'] is String) {
      final text = block['text'] as String;
      if (buffer.isNotEmpty && text.isNotEmpty) buffer.write('\n');
      buffer.write(text);
    }
  }
  return buffer.toString();
}

/// 助手消息里的拒答块；模型按内容政策拒答时正文为空，文字放在这里。
String _refusalText(Object? content) {
  if (content is String) return '';
  final buffer = StringBuffer();
  for (final part in _list(content)) {
    final block = _object(part);
    if (block['type'] == 'refusal' && block['refusal'] is String) {
      buffer.write(block['refusal']);
    }
  }
  return buffer.toString();
}
