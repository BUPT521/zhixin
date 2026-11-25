import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';

/// 403 contact_unverified 的归类：给出专门文案，不归成登录失效，也不自动重试。
void main() {
  test('contact_unverified 有专门的说法，可以和认证失败区分', () {
    expect(shortTextOf(LlmFailure.contactUnverified), '还没有确认任何登录方式，托管额度未开放');
    expect(shortTextOf(LlmFailure.contactUnverified), isNot(contains('登录已失效')));
    expect(
      llmFailureFromName('contactUnverified'),
      LlmFailure.contactUnverified,
    );
  });

  test('4xx 的登录方式未确认不在自动重试范围内', () {
    const policy = RetryPolicy();
    expect(
      policy.shouldRetry(LlmFailure.contactUnverified, attempt: 0),
      isFalse,
    );
    expect(policy.shouldRetry(LlmFailure.auth, attempt: 0), isFalse);
  });

  test('problem+json 的 code 只从代理拒绝里读，提供方错误仍按状态码', () {
    expect(
      problemCodeOf(
        jsonEncode({
          'type': 'urn:zhixin:problem:contact_unverified',
          'title': 'contact_unverified',
          'status': 403,
          'code': 'contact_unverified',
        }),
      ),
      'contact_unverified',
    );
    expect(
      problemCodeOf(
        jsonEncode({
          'error': {'message': 'Insufficient Balance', 'type': 'auth'},
        }),
      ),
      isNull,
    );
    expect(problemCodeOf('not json'), isNull);
    expect(problemCodeOf(''), isNull);
  });

  test('403 contact_unverified 的响应映射成专门失败类型且不重试', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        requests++;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'type': 'urn:zhixin:problem:contact_unverified',
                'title': 'contact_unverified',
                'status': 403,
                'code': 'contact_unverified',
                'detail': '账号还没确认任何登录方式',
              }),
            ),
          ),
          403,
          headers: {'content-type': 'application/problem+json'},
        );
      }),
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
            .having(
              (error) => error.failure,
              'failure',
              LlmFailure.contactUnverified,
            )
            .having(
              (error) => error.shortText,
              'shortText',
              '还没有确认任何登录方式，托管额度未开放',
            ),
      ),
    );
    // 4xx 不自动重试：只发出一次请求。
    expect(requests, 1);
  });

  test('模型未启用从代理的 400 归类，且不自动重试', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        requests++;
        return http.Response(
          '{"code":"model_not_allowed","extra":{"models":["zhixin-chat"]}}',
          400,
          headers: {'content-type': 'application/problem+json'},
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
          LlmFailure.modelNotAllowed,
        ),
      ),
    );
    expect(requests, 1);
  });

  test('429 rate_limited 归为短时繁忙，并带出 Retry-After 的等待时长', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        requests++;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'type': 'urn:zhixin:problem:rate_limited',
                'status': 429,
                'code': 'rate_limited',
                'detail': 'model source is temporarily rate limited',
              }),
            ),
          ),
          429,
          headers: {
            'content-type': 'application/problem+json',
            'retry-after': '7',
          },
        );
      }),
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
            .having((error) => error.failure, 'failure', LlmFailure.busy)
            .having(
              (error) => error.retryAfter,
              'retryAfter',
              const Duration(seconds: 7),
            )
            .having((error) => error.shortText, 'shortText', '模型服务暂时繁忙'),
      ),
    );
    // 等待时间较长时交给用户，不自动重发。
    expect(requests, 1);
  });

  test('429 rate_limited 的等待很短时自动重试一次', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        requests++;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'code': 'rate_limited'}))),
          429,
          headers: {
            'content-type': 'application/problem+json',
            'retry-after': '1',
          },
        );
      }),
    );

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
          LlmFailure.busy,
        ),
      ),
    );
    expect(requests, 2);
  });

  test('429 quota_exceeded 仍按额度用完归类', () async {
    var requests = 0;
    final client = HttpLlmClient(
      config: const LlmConfig(apiKey: 'test-key'),
      retryDelay: Duration.zero,
      httpClient: MockClient.streaming((request, bodyStream) async {
        requests++;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'code': 'quota_exceeded'}))),
          429,
          headers: {'content-type': 'application/problem+json'},
        );
      }),
    );

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
          LlmFailure.rateLimited,
        ),
      ),
    );
    expect(requests, 1);
  });
}
