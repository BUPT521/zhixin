import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/ai_chat_service.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_config_store.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/score.dart';

/// 测试用的假地址：请求打到这个地址，客户端只用配置里的完整接口地址。
const String _testEndpoint = 'https://zhixin.test/v1/llm/responses';

class _MemorySecrets implements SecretStore {
  String? value;
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }

  @override
  Future<void> delete(String key) async {
    value = null;
  }
}

String _textDelta(String text) =>
    'event: response.output_text.delta\n'
    'data: ${jsonEncode({
      'type': 'response.output_text.delta',
      'output_index': 0,
      'delta': text,
    })}\n\n';

String _argumentsDelta(int index, String delta) =>
    'event: response.function_call_arguments.delta\n'
    'data: ${jsonEncode({
      'type': 'response.function_call_arguments.delta',
      'output_index': index,
      'delta': delta,
    })}\n\n';

String _itemDone(Map<String, Object?> item, {int index = 1}) =>
    'event: response.output_item.done\n'
    'data: ${jsonEncode({
      'type': 'response.output_item.done',
      'output_index': index,
      'item': item,
    })}\n\n';

const String _done =
    'event: response.completed\n'
    'data: {"type":"response.completed","response":{"status":"completed"}}\n\n';

const String _incomplete =
    'event: response.incomplete\n'
    'data: {"type":"response.incomplete","response":{"status":"incomplete"}}\n\n';

Map<String, Object?> _callItem(String id, String name, Object arguments) => {
  'type': 'function_call',
  'call_id': id,
  'name': name,
  'arguments': jsonEncode(arguments),
};

http.Response _jsonReply(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _chatReply({String? text, List<Object?> calls = const []}) =>
    _jsonReply({
      'object': 'response',
      'status': 'completed',
      'output': [
        if (text != null)
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text, 'annotations': []},
            ],
          },
        ...calls,
      ],
    });

/// 一段整段响应，内容按 JSON 返回；嵌套使用时不会重复编码。
Map<String, Object?> chatReply({String? text, List<Object?> calls = const []}) =>
    {
      'object': 'response',
      'status': 'completed',
      'output': [
        if (text != null)
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text, 'annotations': []},
            ],
          },
        ...calls,
      ],
    };

http.StreamedResponse _stream(String body) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  200,
  headers: {'content-type': 'text/event-stream'},
);

/// 一次整段响应，内容按 JSON 返回。
http.StreamedResponse _streamedJson(Object? body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  200,
  headers: {'content-type': 'application/json'},
);

/// 一段流式回答：正文增量之后收尾。
String _streamReply({String? text, List<Object?> calls = const []}) => [
  if (text != null) _textDelta(text),
  for (var index = 0; index < calls.length; index++)
    [calls[index] as Map<String, Object?>]
        .map((item) => _itemDone(item, index: index + 1))
        .join(),
  _done,
].join();

const _hit = MaterialHit(
  materialId: 'mat-2',
  materialTitle: '概率论讲义',
  pageNo: 7,
  content: '这是正文里的条件概率公式。',
  snippetText: '条件概率……',
);

