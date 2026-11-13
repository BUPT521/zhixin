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
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/material.dart';

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

String _delta(String text) => jsonEncode({
  'choices': [
    {
      'delta': {'content': text},
      'finish_reason': null,
    },
  ],
});

String _toolDelta(
  int index, {
  String? id,
  String? name,
  String arguments = '',
  String? finishReason,
}) => jsonEncode({
  'choices': [
    {
      'delta': {
        'tool_calls': [
          {
            'index': index,
            'id': ?id,
            'function': {'name': ?name, 'arguments': arguments},
          },
        ],
      },
      'finish_reason': finishReason,
    },
  ],
});

http.Response _jsonReply(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _chatReply({String? text, List<Object?> calls = const []}) =>
    _jsonReply({
      'choices': [
        {
          'message': {'content': text, 'tool_calls': calls},
          'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
        },
      ],
    });

Map<String, Object?> _chatCall(String id, String name, Object arguments) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

const _hit = MaterialHit(
  materialId: 2,
  materialTitle: '概率论讲义',
  pageNo: 7,
  content: '这是正文里的条件概率公式。',
  snippetText: '条件概率……',
);

void main() {
  Future<AiChatService> serviceWith(http.Client client) async {
    final store = LlmConfigStore(_MemorySecrets());
    await store.save(const LlmConfig(apiKey: 'sk-test'));
    return AiChatService(store: store, httpClient: client);
  }

  BuddyContext context() => BuddyContext(now: DateTime(2026, 11, 7, 20));

  BuddyContext withMaterial() =>
      BuddyContext(now: DateTime(2026, 11, 7, 20), materialHits: const [_hit]);

  for (final api in LlmApi.values) {
    test('${api.label}：材料原文、拒绝结果和提案按调用编号回传', () async {
      const calls = [
        (
          id: 'call_page',
          name: readMaterialPageTool,
          args: {'material_id': 2, 'page_no': 7},
        ),
        (
          id: 'call_denied',
          name: readMaterialPageTool,
          args: {'material_id': 2, 'page_no': 8},
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
      const reasoning = {
        'type': 'reasoning',
        'id': 'rs_123',
        'summary': [],
        'encrypted_content': 'test-reasoning',
      };
      final captured = <Map<String, Object?>>[];
      final service = await serviceWith(
        MockClient((request) async {
          captured.add(
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>,
          );
          if (captured.length == 1) {
            if (api == LlmApi.responses) {
              expect(captured.single['store'], isFalse);
              expect(captured.single['include'], [
                'reasoning.encrypted_content',
              ]);
            }
            return switch (api) {
              LlmApi.chat => _chatReply(
                calls: [
                  for (final call in calls)
                    _chatCall(call.id, call.name, call.args),
                ],
              ),
              LlmApi.responses => http.Response(
                [
                  {'type': 'response.output_item.done', 'item': reasoning},
                  {
                    'type': 'response.function_call_arguments.delta',
                    'item_id': 'fc_call_page',
                    'delta': '{"material_id":',
                  },
                  {
                    'type': 'response.completed',
                    'response': {
                      'status': 'completed',
                      'output': [
                        for (final call in calls)
                          {
                            'type': 'function_call',
                            'id': 'fc_${call.id}',
                            'call_id': call.id,
                            'name': call.name,
                            'arguments': jsonEncode(call.args),
                          },
                      ],
                    },
                  },
                ].map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              ),
              LlmApi.anthropic => _jsonReply({
                'stop_reason': 'tool_use',
                'content': [
                  for (final call in calls)
                    {
                      'type': 'tool_use',
                      'id': call.id,
                      'name': call.name,
                      'input': call.args,
                    },
                ],
              }),
            };
          }
          return switch (api) {
            LlmApi.chat => _chatReply(text: '按公式计算。'),
            LlmApi.responses => _jsonReply({
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': '按公式计算。'},
                  ],
                },
              ],
            }),
            LlmApi.anthropic => _jsonReply({
              'content': [
                {'type': 'text', 'text': '按公式计算。'},
              ],
            }),
          };
        }),
      );

      final preview = <String>[];
      final reply = await service.ask(
        context: withMaterial(),
        history: const [],
        text: '请看原文',
        configSnapshot: LlmConfigSnapshot(
          LlmConfig(
            api: api,
            baseUrl: 'https://api.openai.com',
            model: 'test-model',
            apiKey: 'sk-test',
          ),
        ),
        onText: api == LlmApi.responses ? preview.add : null,
      );
      expect(reply.text, '按公式计算。');
      expect(reply.nextSteps.single.title, '阅读定义');
      expect(captured, hasLength(2));
      expect(jsonEncode(captured.first), isNot(contains(_hit.content)));

      final second = captured.last;
      final messages =
          (second[api == LlmApi.responses ? 'input' : 'messages'] as List)
              .cast<Map>();
      late Iterable<Map> invocations;
      late Iterable<Map> results;
      late String resultId;
      late String resultText;
      switch (api) {
        case LlmApi.chat:
          invocations =
              (messages.singleWhere(
                        (message) => message['role'] == 'assistant',
                      )['tool_calls']
                      as List)
                  .cast<Map>();
          results = messages.where((message) => message['role'] == 'tool');
          resultId = 'tool_call_id';
          resultText = 'content';
        case LlmApi.responses:
          expect(second['store'], isFalse);
          expect(second['include'], ['reasoning.encrypted_content']);
          expect(
            messages.singleWhere((item) => item['type'] == 'reasoning'),
            reasoning,
          );
          expect(preview, ['按公式计算。']);
          invocations = messages.where(
            (message) => message['type'] == 'function_call',
          );
          results = messages.where(
            (message) => message['type'] == 'function_call_output',
          );
          resultId = 'call_id';
          resultText = 'output';
        case LlmApi.anthropic:
          invocations = (messages[messages.length - 2]['content'] as List)
              .cast<Map>();
          expect(messages.last['role'], 'user');
          results = (messages.last['content'] as List).cast<Map>();
          expect(results.elementAt(1)['is_error'], isTrue);
          resultId = 'tool_use_id';
          resultText = 'content';
      }
      final ids = calls.map((call) => call.id);
      expect(
        invocations.map(
          (call) => call[api == LlmApi.responses ? 'call_id' : 'id'],
        ),
        ids,
      );
      expect(results.map((result) => result[resultId]), ids);
      final page = jsonDecode(results.first[resultText] as String)['result'];
      expect(page['content'], _hit.content);
      expect(
        jsonDecode(results.elementAt(1)[resultText] as String),
        contains('error'),
      );
      expect(jsonDecode(results.last[resultText] as String)['result'], '已暂存提案');
    });
  }

  test('重复读取已返回的范围只回传位置，连续无进展后收束正文', () async {
    var requests = 0;
    String? contentId;
    final service = await serviceWith(
      MockClient((request) async {
        requests++;
        final body =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
        final messages = (body['messages'] as List).cast<Map>();
        if (requests == 2) {
          final result =
              jsonDecode(messages.last['content'] as String)['result'] as Map;
          contentId = result['content_id'] as String;
          expect(contentId, startsWith('material:'));
        }
        if (requests > 2) {
          final result =
              jsonDecode(messages.last['content'] as String)['result'] as Map;
          expect(result['offset'], 0);
          expect(result['content_id'], contentId);
          expect(result['note'], contains('已在本轮返回'));
          expect(result.containsKey('content'), isFalse);
          final calls = messages.where(
            (message) => message['role'] == 'assistant',
          );
          expect(
            calls
                .expand(
                  (message) =>
                      (message['tool_calls'] as List).map((call) => call['id']),
                )
                .toSet(),
            hasLength(requests - 1),
          );
        }
        if (requests == 4) {
          expect(body['tool_choice'], 'none');
          expect(body['tools'], isNotEmpty);
          return _chatReply(text: '根据已有原文回答。');
        }
        expect(body['tool_choice'], 'auto');
        return _chatReply(
          calls: [
            if (requests == 1)
              _chatCall('call_reused', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
                'offset': 0,
              }),
            _chatCall('call_reused', readMaterialPageTool, {
              'material_id': 2,
              'page_no': 7,
              'offset': requests - 1,
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
              _chatCall('shared', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
                'offset': -1,
              }),
              _chatCall('shared', proposeNextStepsTool, {
                'steps': [
                  {'title': '编号冲突的建议'},
                ],
              }),
              _chatCall('denied', proposeStudyStepsTool, {'steps': []}),
              _chatCall('', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
              }),
            ],
          );
        }
        final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
        final messages = (body['messages'] as List).cast<Map>();
        final assistant = messages.singleWhere(
          (item) => item['role'] == 'assistant',
        );
        final ids = (assistant['tool_calls'] as List)
            .map((item) => (item as Map)['id'])
            .toList();
        final results = messages
            .where((item) => item['role'] == 'tool')
            .toList();
        expect(ids.toSet(), hasLength(4));
        expect(results.map((item) => item['tool_call_id']), ids);
        final content = results
            .map((item) => jsonDecode(item['content'] as String) as Map)
            .toList();
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
        final messages = (body['messages'] as List).cast<Map>();
        final user = messages.where((message) => message['role'] == 'user');
        expect(user, hasLength(3));
        expect(user.take(2).map((message) => message['content']), [
          '同样的问题',
          '同样的问题',
        ]);
        final content = (user.last['content'] as List).cast<Map>();
        expect(content.first['text'], '当前问题');
        expect(
          content.where((part) => part['type'] == 'image_url'),
          hasLength(2),
        );
        expect(
          user.any((message) => message['content'] == '历史里的当前问题'),
          isFalse,
        );
        return _chatReply(text: '继续回答。');
      }),
    );
    const first = ChatMessage(
      id: 1,
      conversationId: 2,
      role: 'user',
      content: '同样的问题',
    );
    const second = ChatMessage(
      id: 2,
      conversationId: 2,
      role: 'user',
      content: '同样的问题',
    );
    const current = ChatMessage(
      id: 3,
      conversationId: 2,
      role: 'user',
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
        final messages = (body['messages'] as List).cast<Map>();
        expect(body['tool_choice'], 'auto');
        if (requests > 0) {
          final read =
              jsonDecode(messages.last['content'] as String)['result'] as Map;
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
            final toolResults = messages.where(
              (message) => message['role'] == 'tool',
            );
            expect(toolResults, hasLength(10));
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
                _chatCall('proposal_$index', proposeNextStepsTool, {
                  'steps': [
                    {'title': '核对定义', 'action': '读原文'},
                  ],
                }),
            if (step == 1)
              _chatCall('another_proposal', proposeNextStepsTool, {
                'steps': [
                  {'title': '核对定义', 'action': '检验公式'},
                ],
              }),
            _chatCall('read_$step', readMaterialPageTool, {
              'material_id': 2,
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
            materialId: 2,
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
          'function': {'name': proposeStudyStepsTool},
        });
        if (requests == 2) {
          final messages = body['messages'] as List;
          final error = jsonDecode(messages.last['content'] as String) as Map;
          expect(error['code'], 'invalid_args');
          expect(error['error'], contains('steps'));
        }
        return _chatReply(
          calls: [
            _chatCall('plan_$requests', proposeStudyStepsTool, {
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
          final messages = body['messages'] as List;
          expect(messages.last['tool_call_id'], 'plan_1');
          final error = jsonDecode(messages.last['content'] as String) as Map;
          expect(error['code'], 'invalid_study_plan');
          expect(error['error'], '学习步骤没有覆盖第 8–9 页，请重新提交完整方案');
        }
        return _chatReply(
          calls: [
            _chatCall('plan_$requests', proposeStudyStepsTool, {
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
            MaterialPage(id: page, materialId: 2, pageNo: page, content: '讲义'),
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
        expect(body['max_tokens'], 2048);
        if (++requests == 1) {
          expect(body['tool_choice'], 'auto');
          return _chatReply(
            calls: [
              _chatCall('first', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
              }),
              _chatCall('second', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
                'offset': 8000,
              }),
            ],
          );
        }
        expect(body['tool_choice'], 'none');
        final messages = (body['messages'] as List).cast<Map>();
        final results = messages.where((message) => message['role'] == 'tool');
        expect(results.map((message) => message['tool_call_id']), [
          'first',
          'second',
        ]);
        final first =
            jsonDecode(results.first['content'] as String)['result'] as Map;
        final length = (first['content'] as String).runes.length;
        expect(length, inInclusiveRange(1, 7999));
        expect(first['next_offset'], length);
        final second =
            jsonDecode(results.last['content'] as String)['result'] as Map;
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
            materialId: 2,
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
        LlmConfig(apiKey: 'sk-test', contextWindowTokens: 8192),
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
          LlmConfig(apiKey: 'sk-test', contextWindowTokens: 4096),
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
              _chatCall('suggestion', proposeNextStepsTool, {
                'steps': [
                  {'title': '这批结果无法续接'},
                ],
              }),
              for (var index = 0; index < 60; index++)
                _chatCall('page_$index', readMaterialPageTool, {
                  'material_id': 2,
                  'page_no': 7,
                }),
            ],
          );
        }
        expect(body['tool_choice'], 'none');
        final messages = (body['messages'] as List).cast<Map>();
        expect(messages.map((item) => item['role']), ['system', 'user']);
        return _chatReply(text: '根据已有资料回答。');
      }),
    );
    final reply = await service.ask(
      context: withMaterial(),
      history: const [],
      text: '请结合讲义回答',
      configSnapshot: const LlmConfigSnapshot(
        LlmConfig(apiKey: 'sk-test', contextWindowTokens: 8192),
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
                  _chatCall('draft', proposeNextStepsTool, {
                    'steps': [
                      {'title': '读定义'},
                    ],
                  }),
                  _chatCall('page', readMaterialPageTool, {
                    'material_id': 2,
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
      MockClient((request) async {
        requests.add(
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>,
        );
        return switch (requests.length) {
          1 => _chatReply(
            text: '先读讲义。',
            calls: [
              _chatCall('', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 7,
              }),
              _chatCall('call_zhixin_1', readMaterialPageTool, {
                'material_id': 2,
                'page_no': 8,
              }),
            ],
          ),
          2 => http.Response('stream unsupported', 400),
          3 => _chatReply(
            calls: [
              _chatCall('draft', proposeNextStepsTool, {
                'steps': [
                  {'title': '读定义'},
                ],
              }),
            ],
          ),
          4 => _chatReply(text: '按条件概率公式计算。'),
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
    final continuation = (requests[1]['messages'] as List).cast<Map>();
    expect(requests[2]['messages'], continuation);
    final calls = (continuation[2]['tool_calls'] as List).cast<Map>();
    expect(calls[1]['id'], 'call_zhixin_1');
    expect(calls[0]['id'], isNot(calls[1]['id']));
    expect(
      continuation.skip(3).map((message) => message['tool_call_id']),
      calls.map((call) => call['id']),
    );
    expect(continuation[3]['content'], contains(_hit.content));
    final last = requests.last['messages'] as List;
    expect(last.take(continuation.length), continuation);
    expect(last, hasLength(continuation.length + 2));
    expect(last.last['tool_call_id'], 'draft');
    expect(reply.text, '先读讲义。\n\n按条件概率公式计算。');
    expect(preview, ['先读讲义。', reply.text]);
    expect(reply.nextSteps.single.title, '读定义');
  });

  for (final streaming in [true, false]) {
    test('${streaming ? '流式' : '普通'}续接在工具参数中截断时保留前一步正文', () async {
      var requests = 0;
      final service = await serviceWith(
        MockClient((request) async {
          switch (++requests) {
            case 1:
              return _chatReply(
                text: '先读讲义。',
                calls: [
                  _chatCall('draft', proposeNextStepsTool, {
                    'steps': [
                      {'title': '读定义'},
                    ],
                  }),
                  _chatCall('page', readMaterialPageTool, {
                    'material_id': 2,
                    'page_no': 7,
                  }),
                ],
              );
            case 2 when streaming:
              final chunk = _toolDelta(
                0,
                id: 'cut',
                name: proposeNextStepsTool,
                arguments: '{"steps": [',
                finishReason: 'length',
              );
              return http.Response(
                'data: $chunk\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            case 2:
              return _jsonReply({
                'choices': [
                  {
                    'message': {'content': null},
                    'finish_reason': 'length',
                  },
                ],
              });
            default:
              throw StateError('截断后仍然请求模型');
          }
        }),
      );
      final preview = <String>[];
      final reply = await service.ask(
        context: withMaterial(),
        history: const [],
        text: '请看原文',
        onText: streaming ? preview.add : null,
      );
      expect(reply.text, '先读讲义。');
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
          controller.add(utf8.encode('data: ${_delta('已收到的部分')}\n\n'));
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
        final text = [
          'data: ${_delta('边生成')}\n\n',
          'data: ${_delta('边显示')}\n\n',
          'data: ${_toolDelta(0, id: 'call_1', name: proposeNextStepsTool, arguments: '{"steps":[{"title":"读定义"}]}')}\n\n',
          'data: [DONE]\n\n',
        ].join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
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

    expect(partials, ['边生成', '边生成边显示']);
    expect(reply.text, '边生成边显示');
    expect(reply.nextSteps.single.title, '读定义');
  });

  test('工具参数损坏时保留已经流出的正文', () async {
    final service = await serviceWith(
      MockClient.streaming((request, bodyStream) async {
        final text = [
          'data: ${_delta('先看定义。')}\n\n',
          'data: ${_toolDelta(0, id: 'call_1', name: proposeNextStepsTool, arguments: '{"steps": [')}\n\n',
          'data: [DONE]\n\n',
        ].join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
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
        final text = [
          'data: ${_delta('先看定义。')}\n\n',
          'data: ${_toolDelta(0, id: 'call_1', name: proposeNextStepsTool, arguments: '{"steps":[{"title":"读定义"}]}', finishReason: 'length')}\n\n',
          'data: [DONE]\n\n',
        ].join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
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
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '使用同一份配置'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final reply = await service.ask(
      context: context(),
      history: const [],
      text: '你好',
      configSnapshot: const LlmConfigSnapshot(LlmConfig(apiKey: 'sk-test')),
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
          Stream.value(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '普通回答'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
            ),
          ),
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
        final text = [
          'data: ${_delta('半截')}\n\n',
          'data: ${jsonEncode({
            'error': {'message': '服务中断'},
          })}\n\n',
        ].join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
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
        controller.add(utf8.encode('data: ${_delta('半截')}\n\n'));
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
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '收到'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final history = [
      for (var index = 0; index < 30; index++)
        ChatMessage(
          id: index + 1,
          conversationId: 1,
          role: index.isEven ? 'user' : 'assistant',
          content: '第 $index 条消息',
        ),
    ];

    await service.ask(context: context(), history: history, text: '继续');

    final messages = (captured!['messages'] as List)
        .cast<Map<String, Object?>>();
    // 第一条是系统提示，之后是 30 条历史与本次提问。
    expect(messages, hasLength(32));
    expect(messages[1]['content'], '第 0 条消息');
    expect(messages[30]['content'], '第 29 条消息');
    expect(messages.last['content'], '继续');
  });

  test('讨论历史超出字数预算时保留最近消息和第一条用户消息', () async {
    Map<String, Object?>? captured;
    final service = await serviceWith(
      MockClient((request) async {
        captured = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '收到'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final long = '内容' * 500;
    final history = [
      for (var index = 0; index < 30; index++)
        ChatMessage(
          id: index + 1,
          conversationId: 1,
          role: index.isEven ? 'user' : 'assistant',
          content: '$index $long',
        ),
    ];

    await service.ask(context: context(), history: history, text: '继续');

    final messages = (captured!['messages'] as List)
        .cast<Map<String, Object?>>();
    expect(messages.length, lessThan(31));
    // 系统提示之后，原问题仍然排在最前面，最近一条讨论紧挨着本次提问。
    expect(messages[1]['content'], startsWith('0 '));
    expect(messages[messages.length - 2]['content'], startsWith('29 '));
  });

  test('连接测试要求模型真的返回工具调用', () async {
    final service = await serviceWith(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['tools'], isA<List>());
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call_probe',
                      'type': 'function',
                      'function': {
                        'name': 'submit_probe',
                        'arguments': '{"ok":true}',
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final duration = await service.test(const LlmConfig(apiKey: 'sk-test'));
    expect(duration, isA<Duration>());
  });

  test('连接测试拒绝无法解析的工具参数', () async {
    final service = await serviceWith(
      MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call_probe',
                      'type': 'function',
                      'function': {'name': 'submit_probe', 'arguments': '{'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      service.test(const LlmConfig(apiKey: 'sk-test')),
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
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      service.test(const LlmConfig(apiKey: 'sk-test')),
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
    ChatMessage message(int id, String role, String content, {bool? model}) {
      return ChatMessage(
        id: id,
        conversationId: 1,
        role: role,
        content: content,
        structuredJson: model == null ? null : jsonEncode({'model': model}),
      );
    }

    final history = selectBuddyHistory([
      message(1, 'user', '第一问'),
      message(2, 'assistant', '本地兜底的一段话', model: false),
      message(3, 'user', '第二问'),
      message(4, 'assistant', '模型回答', model: true),
    ]);

    expect(history.map((item) => item.id), [1, 3, 4]);
    // 旧记录的助手消息没有来源标记，仍然作为历史保留。
    final legacy = selectBuddyHistory([
      message(1, 'user', '第一问'),
      message(2, 'assistant', '旧回答'),
    ]);
    expect(legacy.map((item) => item.id), [1, 2]);
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
            identity: 'material_page:1:3',
            title: '《概率论讲义》第 3 页',
            snippet: '条件概率 P(A|B)=P(AB)/P(B)。',
            matchedText: '条件概率',
            literal: false,
            score: 10,
            location: const EvidenceLocation(materialId: 1, pageNo: 3),
            text: '条件概率 P(A|B)=P(AB)/P(B)。',
          ),
        ],
      ),
      history: const [],
      text: '条件概率怎么算',
    );

    expect(reply.text, '依据本轮摘录回答条件概率。');
    expect(plainRequests, 1);
  });
}
