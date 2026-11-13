import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models/chat_message.dart';
import '../domain/rules/content_identity.dart';
import 'agent_loop.dart';
import 'buddy_prompt.dart';
import 'llm_client.dart';
import 'llm_config.dart';
import 'llm_config_store.dart';
import 'llm_context_budget.dart';

/// 回答来源的接口；应用只依赖它，测试可以换成固定回答。
abstract class BuddyAi {
  Future<LlmConfig?> config();

  /// [onText] 不为空时边生成边回调已经可以显示的正文；回调只用于展示，
  /// 最终结果仍以返回的 [BuddyReply] 为准。
  /// [inputMessageId] 是本次用户消息已有的标识，重答时沿用原消息标识。
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  });
}

/// 一次回答最多带上多少字的讨论历史。
///
/// 不再按固定条数截断：短消息可以多带，长消息少带；超出预算时保留最近的
/// 消息，并始终保留第一条用户消息，避免模型丢掉这次讨论的原问题。
const int buddyHistoryCharBudget = 12000;

/// 从最近一条向前选取讨论历史，累计字数不超过 [buddyHistoryCharBudget]。
///
/// 第一条用户消息是这次讨论的原问题，即使已不在预算内也保留在最前面。
/// 本地规则写下的回答不进入模型历史：重答时那几句兜底话不是上一次的讲解，
/// 带进去会让模型接着套话往下说。讨论页与系统学习共用这一份规则，避免两处
/// 各写一个固定条数。
List<ChatMessage> selectBuddyHistory(
  List<ChatMessage> history, {
  int charBudget = buddyHistoryCharBudget,
}) {
  final usable = uniqueById([
    for (final message in history)
      if ((message.role == 'user' || message.role == 'assistant') &&
          message.structured?['model'] != false &&
          (message.content.trim().isNotEmpty || message.hasImages))
        message,
  ], (message) => message.identity).toList(growable: false);
  if (usable.isEmpty) return const [];
  var used = 0;
  final selected = <ChatMessage>[];
  for (final message in usable.reversed) {
    // 只有图片的消息按占位文字的长度计算，仍然要进入历史。
    final length = message.content.trim().isEmpty
        ? 7
        : message.content.length + 1;
    if (selected.isNotEmpty && used + length > charBudget) {
      break;
    }
    selected.add(message);
    used += length;
  }
  final firstUser = usable.where((message) => message.role == 'user');
  if (firstUser.isNotEmpty &&
      !selected.any(
        (message) => message.identity == firstUser.first.identity,
      )) {
    selected.add(firstUser.first);
  }
  return selected.reversed.toList(growable: false);
}

/// 为一轮回答装配配置、模型客户端、提示与本轮可用的学习工具。
class AiChatService implements BuddyAi {
  AiChatService({required this.store, http.Client? httpClient})
    : _httpClient = httpClient,
      _ownsHttpClient = httpClient == null;

  final LlmConfigStore store;

  /// 建一次连接反复用，省去每次求助重新握手；测试可以换成 MockClient。
  http.Client? _httpClient;
  final bool _ownsHttpClient;

  /// 最近一次成功读到的配置；Keystore 偶尔读不出来时沿用它，避免把一次
  /// 读取失败当成未配置而退回本地。
  LlmConfig? _lastConfig;

  /// 用户明确保存或删除配置后，同步更新运行时配置快照。
  void setConfigSnapshot(LlmConfig? value) => _lastConfig = value;

  @override
  Future<LlmConfig?> config() async {
    try {
      final value = await store.read();
      _lastConfig = value;
      return value;
    } on LlmConfigReadFailure {
      return _lastConfig;
    }
  }

