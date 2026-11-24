import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';
import 'package:zhixin/ai/llm_protocol.dart';
import 'package:zhixin/ai/llm_reply_reader.dart';

/// 测试用的假地址：客户端只用配置里的完整接口地址发请求。
const String _testEndpoint = 'https://zhixin.test/v1/llm/responses';

const _hi = [LlmMessage(role: 'user', content: 'hi')];

/// 用 [LlmReplyReader] 读一次流式回答，按序号汇总工具调用：编号、工具名与
/// 参数。只读一次流；模拟流只能响应一次，所以不连续读第二个模型步骤。
Future<List<(String, String, String)>> _readToolCalls(LlmClient client) async {
  final ids = <int, String>{};
  final names = <int, String>{};
  final args = <int, StringBuffer>{};
  final reader = LlmReplyReader(
    client: client,
    system: 's',
    tools: const [],
    budget: LlmRequestBudget(),
  );
  await for (final delta in client.stream(system: 's', messages: _hi)) {
    for (final call in delta.toolCalls) {
      if (call.id case final id? when id.isNotEmpty) ids[call.index] = id;
      if (call.name case final name? when name.isNotEmpty) {
        names[call.index] = name;
      }
      final buffer = args.putIfAbsent(call.index, StringBuffer.new);
      if (call.replaceArguments) buffer.clear();
      buffer.write(call.arguments);
    }
  }
  // 读取器本身不在这里使用，保留构造是为了让两处共用同一份判据。
  expect(reader, isNotNull);
  final indexes = {...ids.keys, ...names.keys, ...args.keys}.toList()..sort();
  return [
    for (final index in indexes)
      (ids[index] ?? '', names[index] ?? '', args[index]?.toString() ?? ''),
  ];
}