void main() {
  Future<AiChatService> serviceWith(http.Client client) async {
    final store = LlmConfigStore(_MemorySecrets());
    await store.save(
      const LlmConfig(endpoint: _testEndpoint, apiKey: 'sk-test'),
    );
    return AiChatService(store: store, httpClient: client);
  }

  BuddyContext context() => BuddyContext(now: DateTime(2026, 11, 7, 20));

  BuddyContext withMaterial() =>
      BuddyContext(now: DateTime(2026, 11, 7, 20), materialHits: const [_hit]);

  List<Map<String, Object?>> inputOf(Map<String, Object?> body) =>
      (body['input'] as List).cast<Map<String, Object?>>();

  List<Map<String, Object?>> callsIn(Map<String, Object?> body) => [
    for (final item in inputOf(body))
      if (item['type'] == 'function_call') item,
  ];

  List<Map<String, Object?>> outputsIn(Map<String, Object?> body) => [
    for (final item in inputOf(body))
      if (item['type'] == 'function_call_output') item,
  ];

  Map<String, Object?> resultOf(Map<String, Object?> output) =>
      jsonDecode(output['output'] as String) as Map<String, Object?>;

  test('材料原文、拒绝结果和提案按调用编号回传', () async {
    const calls = [
      (
        id: 'call_page',
        name: readMaterialPageTool,
        args: {'material_id': 'mat-2', 'page_no': 7},
      ),
      (
        id: 'call_denied',
        name: readMaterialPageTool,
        args: {'material_id': 'mat-2', 'page_no': 8},
      ),
      (
        id: 'call_proposal',
        name: proposeNextStepsTool,
        args: {
          'steps': [
            {'title': '阅读定义'},
          ],
        },
      ),
    ];
    final captured = <Map<String, Object?>>[];
    final service = await serviceWith(
      MockClient((request) async {
        captured.add(
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>,
        );
        if (captured.length == 1) {
          return _chatReply(
            calls: [
              for (final call in calls)
                _callItem(call.id, call.name, call.args),
            ],
          );
        }
        return _chatReply(text: '按公式计算。');
      }),
    );

    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请看原文',
      configSnapshot: const LlmConfigSnapshot(
        LlmConfig(
          endpoint: _testEndpoint,
          model: 'test-model',
          apiKey: 'sk-test',
        ),
      ),
    );
    expect(reply.text, '按公式计算。');
    expect(reply.nextSteps.single.title, '阅读定义');
    expect(captured, hasLength(2));
    expect(jsonEncode(captured.first), isNot(contains(_hit.content)));

    final second = captured.last;
    final invocations = callsIn(second);
    final outputs = outputsIn(second);
    final ids = calls.map((call) => call.id);
    expect(invocations.map((call) => call['call_id']), ids);
    expect(outputs.map((output) => output['call_id']), ids);
    expect((resultOf(outputs.first)['result'] as Map)['content'], _hit.content);
    expect(resultOf(outputs.elementAt(1)), contains('error'));
    expect(resultOf(outputs.last)['result'], '已暂存提案');
  });

  test('重复读取已返回的范围只回传位置，连续无进展后收束正文', () async {
    var requests = 0;
    String? contentId;
    final service = await serviceWith(
      MockClient((request) async {
        requests++;
        final body =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
        final outputs = outputsIn(body);
        if (requests == 2) {
          final result = resultOf(outputs.last)['result'] as Map;
          contentId = result['content_id'] as String;
          expect(contentId, startsWith('material:'));
        }
        if (requests > 2) {
          final result = resultOf(outputs.last)['result'] as Map;
          expect(result['offset'], 0);
          expect(result['content_id'], contentId);
          expect(result['note'], contains('已在本轮返回'));
          expect(result.containsKey('content'), isFalse);
          expect(callsIn(body), hasLength(requests - 1));
        }
        if (requests == 4) {
          expect(body['tool_choice'], 'none');
          expect(body['tools'], isNotEmpty);
          return _chatReply(text: '根据已有原文回答。');
        }
        expect(body['tool_choice'], 'auto');
        return _chatReply(
          calls: [
            _callItem('call_reused', readMaterialPageTool, {
              'material_id': 'mat-2',
              'page_no': 7,
              'offset': requests == 1 ? 0 : requests - 1,
            }),
          ],
        );
      }),
    );
    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请看原文',
    );
    expect(reply.text, '根据已有原文回答。');
    expect(requests, 4);
  });

  test('坏参数、未开放工具与冲突编号各有可配对的结果，合法调用继续执行', () async {
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        requests++;
        if (requests == 1) {
          return _chatReply(
            calls: [
              _callItem('shared', readMaterialPageTool, {
                'material_id': 'mat-2',
                'page_no': 7,
                'offset': -1,
              }),
              _callItem('shared', proposeNextStepsTool, {
                'steps': [
                  {'title': '编号冲突的建议'},
                ],
              }),
              _callItem('denied', proposeStudyStepsTool, {'steps': []}),
              _callItem('', readMaterialPageTool, {
                'material_id': 'mat-2',
                'page_no': 7,
              }),
            ],
          );
        }
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        final ids = callsIn(body.cast<String, Object?>())
            .map((item) => item['call_id'])
            .toList();
        final outputs = outputsIn(body.cast<String, Object?>());
        expect(ids.toSet(), hasLength(4));
        expect(outputs.map((item) => item['call_id']), ids);
        final content = outputs.map(resultOf).toList();
        expect(content.take(3).map((item) => item['code']), [
          'invalid_args',
          'duplicate_call_id',
          'tool_unavailable',
        ]);
        expect(content.first['error'], contains('offset'));
        expect((content.last['result'] as Map)['content'], _hit.content);
        return _chatReply(text: '根据原文回答。');
      }),
    );
    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请看原文',
    );
    expect(reply.text, '根据原文回答。');
    expect(reply.nextSteps, isEmpty);
    expect(requests, 2);
  });

  test('按消息编号合并历史，保留重复发出的正文并按图片哈希合并附件', () async {
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        final items = inputOf(body.cast<String, Object?>());
        final user = items.where((item) => item['role'] == 'user');
        expect(user, hasLength(3));
        expect(user.take(2).map((item) => item['content']), [
          '同样的问题',
          '同样的问题',
        ]);
        final content = (user.last['content'] as List).cast<Map>();
        expect(content.first['text'], '当前问题');
        expect(
          content.where((part) => part['type'] == 'input_image'),
          hasLength(2),
        );
        expect(
          user.any((item) => item['content'] == '历史里的当前问题'),
          isFalse,
        );
        return _chatReply(text: '继续回答。');
      }),
    );
    const first = ChatMessage(
      id: 'msg-1',
      conversationId: 'conv-2',
      role: MessageRole.user,
      content: '同样的问题',
    );
    const second = ChatMessage(
      id: 'msg-2',
      conversationId: 'conv-2',
      role: MessageRole.user,
      content: '同样的问题',
    );
    const current = ChatMessage(
      id: 'msg-3',
      conversationId: 'conv-2',
      role: MessageRole.user,
      content: '历史里的当前问题',
    );
    final reply = await service.ask(
      context: context(),
      history: const [first, first, second, current],
      text: '当前问题',
      inputMessageId: current.identity,
      images: [
        LlmImage(bytes: Uint8List.fromList([1, 2])),
        LlmImage(bytes: Uint8List.fromList([1, 2])),
        LlmImage(bytes: Uint8List.fromList([3])),
      ],
    );
    expect(reply.text, '继续回答。');
  });

  test('有效读取可以持续多步，提案去重后不挤掉不同做法', () async {
    const offsets = [8000, 0, 16000, 24000, 32000, 40000];
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        final body =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
        expect(body['tool_choice'], 'auto');
        final outputs = outputsIn(body);
        if (requests > 0) {
          final read = resultOf(outputs.last)['result'] as Map;
          final content = read['content'] as String;
          expect(read['offset'], offsets[requests - 1]);
          expect(content.runes.length, 8000);
          if (requests == 2) expect(content.endsWith('😀'), isTrue);
          if (requests == offsets.length) {
            expect(read['next_offset'], isNull);
            expect(read['note'], contains('本轮材料读取已达上限'));
          } else {
            expect(read['next_offset'], offsets[requests == 1 ? 2 : requests]);
          }
          if (requests == 1) {
            expect(outputs, hasLength(10));
          }
        }
        if (requests == offsets.length) {
          requests++;
          return _chatReply(text: '已根据材料回答。');
        }
        final step = requests++;
        return _chatReply(
          calls: [
            if (step == 0)
              for (var index = 0; index < 9; index++)
                _callItem('proposal_$index', proposeNextStepsTool, {
                  'steps': [
                    {'title': '核对定义', 'action': '读原文'},
                  ],
                }),
            if (step == 1)
              _callItem('another_proposal', proposeNextStepsTool, {
                'steps': [
                  {'title': '核对定义', 'action': '检验公式'},
                ],
              }),
            _callItem('read_$step', readMaterialPageTool, {
              'material_id': 'mat-2',
              'page_no': 7,
              'offset': offsets[step],
            }),
          ],
        );
      }),
    );

    final reply = await service.ask(
      context: BuddyContext(
        now: DateTime(2026, 11, 7),
        materialHits: [
          MaterialHit(
            materialId: 'mat-2',
            materialTitle: '概率论讲义',
            pageNo: 7,
            content: '${'甲' * 7999}😀${'乙' * 48000}',
            snippetText: '条件概率……',
          ),
        ],
      ),
      history: const [],
      text: '请读完相关原文后回答',
    );
    expect(requests, 7);
    expect(reply.text, '已根据材料回答。');
    expect(reply.nextSteps.map((step) => step.action), ['读原文', '检验公式']);
  });

  test('学习步骤参数错误时可根据工具结果修正，成功后不再请求正文', () async {
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        requests++;
        final body =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
        expect(body['tool_choice'], {
          'type': 'function',
          'name': proposeStudyStepsTool,
        });
        if (requests == 2) {
          final error = resultOf(outputsIn(body).last);
          expect(error['code'], 'invalid_args');
          expect(error['error'], contains('steps'));
        }
        return _chatReply(
          calls: [
            _callItem('plan_$requests', proposeStudyStepsTool, {
              'steps': [
                if (requests == 2)
                  {'title': '读定义', 'page_from': 7, 'page_to': 7},
              ],
            }),
          ],
        );
      }),
    );
    final reply = await service.ask(
      context: BuddyContext(now: DateTime(2026, 11, 7), mode: BuddyMode.plan),
      history: const [],
      text: '生成步骤',
    );
    expect(reply.text, isEmpty);
    expect(reply.studySteps.single.title, '读定义');
    expect(requests, 2);
  });

  test('学习步骤遗漏已选页面时回传页码并接受完整修正', () async {
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        if (++requests == 2) {
          final output = outputsIn(body.cast<String, Object?>()).last;
          expect(output['call_id'], 'plan_1');
          final error = resultOf(output);
          expect(error['code'], 'invalid_study_plan');
          expect(
            error['error'],
            '学习步骤没有覆盖第 8–9 页；本次范围共 3 页，最多 3 步，'
            '每一页只出现一次并连续覆盖，请重新提交完整方案',
          );
        }
        return _chatReply(
          calls: [
            _callItem('plan_$requests', proposeStudyStepsTool, {
              'steps': [
                {
                  'title': requests == 1 ? '漏页的方案' : '完整方案',
                  'page_from': 7,
                  'page_to': requests == 1 ? 7 : 9,
                },
              ],
            }),
          ],
        );
      }),
    );
    final reply = await service.ask(
      context: BuddyContext(
        now: DateTime(2026, 11, 7),
        mode: BuddyMode.plan,
        outlinePages: [
          for (final page in [7, 8, 9])
            MaterialPage(
              id: 'page-$page',
              materialId: 'mat-2',
              pageNo: page,
              content: '讲义',
            ),
        ],
      ),
      history: const [],
      text: '生成步骤',
    );
    expect(requests, 2);
    expect(reply.studySteps.single.title, '完整方案');
    expect(reply.studySteps.single.pageTo, 9);
  });

  test('按整份请求限制材料结果，并保留配对记录供最终回答', () async {
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        expect(body['max_output_tokens'], 2048);
        if (++requests == 1) {
          expect(body['tool_choice'], 'auto');
          return _chatReply(
            calls: [
              _callItem('first', readMaterialPageTool, {
                'material_id': 'mat-2',
                'page_no': 7,
              }),
              _callItem('second', readMaterialPageTool, {
                'material_id': 'mat-2',
                'page_no': 7,
                'offset': 8000,
              }),
            ],
          );
        }
        expect(body['tool_choice'], 'none');
        final outputs = outputsIn(body.cast<String, Object?>());
        expect(outputs.map((output) => output['call_id']), [
          'first',
          'second',
        ]);
        final first = resultOf(outputs.first)['result'] as Map;
        final length = (first['content'] as String).runes.length;
        expect(length, inInclusiveRange(1, 7999));
        expect(first['next_offset'], length);
        final second = resultOf(outputs.last)['result'] as Map;
        final secondLength = (second['content'] as String).runes.length;
        expect(second['offset'], 8000);
        expect(secondLength, inInclusiveRange(1, 96));
        expect(length + secondLength, lessThan(8192 - 2048));
        return _chatReply(text: '根据已读材料回答。');
      }),
    );
    final reply = await service.ask(
      context: BuddyContext(
        now: DateTime(2026, 11, 7),
        materialHits: [
          MaterialHit(
            materialId: 'mat-2',
            materialTitle: '长讲义',
            pageNo: 7,
            content: '甲' * 18000,
            snippetText: '讲义摘录',
          ),
        ],
      ),
      history: const [],
      text: '结合讲义回答',
      configSnapshot: const LlmConfigSnapshot(
        LlmConfig(endpoint: _testEndpoint, contextWindowTokens: 8192),
      ),
    );
    expect(requests, 2);
    expect(reply.text, '根据已读材料回答。');
  });

  test('原始问题已超出上下文预算时在发送前给出明确错误', () async {
    final service = await serviceWith(
      MockClient((request) async => throw StateError('超预算的请求被发出')),
    );
    await expectLater(
      service.ask(
        context: context(),
        history: const [],
        text: '甲' * 6000,
        configSnapshot: const LlmConfigSnapshot(
          LlmConfig(endpoint: _testEndpoint, contextWindowTokens: 4096),
        ),
      ),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.contextLimit,
        ),
      ),
    );
  });

  test('续接无法容纳整批结果时使用已有上下文，放弃这批提案', () async {
    var requests = 0;
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        if (++requests == 1) {
          expect(body['tool_choice'], 'auto');
          return _chatReply(
            calls: [
              _callItem('suggestion', proposeNextStepsTool, {
                'steps': [
                  {'title': '这批结果无法续接'},
                ],
              }),
              for (var index = 0; index < 60; index++)
                _callItem('page_$index', readMaterialPageTool, {
                  'material_id': 'mat-2',
                  'page_no': 7,
                }),
            ],
          );
        }
        expect(body['tool_choice'], 'none');
        final items = inputOf(body.cast<String, Object?>());
        expect(items.map((item) => item['role']), ['user']);
        return _chatReply(text: '根据已有资料回答。');
      }),
    );
    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请结合讲义回答',
      configSnapshot: const LlmConfigSnapshot(
        LlmConfig(endpoint: _testEndpoint, contextWindowTokens: 8192),
      ),
    );
    expect(requests, 2);
    expect(reply.text, '根据已有资料回答。');
    expect(reply.nextSteps, isEmpty);
  });

  test('第二步等待模型时可以停止，正文保留，第一步的提案丢弃', () async {
    final entered = Completer<void>();
    final aborted = Completer<void>();
    var requests = 0;
    final service = await serviceWith(
      MockClient.streaming((request, body) async {
        if (++requests == 1) {
          return http.StreamedResponse(
            Stream.value(
              _chatReply(
                text: '我先核对原文。',
                calls: [
                  _callItem('draft', proposeNextStepsTool, {
                    'steps': [
                      {'title': '读定义'},
                    ],
                  }),
                  _callItem('page', readMaterialPageTool, {
                    'material_id': 'mat-2',
                    'page_no': 7,
                  }),
                ],
              ).bodyBytes,
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        entered.complete();
        await (request as http.AbortableRequest).abortTrigger!;
        aborted.complete();
        return http.StreamedResponse(const Stream.empty(), 200);
      }),
    );
    final cancel = LlmCancelToken();
    final preview = <String>[];
    final pending = service.ask(
      context: withMaterial(),
      history: const [],
      text: '请看原文',
      onText: preview.add,
      cancelToken: cancel,
    );
    await entered.future;
    cancel.cancel();
    final reply = await pending;
    await aborted.future;
    expect(reply.stopped, isTrue);
    expect(reply.text, '我先核对原文。');
    expect(preview, ['我先核对原文。']);
    expect(reply.nextSteps, isEmpty);
    expect(requests, 2);
  });

  test('工具之后回退到普通请求时沿用同一步上下文', () async {
    final requests = <Map<String, Object?>>[];
    final service = await serviceWith(
      MockClient.streaming((request, body) async {
        requests.add(
          jsonDecode(utf8.decode(await body.toBytes())) as Map<String, Object?>,
        );
        return switch (requests.length) {
          1 || 3 || 4 => _streamedJson(
            switch (requests.length) {
              1 => chatReply(
                text: '先读讲义。',
                calls: [
                  _callItem('', readMaterialPageTool, {
                    'material_id': 'mat-2',
                    'page_no': 7,
                  }),
                  _callItem('call_zhixin_1', readMaterialPageTool, {
                    'material_id': 'mat-2',
                    'page_no': 8,
                  }),
                ],
              ),
              3 => chatReply(
                calls: [
                  _callItem('draft', proposeNextStepsTool, {
                    'steps': [
                      {'title': '读定义'},
                    ],
                  }),
                ],
              ),
              _ => chatReply(text: '按条件概率公式计算。'),
            },
          ),
          2 => http.StreamedResponse(
            Stream.value(utf8.encode('stream unsupported')),
            400,
          ),
          _ => throw StateError('多余的模型请求'),
        };
      }),
    );
    final preview = <String>[];
    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请看原文',
      onText: preview.add,
    );

    expect(requests, hasLength(4));
    expect(requests.map((body) => body['stream']), [true, true, null, null]);
    final continuation = inputOf(requests[1]);
    expect(requests[2]['input'], continuation);
    final calls = callsIn(requests[1]);
    expect(calls[1]['call_id'], 'call_zhixin_1');
    expect(calls[0]['call_id'], isNot(calls[1]['call_id']));
    expect(
      outputsIn(requests[1]).map((item) => item['call_id']),
      calls.map((call) => call['call_id']),
    );
    expect(
      (resultOf(outputsIn(requests[1]).first)['result'] as Map)['content'],
      contains(_hit.content),
    );
    final last = inputOf(requests.last);
    expect(last.take(continuation.length), continuation);
    expect(callsIn(requests.last), hasLength(3));
    expect(outputsIn(requests.last).last['call_id'], 'draft');
    expect(reply.text, '先读讲义。\n\n按条件概率公式计算。');
    expect(preview, ['先读讲义。', reply.text]);
    expect(reply.nextSteps.single.title, '读定义');
  });

  for (final streaming in [true, false]) {
    test('${streaming ? '流式' : '普通'}续接在工具参数中截断时保留前一步正文', () async {
      var requests = 0;
      Future<http.StreamedResponse> Function(http.BaseRequest) handler() =>
          (request) async {
            switch (++requests) {
              case 1:
                return _streamedJson(
                  chatReply(
                    text: '先读讲义。',
                    calls: [
                      _callItem('draft', proposeNextStepsTool, {
                        'steps': [
                          {'title': '读定义'},
                        ],
                      }),
                      _callItem('page', readMaterialPageTool, {
                        'material_id': 'mat-2',
                        'page_no': 7,
                      }),
                    ],
                  ),
                );
              case 2 when streaming:
                return _stream(
                  '${_textDelta('先看定义。')}'
                  '${_argumentsDelta(1, '{"steps": [')}'
                  '$_incomplete',
                );
              case 2:
                return _streamedJson(
                  {
                    'object': 'response',
                    'status': 'incomplete',
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'content': [
                          {'type': 'output_text', 'text': '先看定义。'},
                        ],
                      },
                    ],
                  },
                );
              default:
                throw StateError('截断后仍然请求模型');
            }
          };
      final service = await serviceWith(
        MockClient.streaming((request, body) => handler()(request)),
      );
      final preview = <String>[];
      final reply = await service.ask(
        context: withMaterial(),
        history: const [],
        text: '请看原文',
        onText: streaming ? preview.add : null,
      );
      expect(reply.text, '先读讲义。\n\n先看定义。');
      expect(reply.truncated, isTrue);
      expect(reply.interrupted, isFalse);
      expect(reply.nextSteps, isEmpty);
      expect(requests, 2);
    });
  }

  test('连接意外中止后保留正文并标记中断', () async {
    final service = await serviceWith(
      MockClient.streaming((request, body) async {
        final stream = Stream<List<int>>.multi((controller) {
          controller.add(utf8.encode(_textDelta('已收到的部分')));
          controller.addError(http.RequestAbortedException(request.url));
          controller.close();
        });
        return http.StreamedResponse(
          stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: (_) {},
      cancelToken: LlmCancelToken(),
    );
    expect(reply.text, '已收到的部分');
    expect(reply.interrupted, isTrue);
    expect(reply.interruptedReason, '网络不可用');
    expect(reply.stopped, isFalse);
  });

  test('流式回答边回调正文，结束后解析工具调用', () async {
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        return _stream(
          _streamReply(
            text: '边生成边显示',
            calls: [
              _callItem('call_1', proposeNextStepsTool, {
                'steps': [
                  {'title': '读定义'},
                ],
              }),
            ],
          ),
        );
      }),
    );

    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: partials.add,
    );

    expect(partials.last, '边生成边显示');
    expect(reply.text, '边生成边显示');
    expect(reply.nextSteps.single.title, '读定义');
  });

  test('工具参数损坏时保留已经流出的正文', () async {
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        return _stream(
          '${_textDelta('先看定义。')}'
          '${_argumentsDelta(1, '{"steps": [')}'
          '$_done',
        );
      }),
    );

    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: partials.add,
    );

    expect(reply.text, '先看定义。');
    expect(reply.nextSteps, isEmpty);
    expect(partials.last, '先看定义。');
  });

  test('达到长度上限时保留正文并丢掉工具调用', () async {
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        return _stream(
          '${_textDelta('先看定义。')}'
          '${_argumentsDelta(
            1,
            '{"steps":[{"title":"读定义"}]}',
          )}'
          '$_incomplete',
        );
      }),
    );

    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: partials.add,
    );

    expect(reply.text, '先看定义。');
    expect(reply.truncated, isTrue);
    expect(reply.nextSteps, isEmpty);
    expect(partials.last, '先看定义。');
  });

  test('调用方传入配置快照时不再读取存储', () async {
    final secrets = _MemorySecrets();
    final service = AiChatService(
      store: LlmConfigStore(secrets),
      httpClient: MockClient((request) async {
        return _chatReply(text: '使用同一份配置');
      }),
    );

    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      configSnapshot: const LlmConfigSnapshot(
        LlmConfig(endpoint: _testEndpoint, apiKey: 'sk-test'),
      ),
    );

    expect(reply.text, '使用同一份配置');
    expect(secrets.reads, 0);
  });

  test('流式请求在正文前失败时按普通请求补一次', () async {
    var streaming = 0;
    var complete = 0;
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        final body = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        if (body['stream'] == true) {
          streaming++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('unexpected')),
            400,
            headers: {'content-type': 'text/plain'},
          );
        }
        complete++;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(chatReply(text: '普通回答')))),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: partials.add,
    );

    expect(streaming, 1);
    expect(complete, 1);
    expect(partials, isEmpty);
    expect(reply.text, '普通回答');
  });

  test('流已经给出正文后失败时保留已经显示的部分', () async {
    var calls = 0;
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        calls++;
        return _stream(
          '${_textDelta('半截')}'
          'event: error\n'
          'data: {"type":"error","error":{"message":"服务中断"}}\n\n',
        );
      }),
    );

    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      onText: partials.add,
    );

    expect(calls, 1);
    expect(partials, ['半截']);
    expect(reply.text, '半截');
    expect(reply.interrupted, isTrue);
    expect(reply.interruptedReason, '模型服务出错');
  });

  test('停止生成时中止请求并返回已经显示的部分', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        final abortable = request as http.AbortableRequest;
        controller.add(utf8.encode(_textDelta('半截')));
        abortable.abortTrigger!.then((_) {
          // 停止由取消令牌通知客户端；这里只把响应的流收尾，不再塞进错误，
          // 否则客户端停止订阅之后这条错误会变成没人处理的异步异常。
          if (controller.isClosed) return;
          controller.close();
        });
        return http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

    final cancel = LlmCancelToken();
    final partials = <String>[];
    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      cancelToken: cancel,
      onText: (text) {
        partials.add(text);
        cancel.cancel();
      },
    );

    expect(partials, ['半截']);
    expect(reply.stopped, isTrue);
    expect(reply.text, '半截');
  });

  test('讨论历史按字数预算带入，不再固定只取 12 条', () async {
    Map<String, Object?>? captured;
    final service = await serviceWith(
      MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, Object?>;
        return _chatReply(text: '收到');
      }),
    );
    final history = [
      for (var index = 0; index < 30; index++)
        ChatMessage(
          id: 'msg-${index + 1}',
          conversationId: 'conv-1',
          role: index.isEven ? MessageRole.user : MessageRole.assistant,
          content: '第 $index 条消息',
        ),
    ];

    await service.ask(context: context(), history: history, text: '继续');

    final items = inputOf(captured!);
    // 系统提示放在 instructions，input 里是 30 条历史与本次提问。
    expect(items, hasLength(31));
    expect(captured!['instructions'], isNotEmpty);
    expect(items[0]['content'], '第 0 条消息');
    expect(items[29]['content'], '第 29 条消息');
    expect(items.last['content'], '继续');
  });

  test('讨论历史超出字数预算时保留最近消息和第一条用户消息', () async {
    Map<String, Object?>? captured;
    final service = await serviceWith(
      MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, Object?>;
        return _chatReply(text: '收到');
      }),
    );
    final long = '内容' * 500;
    final history = [
      for (var index = 0; index < 30; index++)
        ChatMessage(
          id: 'msg-${index + 1}',
          conversationId: 'conv-1',
          role: index.isEven ? MessageRole.user : MessageRole.assistant,
          content: '$index $long',
        ),
    ];

    await service.ask(context: context(), history: history, text: '继续');

    final items = inputOf(captured!);
    expect(items.length, lessThan(31));
    // 原问题仍然排在最前面，最近一条讨论紧挨着本次提问。
    expect(items[0]['content'], startsWith('0 '));
    expect(items[items.length - 2]['content'], startsWith('29 '));
  });

  test('讨论历史里的工具交换按条目带回', () async {
    Map<String, Object?>? captured;
    final service = await serviceWith(
      MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, Object?>;
        return _chatReply(text: '收到');
      }),
    );
    await service.ask(
      context: context(),
      history: const [
        ChatMessage(
          id: 'msg-8',
          conversationId: 'conv-1',
          role: MessageRole.assistant,
          content: '',
        ),
        ChatMessage(
          id: 'tool-result:plan',
          conversationId: 'conv-1',
          role: MessageRole.system,
          content: '{"result":"旧一轮的工具结果"}',
        ),
        ChatMessage(
          id: 'msg-9',
          conversationId: 'conv-1',
          role: MessageRole.user,
          content: '继续',
        ),
      ],
      text: '再看一遍',
    );
    final items = inputOf(captured!);
    // 旧一轮的讨论历史只有正文，工具交换来自当轮进程内的上下文。
    expect(items.map((item) => item['role']), ['user', 'user']);
    expect(
      items.where((item) => item['type'] == 'function_call_output'),
      isEmpty,
    );
  });

  test('连接测试要求模型真的返回工具调用', () async {
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['tools'], isA<List>());
        return _jsonReply(
          chatReply(
            calls: [
              _callItem('call_probe', 'submit_probe', {
                'input': [
                  {'type': 'input_text', 'text': '{"ok":true}'},
                ],
              }),
            ],
          ),
        );
      }),
    );

    final duration = await service.test(
      const LlmConfig(endpoint: _testEndpoint, apiKey: 'sk-test'),
    );
    expect(duration, isA<Duration>());
  });

  test('连接测试拒绝无法解析的工具参数', () async {
    final service = await serviceWith(
      MockClient((request) async {
        return _jsonReply(
          chatReply(
            calls: [(_callItem('call_probe', 'submit_probe', {})..['arguments'] = '{')],
          ),
        );
      }),
    );

    await expectLater(
      service.test(const LlmConfig(endpoint: _testEndpoint, apiKey: 'sk-test')),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.toolUnsupported,
        ),
      ),
    );
  });

  test('连接测试没有工具调用时报告不支持', () async {
    final service = await serviceWith(
      MockClient((request) async {
        return _chatReply(text: 'ok');
      }),
    );

    await expectLater(
      service.test(const LlmConfig(endpoint: _testEndpoint, apiKey: 'sk-test')),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.toolUnsupported,
        ),
      ),
    );
  });

  test('本地规则回答不进入模型历史，重答时只带用户说过的话', () {
    ChatMessage message(
      String id,
      MessageRole role,
      String content, {
      bool? model,
    }) {
      return ChatMessage(
        id: id,
        conversationId: 'conv-1',
        role: role,
        content: content,
        payload: model == null ? null : ChatMessagePayload(fromModel: model),
      );
    }

    final history = selectBuddyHistory([
      message('msg-1', MessageRole.user, '第一问'),
      message('msg-2', MessageRole.assistant, '本地兜底的一段话', model: false),
      message('msg-3', MessageRole.user, '第二问'),
      message('msg-4', MessageRole.assistant, '模型回答', model: true),
    ]);

    expect(history.map((item) => item.id), ['msg-1', 'msg-3', 'msg-4']);
    // 旧记录的助手消息没有来源标记，仍然作为历史保留。
    final legacy = selectBuddyHistory([
      message('msg-1', MessageRole.user, '第一问'),
      message('msg-2', MessageRole.assistant, '旧回答'),
    ]);
    expect(legacy.map((item) => item.id), ['msg-1', 'msg-2']);
  });

  test('模型拒绝工具声明时用首轮证据普通请求回答', () async {
    var plainRequests = 0;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final tools = body['tools'];
      if (tools is List && tools.isNotEmpty) {
        return http.Response(
          jsonEncode({
            'error': {'message': 'tools are not supported'},
          }),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      plainRequests++;
      return _chatReply(text: '依据本轮摘录回答条件概率。');
    });
    final service = await serviceWith(client);
    final reply = await service.ask(
      context: BuddyContext(
        now: DateTime(2026, 11, 7, 20),
        evidence: [
          EvidenceHit(
            kind: EvidenceKind.materialPage,
            identity: 'material_page:mat-1:3',
            title: '《概率论讲义》第 3 页',
            snippet: '条件概率 P(A|B)=P(AB)/P(B)。',
            matchedText: '条件概率',
            literal: false,
            score: Score.clamp(0.5),
            location: const EvidenceLocation(materialId: 'mat-1', pageNo: 3),
            text: '条件概率 P(A|B)=P(AB)/P(B)。',
          ),
        ],
      ),
      history: const [],
      text: '条件概率怎么算',
    );

    expect(reply.text, '依据本轮摘录回答条件概率。');
    // 400 不在重试范围里，整轮工具请求失败一次之后才走普通请求。
    expect(plainRequests, 1);
  });
}