  @override
  Future<BuddyReply> ask({
    required BuddyContext context,
    required List<ChatMessage> history,
    required String text,
    String? inputMessageId,
    List<LlmImage> images = const [],
    void Function(String text)? onText,
    LlmCancelToken? cancelToken,
    LlmConfigSnapshot? configSnapshot,
  }) async {
    final current = configSnapshot == null
        ? await config()
        : configSnapshot.value;
    if (current == null || !current.isConfigured) {
      throw const LlmException(LlmFailure.notConfigured, '模型尚未配置');
    }
    final client = _client(current);
    final tools = BuddyTurnTools(context);
    final system = buildBuddySystemPrompt(context);
    final messages = _messages(history, text, images, inputMessageId);
    try {
      final turn = await AgentLoop(client).run(
        system: system,
        messages: messages,
        tools: tools.registry,
        budget: LlmRequestBudget(
          timeout: const Duration(seconds: 90),
          cancelToken: cancelToken,
        ),
        contextBudget: LlmContextBudget(current),
        onText: onText,
      );
      if (turn.interruption case final error?) {
        if (error.failure == LlmFailure.cancelled) {
          return BuddyReply(text: turn.text, stopped: true);
        }
        return BuddyReply(
          text: turn.text,
          interrupted: true,
          interruptedReason: error.shortText,
        );
      }
      if (turn.truncated) return BuddyReply(text: turn.text, truncated: true);
      return tools.finish(turn.text);
    } on LlmException catch (error) {
      // 模型或地址不接受工具声明时，仍用首轮证据回答一次：系统提示里已经有
      // 本轮范围内的摘录，普通请求不需要工具也能给出正文。
      if (error.failure != LlmFailure.toolUnsupported &&
          error.failure != LlmFailure.badResponse) {
        rethrow;
      }
      final plain = await client.complete(
        system: '$system\n\n本轮不能调用工具，只写正文，不要提交引用、建议或记忆。',
        messages: messages,
      );
      final body = plain.text.trim();
      if (body.isEmpty) rethrow;
      return BuddyReply(text: body);
    } finally {
      client.dispose();
    }
  }

  List<LlmMessage> _messages(
    List<ChatMessage> history,
    String text,
    List<LlmImage> images,
    String? inputMessageId,
  ) => [
    for (final message in selectBuddyHistory([
      for (final message in history)
        if (message.identity != inputMessageId) message,
    ]))
      LlmMessage(
        id: message.identity,
        role: message.role,
        content: message.content.trim().isEmpty ? '[发了一张图片]' : message.content,
      ),
    LlmMessage(
      id: inputMessageId ?? 'turn:user',
      role: 'user',
      content: text.trim().isEmpty ? '[我发了一张图片]' : text.trim(),
      images: uniqueById(images, (image) => image.id).toList(growable: false),
    ),
  ];

  http.Client get _http => _httpClient ??= http.Client();

  HttpLlmClient _client(
    LlmConfig config, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return HttpLlmClient(config: config, httpClient: _http, timeout: timeout);
  }

  /// 设置页的连接测试：用同一份配置发一次最小工具请求，确认地址支持工具调用。
  Future<Duration> test(LlmConfig config) async {
    final client = _client(config, timeout: const Duration(seconds: 15));
    final started = DateTime.now();
    try {
      final reply = await client.complete(
        system: '你是连接测试助手。只调用 submit_probe 工具，不要写正文。',
        messages: const [LlmMessage(role: 'user', content: '连接测试')],
        tools: const [
          LlmTool(
            name: 'submit_probe',
            description: '连接测试：确认这个模型或地址可以返回工具调用。',
            parameters: {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
              'required': ['ok'],
            },
          ),
        ],
        forceTool: 'submit_probe',
      );
      final called = reply.toolCalls.any((call) => call.name == 'submit_probe');
      if (!called) {
        throw const LlmException(LlmFailure.toolUnsupported, '模型没有返回工具调用');
      }
      // 有工具调用还不够，参数必须是一段可解析的 JSON 对象。
      final probe = reply.toolCalls.firstWhere(
        (call) => call.name == 'submit_probe',
      );
      try {
        final arguments = jsonDecode(probe.arguments);
        if (arguments is! Map) {
          throw const FormatException('工具参数不是 JSON 对象');
        }
      } on FormatException {
        throw const LlmException(LlmFailure.toolUnsupported, '工具调用参数无法解析');
      }
      return DateTime.now().difference(started);
    } on LlmException catch (error) {
      if (error.failure == LlmFailure.badResponse) {
        throw const LlmException(LlmFailure.toolUnsupported, '这个模型或地址不支持工具调用');
      }
      rethrow;
    } finally {
      client.dispose();
    }
  }

  void dispose() {
    if (_ownsHttpClient) {
      _httpClient?.close();
      _httpClient = null;
    }
  }
}
