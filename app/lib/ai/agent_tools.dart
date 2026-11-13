import 'dart:async';
import 'dart:convert';

import 'llm_client.dart';
import 'llm_context_budget.dart';

typedef ToolArguments = Map<String, Object?>;

/// 工具的参数声明与实现共用一份定义，只有声明会发送给模型。
class AgentTool {
  const AgentTool({
    required this.schema,
    required this.execute,
    this.continuesAfterText = true,
    this.partialList,
  });

  final LlmTool schema;
  final FutureOr<AgentToolResult> Function(
    ToolArguments arguments,
    int resultTokens,
  )
  execute;

  /// 读到的资料需要交回模型，即使这一步已经有正文。
  final bool continuesAfterText;

  /// 可选提案允许保留同一批中合格的条目。完整方案使用默认的整批校验。
  final String? partialList;

  Future<AgentToolResult> _invoke(
    ToolArguments arguments,
    int resultTokens,
  ) async {
    final problem = _validateArguments(
      schema.parameters,
      arguments,
      '',
      partialList: partialList,
    );
    if (problem != null) return AgentToolResult.invalid(problem);
    if (partialList case final field?) {
      final items = arguments[field] as List;
      final properties = schema.parameters['properties'] as Map;
      final itemSchema = (properties[field] as Map)['items'] as Map;
      final valid = <Object?>[];
      String? firstProblem;
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final problem = _validateArguments(itemSchema, item, '$field[$index]');
        if (problem == null) valid.add(item);
        firstProblem ??= problem;
      }
      if (valid.isEmpty) {
        return AgentToolResult.invalid(firstProblem ?? '$field 不能为空');
      }
      arguments = {...arguments, field: valid};
    }
    return await execute(arguments, resultTokens);
  }
}

class AgentToolResult {
  const AgentToolResult(this.content, {this.concludesTurn = false})
    : errorCode = null,
      madeProgress = true;
  const AgentToolResult.unchanged(this.content)
    : errorCode = null,
      madeProgress = false,
      concludesTurn = false;
  const AgentToolResult.error(String code, this.content)
    : errorCode = code,
      madeProgress = false,
      concludesTurn = false;
  const AgentToolResult.invalid(String message)
    : this.error('invalid_args', message);

  final Object content;
  final String? errorCode;
  final bool madeProgress;
  final bool concludesTurn;

  String get encoded => jsonEncode({
    if (errorCode case final code?) ...{
      'code': code,
      'error': content,
    } else
      'result': content,
  });

  LlmMessage messageFor(String callId) => LlmMessage.toolResult(
    callId: callId,
    content: encoded,
    toolIsError: errorCode != null,
  );
}

typedef PreparedToolCall = ({
  LlmToolCall call,
  AgentTool? tool,
  ToolArguments? arguments,
  bool conflict,
});

typedef AgentToolOutcome = ({
  String name,
  AgentToolResult result,
  LlmMessage message,
});

class AgentToolBatch {
  const AgentToolBatch(this.outcomes);

  final List<AgentToolOutcome> outcomes;

  bool get madeProgress => outcomes.any((entry) => entry.result.madeProgress);
  bool concludesWith(String name) =>
      outcomes.any((entry) => entry.name == name && entry.result.concludesTurn);
}

/// 一轮回答可用的工具。声明与执行使用同一份注册表，批次按模型顺序完成。
class AgentToolSet {
  AgentToolSet(Iterable<AgentTool> tools, {this.requiredTool})
    : _tools = _index(tools) {
    if (requiredTool != null && !_tools.containsKey(requiredTool)) {
      throw ArgumentError.value(requiredTool, 'requiredTool', '未注册此工具');
    }
  }

  final Map<String, AgentTool> _tools;
  final String? requiredTool;
  final _usedIds = <String>{};
  var _generatedId = 0;
  static const _reservedPayloadTokens = 96;

  List<LlmTool> get schemas => [
    for (final tool in _tools.values)
      if (requiredTool == null || tool.schema.name == requiredTool) tool.schema,
  ];

  void reserveHistory(Iterable<LlmMessage> messages) {
    for (final message in messages) {
      _usedIds.addAll(message.toolCalls.map((call) => call.id));
      if (message.toolCallId case final id?) _usedIds.add(id);
    }
  }

  List<PreparedToolCall> prepare(
    List<LlmToolCall> calls,
    LlmRequestBudget budget,
  ) {
    final seenIds = <String>{};
    final seenCalls = <(String, String, String)>{};
    final availableIds = {
      for (final call in calls)
        if (_callId.hasMatch(call.id) && _usedIds.add(call.id)) call.id,
    };
    final prepared = <PreparedToolCall>[];
    for (final call in calls) {
      budget.check();
      if (!seenCalls.add((call.id, call.name, call.arguments))) continue;
      final conflict = call.id.isNotEmpty && !seenIds.add(call.id);
      final arguments = call.argumentsObject;
      prepared.add((
        call: LlmToolCall(
          id: availableIds.remove(call.id) ? call.id : _nextId(),
          name: _toolName.hasMatch(call.name) ? call.name : 'invalid_tool',
          arguments: arguments == null ? '{}' : call.arguments,
        ),
        tool: requiredTool == null || call.name == requiredTool
            ? _tools[call.name]
            : null,
        arguments: arguments,
        conflict: conflict,
      ));
    }
    return prepared;
  }