void main() {
  Map<String, Object?> response({
    String? text,
    String status = 'completed',
    List<Map<String, Object?>> calls = const [],
    Map<String, Object?>? usage,
  }) => {
    'object': 'response',
    'status': status,
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
    'usage': ?usage,
  };

  Map<String, Object?> call(String id, String name, Object arguments) => {
    'type': 'function_call',
    'call_id': id,
    'name': name,
    'arguments': jsonEncode(arguments),
  };

  String event(String name, Map<String, Object?> payload) =>
      'event: $name\ndata: ${jsonEncode(payload)}\n\n';

  String textDelta(String text, {int index = 0}) =>
      event('response.output_text.delta', {
        'type': 'response.output_text.delta',
        'output_index': index,
        'delta': text,
      });

  String argumentsDelta(int index, String delta) =>
      event('response.function_call_arguments.delta', {
        'type': 'response.function_call_arguments.delta',
        'output_index': index,
        'delta': delta,
      });

  String itemDone(Map<String, Object?> item, {int index = 1}) => event(
    'response.output_item.done',
    {'type': 'response.output_item.done', 'output_index': index, 'item': item},
  );

  String completed() => event('response.completed', {
    'type': 'response.completed',
    'response': {'id': 'resp_1', 'status': 'completed'},
  });

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

  HttpLlmClient rawStreamingClient(
    String body, {
    int status = 200,
    String contentType = 'text/event-stream',
    LlmConfig config = const LlmConfig(
      endpoint: _testEndpoint,
      apiKey: 'test-key',
    ),
    Duration retryDelay = const Duration(milliseconds: 600),
  }) {
    return HttpLlmClient(
      config: config,
      retryDelay: retryDelay,
      httpClient: MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          status,
          headers: {'content-type': contentType},
        );
      }),
    );
  }

  HttpLlmClient streamingClient(List<String> events) =>
      rawStreamingClient(events.join());

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
            Stream.value(utf8.encode('${textDelta('重试成功')}${completed()}')),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final result = await client.stream(system: 's', messages: _hi).toList();
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
          stream.add(
            utf8.encode(
              toolOnly ? argumentsDelta(1, '{"steps":') : textDelta('已经显示的正文'),
            ),
          );
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
        client.stream(system: 's', messages: _hi).map((delta) {
          deltas.add(delta);
          return delta;
        }).drain<void>(),
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
        expect(deltas.single.toolCalls.single.arguments, '{"steps":');
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
      client.stream(system: 's', messages: _hi).drain<void>(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.timeout)
            .having((error) => error.detail, 'detail', contains('首个有效事件')),
      ),
    );
    // 首字超时在流式判据里可重试一次，两次都超时才向调用方报错。
    expect(requests, 2);
  });

  test('请求带上本轮剩余预算，重试时剩下的更少', () async {
    final budgets = <String?>[];
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      budget: LlmRequestBudget(timeout: const Duration(seconds: 30)),
      retryDelay: const Duration(milliseconds: 40),
      httpClient: MockClient.streaming((request, body) async {
        budgets.add(request.headers['X-Zhixin-Round-Budget-Ms']);
        if (budgets.length == 1) {
          throw http.ClientException('connection closed');
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('${textDelta('好了')}${completed()}')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final result = await client.stream(system: 's', messages: _hi).toList();
    expect(result.map((delta) => delta.text).join(), '好了');
    expect(budgets, hasLength(2));
    final first = int.parse(budgets.first!);
    final second = int.parse(budgets.last!);
    // 整轮预算 30 秒，单位是毫秒；两次尝试共用一个截止时间，所以后一次更少。
    expect(first, greaterThan(second));
    expect(first, lessThanOrEqualTo(30000));
    expect(second, greaterThan(0));
  });

  test('请求带上讨论标识，没有归属时不带', () async {
    Future<String?> headerFor(LlmRequestBudget? template) async {
      String? session;
      final client = HttpLlmClient(
        config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
        budget: template,
        httpClient: MockClient.streaming((request, body) async {
          session = request.headers['X-Zhixin-Session-Id'];
          return http.StreamedResponse(
            Stream.value(utf8.encode('${textDelta('好')}${completed()}')),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      await client.stream(system: 's', messages: _hi).drain<void>();
      return session;
    }

    // 构造时给的期限模板每次请求会重启一份，讨论标识要跟着一起带过去。
    expect(
      await headerFor(LlmRequestBudget(sessionId: 'discussion-7')),
      'discussion-7',
    );
    expect(await headerFor(null), isNull);
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
        stream.add(utf8.encode(textDelta('已经显示的正文')));
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
      client.stream(system: 's', messages: _hi).map((delta) {
        deltas.add(delta);
        return delta;
      }).drain<void>(),
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
        stream.add(utf8.encode(textDelta('已经显示的正文')));
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
      client.stream(system: 's', messages: _hi).map((delta) {
        deltas.add(delta);
        if (delta.text.isNotEmpty) cancelled.cancel();
        return delta;
      }).drain<void>(),
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
      jsonEncode(
        response(text: ' 你好 ', usage: {'input_tokens': 3, 'output_tokens': 2}),
      ),
    );
    final reply = await client.complete(system: 's', messages: _hi);
    expect(reply.text, '你好');
    expect(reply.toolCalls, isEmpty);
    expect(reply.tokensIn, 3);
    expect(reply.tokensOut, 2);
  });

  test('整段回答可以没有正文，只返回工具调用', () async {
    final client = clientReturning(
      jsonEncode(
        response(
          calls: [
            call('call_1', 'propose_next_steps', {
              'steps': [
                {'title': '读定义'},
              ],
            }),
          ],
        ),
      ),
    );
    final reply = await client.complete(system: 's', messages: _hi);
    expect(reply.text, isEmpty);
    expect(reply.toolCalls.single.id, 'call_1');
    expect(reply.toolCalls.single.name, 'propose_next_steps');
    expect(reply.toolCalls.single.arguments, contains('读定义'));
  });

  test('整段回答达到长度上限时保留正文并标记截断', () async {
    final client = clientReturning(
      jsonEncode(response(text: '{"reply":"半截', status: 'incomplete')),
    );
    final reply = await client.complete(system: 's', messages: _hi);
    expect(reply.text, '{"reply":"半截');
    expect(reply.truncated, isTrue);
    expect(reply.toolCalls, isEmpty);
  });

  test('整段回答没有正文又达到长度上限时按截断失败', () async {
    final client = clientReturning(jsonEncode(response(status: 'incomplete')));
    await expectLater(
      client.complete(system: 's', messages: _hi),
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
    final client = clientReturning(jsonEncode(response(text: '')));
    await expectLater(
      client.complete(system: 's', messages: _hi),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.badResponse,
        ),
      ),
    );
  });

  test('请求按现行接口带上工具、输出上限与关掉的存储', () async {
    Map<String, Object?>? sent;
    final client = HttpLlmClient(
      config: const LlmConfig(
        endpoint: _testEndpoint,
        model: 'zhixin-chat',
        apiKey: 'test-key',
      ),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        final text = '${textDelta('你')}${textDelta('好')}${completed()}';
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
      messages: _hi,
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
    expect(sent!['model'], 'zhixin-chat');
    expect(sent!['instructions'], 's');
    expect(sent!['stream'], isTrue);
    expect(sent!['store'], isFalse);
    expect(sent!['max_output_tokens'], isNotNull);
    expect(sent!.containsKey('max_tokens'), isFalse);
    expect(sent!.containsKey('stream_options'), isFalse);
    expect(sent!.containsKey('thinking'), isFalse);
    expect(sent!.containsKey('response_format'), isFalse);
    final tools = sent!['tools'] as List;
    // 工具声明是扁平形状：名字、简介与参数都在顶层。
    expect(
      (tools.single as Map).keys,
      containsAll(['type', 'name', 'description', 'parameters']),
    );
    expect(tools.single['name'], 'propose_next_steps');
    expect(sent!['tool_choice'], {
      'type': 'function',
      'name': 'propose_next_steps',
    });
    expect((sent!['input'] as List).single, {
      'type': 'message',
      'role': 'user',
      'content': 'hi',
    });
  });

  test('工具不可用时把 tool_choice 发成 none', () async {
    Map<String, Object?>? sent;
    final client = rawStreamingClient(
      '${textDelta('好')}${completed()}',
      retryDelay: Duration.zero,
    );
    final capturing = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('${textDelta('好')}${completed()}')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await capturing
        .stream(
          system: 's',
          messages: _hi,
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {},
            ),
          ],
          allowToolCalls: false,
        )
        .toList();
    expect(sent!['tool_choice'], 'none');
    expect(sent!.containsKey('stream'), isTrue);
    client.dispose();
  });

  test('自动选择工具时不带具体名字', () async {
    Map<String, Object?>? sent;
    final client = HttpLlmClient(
      config: const LlmConfig(endpoint: _testEndpoint, apiKey: 'test-key'),
      httpClient: MockClient.streaming((request, bodyStream) async {
        sent = jsonDecode(
          utf8.decode(await bodyStream.toBytes()),
        ) as Map<String, Object?>;
        return http.StreamedResponse(
          Stream.value(utf8.encode('${textDelta('好')}${completed()}')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    await client
        .stream(
          system: 's',
          messages: _hi,
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {},
            ),
          ],
        )
        .toList();
    expect(sent!['tool_choice'], 'auto');
  });

  test('事件按 SSE 规范拼行：BOM、注释、event 字段与多行 data 都不丢', () async {
    final client = rawStreamingClient(
      '\uFEFFevent: response.output_text.delta\r\n'
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': '你'})}\r\n'
      '\r\n'
      ': keepalive\r\n'
      '\r\n'
      'event: response.output_text.delta\r\n'
      'data: {"type":\r\n'
      'data: "response.output_text.delta","delta":"好"}\r\n'
      '\r\n'
      'event: response.completed\r\n'
      'data: {"type":"response.completed","response":{"status":"completed"}}\r\n'
      '\r\n',
    );
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['你', '好']);
    expect(truncated, isFalse);
  });

  test('服务端省略 event 时按负载里的 type 读取', () async {
    final client = rawStreamingClient(
      [
        {'type': 'response.output_text.delta', 'delta': '你'},
        {'type': 'response.output_text.delta', 'delta': '好'},
        {
          'type': 'response.completed',
          'response': {'status': 'completed'},
        },
      ].map((payload) => 'data: ${jsonEncode(payload)}\n\n').join(),
    );
    final parts = <String>[];
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts.join(), '你好');
  });

  test('推理条目一类的其他事件不进入正文', () async {
    final client = streamingClient([
      event('response.reasoning_summary_text.delta', {
        'type': 'response.reasoning_summary_text.delta',
        'delta': '先算一步',
      }),
      event('response.output_text.delta', {
        'type': 'response.output_text.delta',
        'delta': '你好',
      }),
      completed(),
    ]);
    final parts = <String>[];
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
    }
    expect(parts, ['你好']);
  });

  test('流式工具参数按 output_index 分片到达，可以并行调用', () async {
    final client = streamingClient([
      argumentsDelta(1, '{"steps":['),
      argumentsDelta(2, '{"citations":['),
      itemDone(
        call('call_a', 'propose_next_steps', {
          'steps': [
            {'title': '读定义'},
          ],
        }),
        index: 1,
      ),
      itemDone(
        call('call_b', 'propose_citations', {
          'citations': [
            {'material_id': 1, 'page_no': 2, 'quote': '原文'},
          ],
        }),
        index: 2,
      ),
      completed(),
    ]);
    final deltas = await client
        .stream(
          system: 's',
          messages: _hi,
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {},
            ),
            LlmTool(
              name: 'propose_citations',
              description: '提交引用',
              parameters: {},
            ),
          ],
        )
        .toList();
    final args = <int, StringBuffer>{};
    final ids = <int, String>{};
    for (final delta in deltas) {
      for (final call in delta.toolCalls) {
        final buffer = args.putIfAbsent(call.index, StringBuffer.new);
        if (call.replaceArguments) buffer.clear();
        buffer.write(call.arguments);
        if (call.id case final id?) ids[call.index] = id;
      }
    }
    expect(args[1].toString(), '{"steps":[{"title":"读定义"}]}');
    expect(
      args[2].toString(),
      '{"citations":[{"material_id":1,"page_no":2,"quote":"原文"}]}',
    );
    expect(ids, {1: 'call_a', 2: 'call_b'});
  });

  // 项目技术审查 API-04：官方事件里 response.output_item.done 的顶层带
  // output_index，两个调用按相反顺序完成时也不能把参数、编号与工具名写到另一项
  // 调用上。这里用两个同参数的调用，保证换错序号时只有工具名会不同。
  // 真机路径会连续读两个模型步骤；模拟流只能响应一次，所以这里第一次读到的
  // 工具调用按序号汇总后作为结果比较。
  test('两个工具乱序完成时按顶层 output_index 归位', () async {
    final client = streamingClient([
      argumentsDelta(1, '{"steps":[]}'),
      argumentsDelta(2, '{"steps":[]}'),
      // 序号 2 先完成，序号 1 后完成。
      itemDone(call('call_b', 'propose_citations', {'steps': []}), index: 2),
      itemDone(call('call_a', 'propose_next_steps', {'steps': []}), index: 1),
      completed(),
    ]);
    final calls = await _readToolCalls(client);
    expect(calls, [
      ('call_a', 'propose_next_steps', '{"steps":[]}'),
      ('call_b', 'propose_citations', '{"steps":[]}'),
    ]);
  });

  // 条目不带 output_index 时，服务端只在每条参数增量都报同一个序号的情况下才能
  // 推测出归属；这里按官方事件顺序：先逐条发完参数，再逐条发完成条目。
  test('工具条目不带 output_index 时按尚未完成的那个序号归位', () async {
    final client = streamingClient([
      argumentsDelta(1, '{"steps":[]}'),
      argumentsDelta(2, '{"steps":[]}'),
      event('response.output_item.done', {
        'type': 'response.output_item.done',
        'item': call('call_a', 'propose_next_steps', {'steps': []}),
      }),
      event('response.output_item.done', {
        'type': 'response.output_item.done',
        'item': call('call_b', 'propose_citations', {'steps': []}),
      }),
      completed(),
    ]);
    final calls = await _readToolCalls(client);
    expect(
      [for (final c in calls) (c.$1, c.$2)],
      [('call_a', 'propose_next_steps'), ('call_b', 'propose_citations')],
    );
  });

  // 项目技术审查 API-03：官方事件顺序里正文增量之后还有一条带完整 message 的
  // response.output_item.done，界面不能把同一段正文再收一次。
  test('正文增量之后仍有完整条目时只收一次正文', () async {
    final client = streamingClient([
      textDelta('你'),
      textDelta('好'),
      event('response.output_item.done', {
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '你好', 'annotations': []},
          ],
        },
      }),
      completed(),
    ]);
    final parts = <String>[];
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      parts.add(delta.text);
    }
    expect(parts.join(), '你好');
  });

  test('只有完整条目没有正文增量时才从条目补回正文', () async {
    final client = streamingClient([
      event('response.output_item.done', {
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '整段补回', 'annotations': []},
          ],
        },
      }),
      completed(),
    ]);
    final parts = <String>[];
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      parts.add(delta.text);
    }
    expect(parts.join(), '整段补回');
  });

  test('流式回答只有工具调用时不报错', () async {
    final client = streamingClient([
      itemDone(call('call_1', 'propose_next_steps', {'steps': []})),
      completed(),
    ]);
    final deltas = await client
        .stream(
          system: 's',
          messages: _hi,
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {},
            ),
          ],
        )
        .toList();
    expect(deltas.single.toolCalls.single.name, 'propose_next_steps');
  });

  // 项目技术审查 API-05：不是所有 incomplete 都是“回答过长”。只有
  // max_output_tokens 才按截断提示，内容被过滤等原因按服务端错误报告。
  test('流式 incomplete 的原因不是输出上限时按服务端错误报告', () async {
    final client = streamingClient([
      textDelta('说了一半'),
      event('response.incomplete', {
        'type': 'response.incomplete',
        'response': {
          'status': 'incomplete',
          'incomplete_details': {'reason': 'content_filter'},
        },
      }),
    ]);
    await expectLater(
      client.stream(system: 's', messages: _hi).toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.server)
            .having(
              (error) => error.detail,
              'detail',
              contains('content_filter'),
            ),
      ),
    );
  });

  test('流式拒答按拒答失败报告，不带正文', () async {
    final client = streamingClient([
      event('response.refusal.delta', {
        'type': 'response.refusal.delta',
        'delta': '这个问题我不能回答',
      }),
      event('response.completed', {
        'type': 'response.completed',
        'response': {'id': 'resp_1', 'status': 'completed'},
      }),
    ]);
    await expectLater(
      client.stream(system: 's', messages: _hi).toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.refused)
            .having((error) => error.detail, 'detail', '这个问题我不能回答'),
      ),
    );
  });

  test('整段回答只有拒答块时按拒答失败报告', () async {
    final client = clientReturning(
      jsonEncode({
        'id': 'resp_1',
        'object': 'response',
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'refusal', 'refusal': '不接受这类请求'},
            ],
          },
        ],
      }),
    );
    await expectLater(
      client.complete(system: 's', messages: _hi),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.refused)
            .having((error) => error.detail, 'detail', '不接受这类请求'),
      ),
    );
  });

  test('整段回答因输出上限未完成时标记截断，其他原因按服务端错误报告', () async {
    String incomplete(String reason) => jsonEncode({
      'id': 'resp_1',
      'object': 'response',
      'status': 'incomplete',
      'incomplete_details': {'reason': reason},
      'output': [
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '半截', 'annotations': []},
          ],
        },
      ],
    });

    final truncated = await clientReturning(incomplete('max_output_tokens'))
        .complete(system: 's', messages: _hi);
    expect(truncated.text, '半截');
    expect(truncated.truncated, isTrue);

    await expectLater(
      clientReturning(incomplete('content_filter'))
          .complete(system: 's', messages: _hi),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.server)
            .having(
              (error) => error.detail,
              'detail',
              contains('content_filter'),
            ),
      ),
    );
  });

  test('流式回答达到长度上限时保留正文并标记截断', () async {
    final client = streamingClient([
      textDelta('半截'),
      event('response.incomplete', {
        'type': 'response.incomplete',
        'response': {
          'status': 'incomplete',
          'incomplete_details': {'reason': 'max_output_tokens'},
        },
      }),
    ]);
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['半截']);
    expect(truncated, isTrue);
  });

  test('流式回答没有正文又达到长度上限时按截断失败', () async {
    final client = streamingClient([
      event('response.incomplete', {
        'type': 'response.incomplete',
        'response': {'status': 'incomplete'},
      }),
    ]);
    await expectLater(
      client.stream(system: 's', messages: _hi).toList(),
      throwsA(
        isA<LlmException>().having(
          (error) => error.failure,
          'failure',
          LlmFailure.truncated,
        ),
      ),
    );
  });

  test('响应失败时按服务端错误报告', () async {
    final client = streamingClient([
      event('response.failed', {
        'type': 'response.failed',
        'response': {
          'status': 'failed',
          'error': {'code': 'server_error', 'message': '服务中断'},
        },
      }),
    ]);
    await expectLater(
      client.stream(system: 's', messages: _hi).toList(),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.server)
            .having((error) => error.detail, 'detail', '服务中断'),
      ),
    );
  });

  test('内容被过滤时按服务端错误报告', () async {
    final client = clientReturning(
      jsonEncode({
        'error': {'message': '回答被内容过滤', 'code': 'content_filter'},
      }),
    );
    await expectLater(
      client.complete(system: 's', messages: _hi),
      throwsA(
        isA<LlmException>()
            .having((error) => error.failure, 'failure', LlmFailure.server)
            .having((error) => error.detail, 'detail', '回答被内容过滤'),
      ),
    );
  });

  test('流既没有结束事件也没有 [DONE] 时按截断报告', () async {
    final client = streamingClient([textDelta('半截')]);
    final parts = <String>[];
    var truncated = false;
    await for (final delta in client.stream(system: 's', messages: _hi)) {
      if (delta.text.isNotEmpty) parts.add(delta.text);
      if (delta.truncated) truncated = true;
    }
    expect(parts, ['半截']);
    expect(truncated, isTrue);
  });

  test('只有结束事件没有正文与工具调用时按格式错误报告', () async {
    final client = streamingClient([completed()]);
    await expectLater(
      client.stream(system: 's', messages: _hi).toList(),
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
      client.stream(system: 's', messages: _hi).toList(),
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
        final body = jsonEncode(
          response(
            text: '整段回答',
            calls: [
              call('call_1', 'propose_next_steps', {'steps': []}),
            ],
          ),
        );
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
          messages: _hi,
          tools: const [
            LlmTool(
              name: 'propose_next_steps',
              description: '提交建议',
              parameters: {},
            ),
          ],
        )
        .toList();
    expect(deltas.first.text, '整段回答');
    expect(deltas.last.toolCalls.single.name, 'propose_next_steps');
  });

  test(
    '消息按条目展开：图片是 input_image，工具交换是 function_call 与 function_call_output',
    () {
      final body = responsesBody(
        config: const LlmConfig(endpoint: _testEndpoint, model: 'm'),
        system: 'sys',
        messages: [
          LlmMessage(
            role: 'user',
            content: '请看图',
            images: [
              LlmImage(bytes: Uint8List.fromList([1, 2])),
            ],
          ),
          const LlmMessage(
            role: 'assistant',
            content: '先读原文',
            toolCalls: [
              LlmToolCall(
                id: 'call_1',
                name: 'read_material_page',
                arguments: '{"page_no":7}',
              ),
            ],
          ),
          const LlmMessage.toolResult(
            callId: 'call_1',
            content: '{"result":"正文"}',
          ),
        ],
        tools: const [],
        forceTool: null,
        allowToolCalls: false,
        stream: false,
      );
      final input = (body['input'] as List).cast<Map<String, Object?>>();
      final content = input.first['content'] as List;
      expect(content.first, {'type': 'input_text', 'text': '请看图'});
      expect((content.last as Map)['image_url'], 'data:image/jpeg;base64,AQI=');
      expect(input[1], {
        'type': 'message',
        'role': 'assistant',
        'content': '先读原文',
      });
      expect(input[2], {
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'read_material_page',
        'arguments': '{"page_no":7}',
      });
      final output = jsonDecode(input[3]['output'] as String) as Map;
      expect(input[3]['type'], 'function_call_output');
      expect(input[3]['call_id'], 'call_1');
      expect(output['result'], '正文');
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('tool_choice'), isFalse);
    },
  );

  test('讨论历史里的工具结果原样发送', () {
    final body = responsesBody(
      config: const LlmConfig(endpoint: _testEndpoint),
      system: 's',
      messages: const [
        LlmMessage.toolResult(
          callId: 'c',
          content: 'Binary(12) \\x01',
          compileArgs: false,
        ),
      ],
      tools: const [],
      forceTool: null,
      allowToolCalls: false,
      stream: false,
    );
    expect((body['input'] as List).single, {
      'type': 'function_call_output',
      'call_id': 'c',
      'output': 'Binary(12) \\x01',
    });
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
        return http.StreamedResponse(
          Stream.value(utf8.encode('${textDelta('好')}${completed()}')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final parts = <String>[];
    await for (final delta in client.stream(system: 's', messages: _hi)) {
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
          jsonEncode(response(text: '重试成功')),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final reply = await client.complete(system: 's', messages: _hi);
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
      client.complete(system: 's', messages: _hi),
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
      client.complete(system: 's', messages: _hi),
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
      client.complete(system: 's', messages: _hi),
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
      client.complete(system: 's', messages: _hi),
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
      client.stream(system: 's', messages: _hi).drain<void>(),
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
      client.stream(system: 's', messages: _hi).drain<void>(),
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
      client.stream(system: 's', messages: _hi).drain<void>(),
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
            textDelta('半截') +
            event('error', {
              'type': 'error',
              'error': {'message': '服务出错'},
            });
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    final deltas = <LlmDelta>[];
    await expectLater(
      client.stream(system: 's', messages: _hi).map((delta) {
        deltas.add(delta);
        return delta;
      }).drain<void>(),
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
