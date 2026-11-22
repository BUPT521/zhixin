import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';

/// 测试用的假地址：客户端只用配置里的完整接口地址发请求。
const String _testEndpoint = 'https://zhixin.test/v1/llm';

void main() {
  HttpLlmClient clientReturning(String body) {
    return HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
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
    LlmConfig config = const LlmConfig(
      endpoint: _testEndpoint,
      apiKey: 'test-key',
    ),
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

  for (final sendsHeartbeat in [true, false]) {
    test(sendsHeartbeat ? '心跳不延长首个有效事件期限' : '响应头之后断线可重试同一步', () async {
      final requests = <String>[];
      final aborted = Completer<void>();
      final client = HttpLlmClient(
        config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
        budget: LlmRequestBudget(
          firstOutputTimeout: const Duration(milliseconds: 150),
        ),
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
        config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
        budget: LlmRequestBudget(
          idleTimeout: const Duration(milliseconds: 120),
        ),
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

  test('首字超时按超时返回，两次尝试都用同一份预算', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      budget: LlmRequestBudget(
        firstOutputTimeout: const Duration(milliseconds: 60),
      ),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, body) async {
        requests++;
        final stream = StreamController<List<int>>();
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then(
            (_) => unawaited(stream.close()),
          ),
        );
        return http.StreamedResponse(
          stream.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.timeout)
            .having((error) => error.detail, 'detail', contains('首个有效事件')),
      ),
    );
    // 首字超时在流式判据里可重试一次，两次都超时才向调用方报错。
    expect(requests, 2);
  });

  test('正文之后的空闲超时按超时返回，已经显示的部分保留', () async {
    var requests = 0;
    final aborted = Completer<void>();
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      budget: LlmRequestBudget(idleTimeout: const Duration(milliseconds: 80)),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, body) async {
        requests++;
        final stream = StreamController<List<int>>();
        stream.add(utf8.encode(event(sseChunk('已经显示的正文'))));
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then((_) {
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
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.timeout)
            .having((error) => error.detail, 'detail', contains('有效事件之间')),
      ),
    );
    await aborted.future;
    expect(deltas.map((delta) => delta.text).join(), '已经显示的正文');
    // 已经给出正文之后不重试。
    expect(requests, 1);
  });

  test('用户取消时按已取消返回，不算超时也不重试', () async {
    final cancelled = LlmCancelToken();
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      budget: LlmRequestBudget(cancelToken: cancelled),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, body) async {
        requests++;
        final stream = StreamController<List<int>>();
        stream.add(utf8.encode(event(sseChunk('已经显示的正文'))));
        unawaited(
          (request as http.AbortableRequest).abortTrigger!.then(
            (_) => unawaited(stream.close()),
          ),
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
            if (delta.text.isNotEmpty) cancelled.cancel();
            return delta;
          })
          .drain<void>(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.cancelled,
        ),
      ),
    );
    expect(deltas.map((delta) => delta.text).join(), '已经显示的正文');
    expect(requests, 1);
  });

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
      config: const LlmConfig(
        endpoint: _testEndpoint,
        model: 'deepseek-flash',
        apiKey: 'test-key',
      ),
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

  test('模型名不是 DeepSeek 时不发思考模式字段', () async {
    Map<String, Object?>? sent;
    final client = HttpLlmClient(
      config: const LlmConfig(
        endpoint: _testEndpoint,
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
    expect(sent!['max_tokens'], isNotNull);
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
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
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
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
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

  test('整段请求遇到服务端错误重试一次', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('busy', 500);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '重试成功'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final reply = await client.complete(
      system: 's',
      messages: const [LlmMessage(role: 'user', content: 'hi')],
    );
    expect(reply.text, '重试成功');
    expect(calls, 2);
  });

  test('整段请求只重试一次，连续两次服务端错误后报告失败', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        return http.Response('busy', 503);
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
          LlmFailure.server,
        ),
      ),
    );
    expect(calls, 2);
  });

  test('整段请求遇到 4xx 不重试', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        return http.Response(
          '{"error":{"message":"额度不足"}}',
          429,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await expectLater(
      client.complete(
        system: 's',
        messages: const [LlmMessage(role: 'user', content: 'hi')],
      ),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.rateLimited)
            .having((error) => error.detail, 'detail', '额度不足'),
      ),
    );
    expect(calls, 1);
  });

  test('整段请求遇到网络错误重试一次后报告离线', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        throw http.ClientException('connection refused');
      }),
    );
    await expectLater(
      client.complete(
        system: 's',
        messages: const [LlmMessage(role: 'user', content: 'hi')],
      ),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.offline)
            .having((error) => error.detail, 'detail', 'connection refused'),
      ),
    );
    expect(calls, 2);
  });

  test('整段请求超时不重试', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      budget: LlmRequestBudget(timeout: const Duration(milliseconds: 40)),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
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
          LlmFailure.timeout,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('整段请求的内容错误不重试', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '半截'},
                'finish_reason': 'content_filter',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
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
          LlmFailure.server,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('流式请求遇到 4xx 不重试', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"额度不足"}}')),
          429,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.rateLimited)
            .having((error) => error.detail, 'detail', '额度不足'),
      ),
    );
    expect(calls, 1);
  });

  test('流式请求只重试一次', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('busy')),
          500,
          headers: {'content-type': 'text/plain'},
        );
      }),
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.server,
        ),
      ),
    );
    expect(calls, 2);
  });

  test('流式请求在首个有效事件前结束时只重试一次', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await expectLater(
      client
          .stream(
            system: 's',
            messages: const [LlmMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.offline,
        ),
      ),
    );
    expect(calls, 2);
  });

  test('流式请求给出正文后不再重试服务端错误', () async {
    var calls = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        calls++;
        final body =
            event(sseChunk('半截')) +
            event(
              jsonEncode({
                'error': {'message': '服务出错'},
              }),
            );
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
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
          LlmFailure.server,
        ),
      ),
    );
    expect(calls, 1);
    expect(deltas.single.text, '半截');
  });
}
