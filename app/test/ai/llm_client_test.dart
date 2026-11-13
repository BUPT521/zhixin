import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';

void main() {
  HttpLlmClient clientReturning(String body) {
    return HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(body),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  }

  String sseChunk(String content, {String? finishReason}) => jsonEncode({
    'choices': [
      {
        'delta': {'content': content},
        'finish_reason': finishReason,
      },
    ],
  });

  String sseToolChunk(
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

  HttpLlmClient rawStreamingClient(
    String body, {
    int status = 200,
    String contentType = 'text/event-stream',
    LlmConfig config = const LlmConfig(apiKey: 'test-key'),
  }) {
    return HttpLlmClient(
      config: config,
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          status,
          headers: {'content-type': contentType},
        );
      }),
    );
  }

  HttpLlmClient streamingClient(
    List<String> payloads, {
    int status = 200,
    String contentType = 'text/event-stream',
  }) => rawStreamingClient(
    payloads.map((payload) => 'data: $payload\n\n').join(),
    status: status,
    contentType: contentType,
  );

  String event(String json) => 'data: $json\n\n';

  const responsesConfig = LlmConfig(
    api: LlmApi.responses,
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-test',
    apiKey: 'test-key',
  );
  const anthropicConfig = LlmConfig(
    api: LlmApi.anthropic,
    baseUrl: 'https://api.anthropic.com',
    model: 'claude-test',
    apiKey: 'test-key',
  );

  for (final sendsHeartbeat in [true, false]) {
    test(sendsHeartbeat ? '心跳不延长首个有效事件期限' : '响应头之后断线可重试同一步', () async {
      final requests = <String>[];
      final aborted = Completer<void>();
      final client = HttpLlmClient(
        config: const LlmConfig(apiKey: 'test-key'),
        firstOutputTimeout: const Duration(milliseconds: 150),
        retryDelay: Duration.zero,
        httpClient: MockClient.streaming((request, body) async {
          requests.add(utf8.decode(await body.toBytes()));
          if (requests.length == 1) {
            final stream = StreamController<List<int>>();
            final heartbeats = sendsHeartbeat
                ? Timer.periodic(const Duration(milliseconds: 20), (_) {
                    stream.add(utf8.encode(': heartbeat\n\n'));
                  })
                : null;
            if (!sendsHeartbeat) {
              stream.addError(http.ClientException('connection closed'));
            }
            final abort = (request as http.AbortableRequest).abortTrigger!;
            unawaited(
              abort.then((_) {
                heartbeats?.cancel();
                aborted.complete();
                unawaited(stream.close());
              }),
            );
            return http.StreamedResponse(
              stream.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          expect(aborted.isCompleted, isTrue);
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(event(sseChunk('重试成功', finishReason: 'stop'))),
            ),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final result = await client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList();
      expect(requests, hasLength(2));
      expect(requests[0], requests[1]);
      expect(result.map((delta) => delta.text).join(), '重试成功');
    });
  }

  for (final toolOnly in [true, false]) {
    test(toolOnly ? '收到工具参数后断线直接报告中断' : '正文后的心跳不延长流空闲期限', () async {
      var requests = 0;
      final aborted = Completer<void>();
      final client = HttpLlmClient(
        config: const LlmConfig(apiKey: 'test-key'),
        streamIdleTimeout: const Duration(milliseconds: 120),
        retryDelay: Duration.zero,
        httpClient: MockClient.streaming((request, body) async {
          requests++;
          final stream = StreamController<List<int>>();
          final chunk = toolOnly
              ? sseToolChunk(0, id: 'call_1', name: 'read', arguments: '{')
              : sseChunk('已经显示的正文');
          stream.add(utf8.encode(event(chunk)));
          final heartbeats = toolOnly
              ? null
              : Timer.periodic(const Duration(milliseconds: 20), (_) {
                  stream.add(utf8.encode(': heartbeat\n\n'));
                });
          if (toolOnly) {
            stream.addError(http.ClientException('connection closed'));
          }
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then((_) {
              heartbeats?.cancel();
              aborted.complete();
              unawaited(stream.close());
            }),
          );
          return http.StreamedResponse(
            stream.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final deltas = <LlmDelta>[];
      await expectLater(
        client
            .stream(
              system: 's',
              messages: const [LlmMessage(role: 'user', content: 'hi')],
            )
            .map((delta) {
              deltas.add(delta);
              return delta;
            })
            .drain<void>(),
        throwsA(
          isA<LlmException>().having(
            (error) => error.failure,
            'failure',
            toolOnly ? LlmFailure.offline : LlmFailure.timeout,
          ),
        ),
      );
      await aborted.future;
      expect(requests, 1);
      expect(deltas, hasLength(1));
      if (toolOnly) {
        expect(deltas.single.toolCalls.single.arguments, '{');
      } else {
        expect(deltas.single.text, '已经显示的正文');
      }
    });
  }

  test('正常回答返回文本与用量', () async {
    final client = clientReturning(
      jsonEncode({
        'choices': [
          {
            'message': {'content': ' 你好 '},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
      }),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, '你好');
    expect(reply.toolCalls, isEmpty);
    expect(reply.tokensIn, 3);
    expect(reply.tokensOut, 2);
  });

  test('整段回答可以没有正文，只返回工具调用', () async {
    final client = clientReturning(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'propose_next_steps',
                    'arguments': '{"steps":[{"title":"读定义"}]}',
                  },
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      }),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, isEmpty);
    expect(reply.toolCalls.single.name, 'propose_next_steps');
    expect(reply.toolCalls.single.arguments, contains('读定义'));
  });

  test('整段回答达到长度上限时保留正文并标记截断', () async {
    final client = clientReturning(
      jsonEncode({
        'choices': [
          {
            'message': {'content': '{"reply":"半截'},
            'finish_reason': 'length',
          },
        ],
      }),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, '{"reply":"半截');
    expect(reply.truncated, isTrue);
    expect(reply.toolCalls, isEmpty);
  });

  test('整段回答没有正文又达到长度上限时按截断失败', () async {
    final client = clientReturning(
      jsonEncode({
        'choices': [
          {
            'message': {'content': null},
            'finish_reason': 'length',
          },
        ],
      }),
    );
    await expectLater(
      client.complete(
        system: 's',
        messages: const [LlmMessage(role: 'user', content: 'hi')],
      ),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.truncated,
        ),
      ),
    );
  });

  test('空内容按格式错误报告', () async {
    final client = clientReturning(
      jsonEncode({
        'choices': [
          {
            'message': {'content': ''},
            'finish_reason': 'stop',
          },
        ],
      }),
    );
    await expectLater(
      client.complete(
        system: 's',
        messages: const [LlmMessage(role: 'user', content: 'hi')],
      ),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.badResponse,
        ),
      ),
    );
  });

  test('请求按现行接口带上工具、用量与关掉的思考模式', () async {
    Map<String, Object?>? sent;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        final text = [
          sseChunk('你'),
          sseChunk('好', finishReason: 'stop'),
          '[DONE]',
        ].map((payload) => 'data: $payload\n\n').join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final parts = <String>[];
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
      tools: const [
        LlmTool(
          name: 'propose_next_steps',
          description: '提交建议',
          parameters: {'type': 'object'},
        ),
      ],
      forceTool: 'propose_next_steps',
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts, ['你', '好']);
    expect(sent!['stream'], isTrue);
    expect(sent!['stream_options'], {'include_usage': true});
    expect(sent!['thinking'], {'type': 'disabled'});
    expect(sent!['max_tokens'], isNotNull);
    expect(sent!.containsKey('max_completion_tokens'), isFalse);
    expect(sent!.containsKey('response_format'), isFalse);
    final tools = sent!['tools'] as List;
    expect((tools.single as Map)['type'], 'function');
    expect(
      ((sent!['tool_choice'] as Map)['function'] as Map)['name'],
      'propose_next_steps',
    );
  });

  test('非 DeepSeek 地址不发思考模式字段', () async {
    Map<String, Object?>? sent;
    final client = HttpLlmClient(
      config: const LlmConfig(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        apiKey: 'test-key',
      ),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode('data: ${sseChunk('好', finishReason: 'stop')}\n\n'),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await client
        .stream(
          system: 's',
          messages: const [LlmMessage(role: 'user', content: 'hi')],
        )
        .toList();
    expect(sent!.containsKey('thinking'), isFalse);
    expect(sent!.containsKey('max_tokens'), isFalse);
    expect(sent!['max_completion_tokens'], isNotNull);
  });

  test('事件按 SSE 规范拼行：BOM、注释、event 字段与多行 data 都不丢', () async {
    final client = rawStreamingClient(
      '\uFEFFdata: ${sseChunk('你')}\r\n'
      '\r\n'
      ': keepalive\r\n'
      '\r\n'
      'event: message\r\n'
      'data: {"choices":\r\n'
      'data: [{"delta":{"content":"好"},"finish_reason":"stop"}]}\r\n'
      '\r\n'
      'data: [DONE]\r\n'
      '\r\n',
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['你', '好']);
    expect(truncated, isFalse);
  });

  test('正文是内容块数组时按顺序拼起来', () async {
    final client = streamingClient([
      jsonEncode({
        'choices': [
          {
            'delta': {
              'content': [
                {'type': 'text', 'text': '你'},
                {'type': 'text', 'text': '好'},
              ],
            },
            'finish_reason': 'stop',
          },
        ],
      }),
      '[DONE]',
    ]);
    final parts = <String>[];
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts.join(), '你好');
  });

  test('思考模式下的推理内容不进入正文', () async {
    final client = streamingClient([
      jsonEncode({
        'choices': [
          {
            'delta': {'reasoning_content': '先算一步', 'content': '你好'},
            'finish_reason': 'stop',
          },
        ],
      }),
      '[DONE]',
    ]);
    final parts = <String>[];
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts, ['你好']);
  });

  test('流式工具参数按 index 分片到达，可以并行调用', () async {
    final client = streamingClient([
      sseToolChunk(
        0,
        id: 'call_a',
        name: 'propose_next_steps',
        arguments: '{"steps":[',
      ),
      sseToolChunk(
        1,
        id: 'call_b',
        name: 'propose_citations',
        arguments: '{"citations":[',
      ),
      sseToolChunk(0, arguments: '{"title":"读定义"}]}'),
      sseToolChunk(
        1,
        arguments: '{"material_id":1,"page_no":2,"quote":"原文"}]}',
      ),
      '[DONE]',
    ]);
    final deltas = await client
        .stream(
          system: 's',
          messages: const [LlmMessage(role: 'user', content: 'hi')],
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {'type': 'object'},
            ),
            LlmTool(
              name: 'propose_citations',
              description: '提交引用',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .toList();
    final args = <int, StringBuffer>{};
    for (final delta in deltas) {
      for (final call in delta.toolCalls) {
        args.putIfAbsent(call.index, StringBuffer.new).write(call.arguments);
      }
    }
    expect(args[0].toString(), '{"steps":[{"title":"读定义"}]}');
    expect(
      args[1].toString(),
      '{"citations":[{"material_id":1,"page_no":2,"quote":"原文"}]}',
    );
  });

  test('工具调用没有 index 时按数组位置区分', () async {
    final client = streamingClient([
      jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'id': 'call_a',
                  'function': {'name': 'propose_next_steps', 'arguments': '{}'},
                },
                {
                  'id': 'call_b',
                  'function': {'name': 'propose_citations', 'arguments': '{}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      }),
      '[DONE]',
    ]);
    final calls = await client
        .stream(
          system: 's',
          messages: const [LlmMessage(role: 'user', content: 'hi')],
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {'type': 'object'},
            ),
            LlmTool(
              name: 'propose_citations',
              description: '提交引用',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .expand((delta) => delta.toolCalls)
        .toList();
    expect(calls.map((call) => call.index), [0, 1]);
    expect(calls.first.name, 'propose_next_steps');
    expect(calls.last.name, 'propose_citations');
  });

  test('流式回答只有工具调用时不报错', () async {
    final client = streamingClient([
      sseToolChunk(
        0,
        id: 'call_1',
        name: 'propose_next_steps',
        arguments: '{"steps":[]}',
        finishReason: 'tool_calls',
      ),
      '[DONE]',
    ]);
    final deltas = await client
        .stream(
          system: 's',
          messages: const [LlmMessage(role: 'user', content: 'hi')],
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .toList();
    expect(deltas.single.toolCalls.single.name, 'propose_next_steps');
  });

  test('流式回答达到长度上限时保留正文并标记截断', () async {
    final client = streamingClient([
      sseChunk('半截', finishReason: 'length'),
      '[DONE]',
    ]);
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['半截']);
    expect(truncated, isTrue);
  });

  test('推理资源不足时保留正文并标记截断', () async {
    final client = streamingClient([
      sseChunk('半截', finishReason: 'insufficient_system_resource'),
      '[DONE]',
    ]);
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['半截']);
    expect(truncated, isTrue);
  });

  test('流式回答没有正文又达到长度上限时按截断失败', () async {
    final client = streamingClient([
      sseChunk('', finishReason: 'length'),
      '[DONE]',
    ]);
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.truncated,
        ),
      ),
    );
  });

  test('内容被过滤时按服务端错误报告', () async {
    final client = streamingClient([
      sseChunk('半截', finishReason: 'content_filter'),
      '[DONE]',
    ]);
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.server,
        ),
      ),
    );
  });

  test('流既没有 [DONE] 也没有结束原因时按截断报告', () async {
    final client = streamingClient([
      jsonEncode({
        'choices': [
          {
            'delta': {'content': '半截'},
          },
        ],
      }),
    ]);
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['半截']);
    expect(truncated, isTrue);
  });

  test('只有 [DONE] 没有正文与工具调用时按格式错误报告', () async {
    final client = streamingClient(['[DONE]']);
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.badResponse,
        ),
      ),
    );
  });

  test('非 2xx 时把服务端说明带进错误里', () async {
    final client = rawStreamingClient(
      jsonEncode({
        'error': {'message': 'Insufficient Balance', 'type': 'auth'},
      }),
      status: 401,
      contentType: 'application/json',
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.auth)
            .having((error) => error.detail, 'detail', 'Insufficient Balance'),
      ),
    );
  });

  test('服务端忽略 stream 时按整段回答读出', () async {
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        final body = jsonEncode({
          'choices': [
            {
              'message': {
                'content': '整段回答',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'propose_next_steps',
                      'arguments': '{"steps":[]}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        });
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final deltas = await client
        .stream(
          system: 's',
          messages: const [LlmMessage(role: 'user', content: 'hi')],
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .toList();
    expect(deltas.first.text, '整段回答');
    expect(deltas.last.toolCalls.single.name, 'propose_next_steps');
  });

  test('流式请求遇到服务端错误重试一次', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        calls++;
        if (calls == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('busy')),
            500,
            headers: {'content-type': 'text/plain'},
          );
        }
        final text =
            'data: ${sseChunk('好', finishReason: 'stop')}\n\ndata: [DONE]\n\n';
        return http.StreamedResponse(
          Stream.value(utf8.encode(text)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final parts = <String>[];
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts, ['好']);
    expect(calls, 2);
  });
  String? headerOf(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  test('三种接口的地址拼接与配置往返', () {
    const chat = LlmConfig(apiKey: 'k');
    expect(chat.endpoint, 'https://api.deepseek.com/v1/chat/completions');

    const root = LlmConfig(baseUrl: 'https://api.deepseek.com', apiKey: 'k');
    expect(root.endpoint, 'https://api.deepseek.com/v1/chat/completions');

    const responses = LlmConfig(
      api: LlmApi.responses,
      baseUrl: 'https://api.openai.com',
      apiKey: 'k',
    );
    expect(responses.endpoint, 'https://api.openai.com/v1/responses');

    const anthropic = LlmConfig(
      api: LlmApi.anthropic,
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'k',
    );
    expect(anthropic.endpoint, 'https://api.anthropic.com/v1/messages');

    const deepseekAnthropic = LlmConfig(
      api: LlmApi.anthropic,
      baseUrl: 'https://api.deepseek.com/anthropic',
      apiKey: 'k',
    );
    expect(
      deepseekAnthropic.endpoint,
      'https://api.deepseek.com/anthropic/v1/messages',
    );

    expect(LlmConfig.fromJson(chat.toJson()).api, LlmApi.chat);
    expect(LlmConfig.fromJson(responses.toJson()).api, LlmApi.responses);
    expect(LlmConfig.fromJson(anthropic.toJson()).api, LlmApi.anthropic);
    expect(LlmConfig.fromJson(const {}).api, LlmApi.chat);
  });

  test('Responses：请求按 instructions、input 与 tools 组装', () async {
    Map<String, Object?>? sent;
    Map<String, String>? headers;
    final client = HttpLlmClient(
      config: responsesConfig,
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        headers = request.headers;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              event(
                jsonEncode({
                  'type': 'response.completed',
                  'response': {
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'message',
                        'content': [
                          {'type': 'output_text', 'text': '收到'},
                        ],
                      },
                    ],
                  },
                }),
              ),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final parts = <String>[];
    await for (final delta in client.stream(
      system: '你是知新',
      messages: [
        const LlmMessage(role: 'user', content: '这是什么'),
        LlmMessage(
          role: 'user',
          content: '看图',
          images: [
            LlmImage(bytes: Uint8List.fromList([1, 2, 3])),
          ],
        ),
        const LlmMessage(role: 'assistant', content: '上一轮回答'),
      ],
      tools: const [
        LlmTool(
          name: 'propose_next_steps',
          description: '提交建议',
          parameters: {'type': 'object'},
        ),
      ],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts.join(), '收到');
    expect(sent!['instructions'], '你是知新');
    expect(sent!['max_output_tokens'], 8192);
    expect(sent!['stream'], isTrue);
    expect(sent!.containsKey('temperature'), isFalse);
    expect(sent!['store'], isFalse);
    expect(sent!['tool_choice'], 'auto');
    final input = sent!['input'] as List;
    expect(((input[0] as Map)['content'] as List).first['type'], 'input_text');
    final image = ((input[1] as Map)['content'] as List)[1] as Map;
    expect(image['type'], 'input_image');
    expect(image['image_url'], startsWith('data:image/jpeg;base64,'));
    expect(((input[2] as Map)['content'] as List).first['type'], 'output_text');
    final tool = (sent!['tools'] as List).single as Map;
    expect(tool['type'], 'function');
    expect(tool['strict'], false);
    expect(tool.containsKey('function'), isFalse);
    expect(headerOf(headers!, 'authorization'), 'Bearer test-key');
  });

  test('Responses：正文增量之后只补没发过的后缀', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({'type': 'response.output_text.delta', 'delta': '前半'}),
        ),
        event(
          jsonEncode({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': '前半后半'},
                  ],
                },
              ],
            },
          }),
        ),
      ].join(),
      config: responsesConfig,
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts.join(), '前半后半');
    expect(truncated, isFalse);
  });

  test('Responses：工具调用按 item 归并参数', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'id': 'fc_1',
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'propose_next_steps',
              'arguments': '',
            },
          }),
        ),
        event(
          jsonEncode({
            'type': 'response.function_call_arguments.delta',
            'item_id': 'fc_1',
            'delta': '{"steps":',
          }),
        ),
        event(
          jsonEncode({
            'type': 'response.function_call_arguments.delta',
            'item_id': 'fc_1',
            'delta': '[{"title":"读定义"}]}',
          }),
        ),
        event(
          jsonEncode({
            'type': 'response.completed',
            'response': {'status': 'completed', 'output': []},
          }),
        ),
      ].join(),
      config: responsesConfig,
    );
    final args = <int, StringBuffer>{};
    final names = <int, String?>{};
    final ids = <int, String?>{};
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
      tools: const [
        LlmTool(
          name: 'propose_next_steps',
          description: '提交建议',
          parameters: {'type': 'object'},
        ),
      ],
    )) {
      if (delta.truncated) truncated = true;
      for (final call in delta.toolCalls) {
        args.putIfAbsent(call.index, StringBuffer.new).write(call.arguments);
        names[call.index] = call.name ?? names[call.index];
        ids[call.index] = call.id ?? ids[call.index];
      }
    }
    expect(args[0].toString(), '{"steps":[{"title":"读定义"}]}');
    expect(names[0], 'propose_next_steps');
    expect(ids[0], 'call_1');
    expect(truncated, isFalse);
  });

  test('Responses：没有增量时用收尾的 output 补齐正文与工具', () async {
    final client = rawStreamingClient(
      event(
        jsonEncode({
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '完整回答'},
                ],
              },
              {
                'type': 'function_call',
                'id': 'fc_1',
                'call_id': 'call_1',
                'name': 'propose_next_steps',
                'arguments': '{"steps":[{"title":"读定义"}]}',
              },
            ],
          },
        }),
      ),
      config: responsesConfig,
    );
    final parts = <String>[];
    final args = <int, StringBuffer>{};
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
      tools: const [
        LlmTool(
          name: 'propose_next_steps',
          description: '提交建议',
          parameters: {'type': 'object'},
        ),
      ],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      for (final call in delta.toolCalls) {
        args.putIfAbsent(call.index, StringBuffer.new).write(call.arguments);
      }
    }
    expect(parts.join(), '完整回答');
    expect(args[0].toString(), '{"steps":[{"title":"读定义"}]}');
  });

  test('Responses：incomplete 按截断保留正文', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({'type': 'response.output_text.delta', 'delta': '半截'}),
        ),
        event(
          jsonEncode({
            'type': 'response.incomplete',
            'response': {'status': 'incomplete', 'output': []},
          }),
        ),
      ].join(),
      config: responsesConfig,
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts.join(), '半截');
    expect(truncated, isTrue);
  });

  test('Responses：failed 与 error 事件按服务端错误报告', () async {
    final failed = rawStreamingClient(
      event(
        jsonEncode({
          'type': 'response.failed',
          'response': {
            'status': 'failed',
            'error': {'message': '模型崩了'},
          },
        }),
      ),
      config: responsesConfig,
    );
    await expectLater(
      failed
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.server)
            .having((error) => error.detail, 'detail', '模型崩了'),
      ),
    );

    final error = rawStreamingClient(
      event(jsonEncode({'type': 'error', 'message': '限流了'})),
      config: responsesConfig,
    );
    await expectLater(
      error
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>().having((item) => item.detail, 'detail', '限流了'),
      ),
    );
  });

  test('Responses：整段响应解出正文、工具与用量', () async {
    final client = HttpLlmClient(
      config: responsesConfig,
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': ' 好的 '},
                  ],
                },
                {
                  'type': 'function_call',
                  'id': 'fc_1',
                  'call_id': 'call_1',
                  'name': 'propose_next_steps',
                  'arguments': '{"steps":[]}',
                },
              ],
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, '好的');
    expect(reply.toolCalls.single.name, 'propose_next_steps');
    expect(reply.toolCalls.single.id, 'call_1');
    expect(reply.tokensIn, 10);
    expect(reply.tokensOut, 5);
    expect(reply.truncated, isFalse);
  });

  test('Anthropic：请求发 x-api-key 与 messages 块', () async {
    Map<String, Object?>? sent;
    Map<String, String>? headers;
    final client = HttpLlmClient(
      config: anthropicConfig,
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        headers = request.headers;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              [
                event(
                  jsonEncode({
                    'type': 'content_block_delta',
                    'index': 0,
                    'delta': {'type': 'text_delta', 'text': '好'},
                  }),
                ),
                event(jsonEncode({'type': 'message_stop'})),
              ].join(),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await client
        .stream(
          system: '你是知新',
          messages: [
            LlmMessage(
              role: 'user',
              content: '看图',
              images: [
                LlmImage(bytes: Uint8List.fromList([1, 2, 3])),
              ],
            ),
            const LlmMessage(role: 'assistant', content: '上一轮回答'),
          ],
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .toList();
    expect(headerOf(headers!, 'x-api-key'), 'test-key');
    expect(headerOf(headers!, 'anthropic-version'), '2023-06-01');
    expect(headerOf(headers!, 'authorization'), isNull);
    expect(sent!['system'], '你是知新');
    expect(sent!['max_tokens'], 8192);
    expect(sent!.containsKey('temperature'), isFalse);
    final messages = sent!['messages'] as List;
    final userBlocks = (messages[0] as Map)['content'] as List;
    expect((userBlocks[0] as Map)['type'], 'text');
    final image = userBlocks[1] as Map;
    expect(image['type'], 'image');
    expect((image['source'] as Map)['type'], 'base64');
    expect((image['source'] as Map)['media_type'], 'image/jpeg');
    expect(((messages[1] as Map)['content'] as List).first['type'], 'text');
    final tool = (sent!['tools'] as List).single as Map;
    expect(tool['name'], 'propose_next_steps');
    expect(tool['input_schema'], {'type': 'object'});
    expect(sent!['tool_choice'], {'type': 'auto'});
  });

  test('Anthropic：正文增量到 message_stop 结束', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 3},
            },
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '你'},
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '好'},
          }),
        ),
        event(
          jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 2},
          }),
        ),
        event(jsonEncode({'type': 'message_stop'})),
        '[DONE]',
      ].join(),
      config: anthropicConfig,
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts.join(), '你好');
    expect(truncated, isFalse);
  });

  test('Anthropic：工具参数按 input_json_delta 拼接', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': '先记一下'},
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'propose_next_steps',
              'input': {},
            },
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"steps":'},
          }),
        ),
        event(
          jsonEncode({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '[{"title":"读定义"}]}',
            },
          }),
        ),
        event(
          jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          }),
        ),
        event(jsonEncode({'type': 'message_stop'})),
      ].join(),
      config: anthropicConfig,
    );
    final parts = <String>[];
    final args = <int, StringBuffer>{};
    final names = <int, String?>{};
    final ids = <int, String?>{};
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
      tools: const [
        LlmTool(
          name: 'propose_next_steps',
          description: '提交建议',
          parameters: {'type': 'object'},
        ),
      ],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      for (final call in delta.toolCalls) {
        args.putIfAbsent(call.index, StringBuffer.new).write(call.arguments);
        names[call.index] = call.name ?? names[call.index];
        ids[call.index] = call.id ?? ids[call.index];
      }
    }
    expect(parts.join(), '先记一下');
    expect(args[0].toString(), '{"steps":[{"title":"读定义"}]}');
    expect(names[0], 'propose_next_steps');
    expect(ids[0], 'toolu_1');
  });

  test('Anthropic：max_tokens 结束按截断保留正文', () async {
    final client = rawStreamingClient(
      [
        event(
          jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '半截'},
          }),
        ),
        event(
          jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'max_tokens'},
          }),
        ),
        event(jsonEncode({'type': 'message_stop'})),
      ].join(),
      config: anthropicConfig,
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts.join(), '半截');
    expect(truncated, isTrue);
  });

  test('Anthropic：错误事件按类型映射', () async {
    final client = rawStreamingClient(
      event(
        jsonEncode({
          'type': 'error',
          'error': {'type': 'rate_limit_error', 'message': '太快了'},
        }),
      ),
      config: anthropicConfig,
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.rateLimited)
            .having((error) => error.detail, 'detail', '太快了'),
      ),
    );
  });

  test('Anthropic：没有 message_stop 的流按截断报告', () async {
    final client = rawStreamingClient(
      event(
        jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': '半截'},
        }),
      ),
      config: anthropicConfig,
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    )) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts.join(), '半截');
    expect(truncated, isTrue);
  });

  test('Anthropic：整段响应解出正文、工具与用量', () async {
    final client = HttpLlmClient(
      config: anthropicConfig,
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': '好的'},
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'propose_next_steps',
                  'input': {'steps': []},
                },
              ],
              'stop_reason': 'tool_use',
              'usage': {'input_tokens': 7, 'output_tokens': 3},
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, '好的');
    expect(reply.toolCalls.single.id, 'toolu_1');
    expect(reply.toolCalls.single.arguments, '{"steps":[]}');
    expect(reply.tokensIn, 7);
    expect(reply.tokensOut, 3);
  });
}