  /// 续接前为每个结果保留消息包装和简短回执的空间。
  int reservedResultTokens(
    List<PreparedToolCall> calls,
    LlmContextBudget contextBudget,
  ) {
    var reserved = 0;
    for (final entry in calls) {
      reserved +=
          _reservedPayloadTokens +
          contextBudget.messageTokens(
            LlmMessage.toolResult(callId: entry.call.id, content: ''),
          );
    }
    return reserved;
  }

  Future<AgentToolBatch> execute(
    List<PreparedToolCall> calls,
    LlmRequestBudget budget, {
    required int extraResultTokens,
  }) async {
    final outcomes = <AgentToolOutcome>[];
    for (final entry in calls) {
      budget.check();
      final result = await _execute(
        entry,
        _reservedPayloadTokens + extraResultTokens,
      );
      final message = result.messageFor(entry.call.id);
      extraResultTokens +=
          _reservedPayloadTokens - estimateLlmTextTokens(message.content);
      outcomes.add((name: entry.call.name, result: result, message: message));
    }
    budget.check();
    return AgentToolBatch(outcomes);
  }

  Future<AgentToolResult> _execute(
    PreparedToolCall call,
    int resultTokens,
  ) async {
    if (call.conflict) {
      return const AgentToolResult.error(
        'duplicate_call_id',
        '同一步的调用编号冲突，请重新调用',
      );
    }
    final tool = call.tool;
    if (tool == null) {
      return const AgentToolResult.error('tool_unavailable', '本轮未开放此工具');
    }
    final arguments = call.arguments;
    if (arguments == null) {
      return const AgentToolResult.invalid('工具参数必须是 JSON 对象');
    }
    try {
      return await tool._invoke(arguments, resultTokens);
    } on Exception {
      return const AgentToolResult.error('execution_failed', '工具执行失败，请调整参数后重试');
    }
  }

  String _nextId() {
    String id;
    do {
      id = 'call_zhixin_${++_generatedId}';
    } while (!_usedIds.add(id));
    return id;
  }

  static final _toolName = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
  static final _callId = RegExp(r'^[a-zA-Z0-9_-]+$');

  static Map<String, AgentTool> _index(Iterable<AgentTool> tools) {
    final indexed = <String, AgentTool>{};
    for (final tool in tools) {
      final name = tool.schema.name;
      if (!_toolName.hasMatch(name) || indexed.containsKey(name)) {
        throw ArgumentError.value(name, 'tool.name', '工具名称无效或重复');
      }
      indexed[name] = tool;
    }
    return indexed;
  }
}

/// 校验本地工具所用的 JSON Schema 关键字，错误指明参数路径。
String? _validateArguments(
  Map schema,
  Object? value,
  String path, {
  String? partialList,
}) {
  final type = schema['type'];
  final types = type is List ? type : [type];
  final label = path.isEmpty ? '参数' : path;
  if (!types.any(
    (type) => switch (type) {
      'object' => value is Map<String, Object?>,
      'array' => value is List,
      'string' => value is String,
      'integer' => value is int,
      'boolean' => value is bool,
      'null' => value == null,
      _ => throw StateError('不支持的工具参数类型：$type'),
    },
  )) {
    return '$label 类型错误，应为 ${types.join(' 或 ')}';
  }
  if (schema['enum'] case final List values when !values.contains(value)) {
    return '$label 应为 ${values.join('、')} 之一';
  }
  if (value is Map<String, Object?>) {
    final properties = schema['properties'] as Map;
    final required = schema['required'] as List? ?? const [];
    for (final entry in properties.entries) {
      final key = entry.key as String;
      final field = path.isEmpty ? key : '$path.$key';
      if (!value.containsKey(key)) {
        if (required.contains(key)) return '缺少 $field';
        continue;
      }
      final fieldSchema = entry.value as Map;
      final problem = _validateArguments(
        key == partialList ? ({...fieldSchema}..remove('items')) : fieldSchema,
        value[key],
        field,
      );
      if (problem != null) return problem;
    }
  }
  if (value is List) {
    if (schema['minItems'] case final int min when value.length < min) {
      return '$label 至少需要 $min 项';
    }
    if (schema['maxItems'] case final int max when value.length > max) {
      return '$label 最多允许 $max 项';
    }
    if (schema['items'] case final Map items) {
      for (var index = 0; index < value.length; index++) {
        final problem = _validateArguments(
          items,
          value[index],
          '$path[$index]',
        );
        if (problem != null) return problem;
      }
    }
  }
  if (schema['minimum'] case final int min when value is int && value < min) {
    return '$label 必须大于或等于 $min';
  }
  if (value is String) {
    if (schema['minLength'] case final int min
        when value.trim().runes.length < min) {
      return '$label 不能为空';
    }
    if (schema['maxLength'] case final int max
        when value.trim().runes.length > max) {
      return '$label 最多允许 $max 个字符';
    }
  }
  return null;
}
