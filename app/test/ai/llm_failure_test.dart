import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/llm_config.dart';

/// 403 email_unverified 的归类：给出专门文案，不归成 API Key 无效，也不自动重试。
void main() {
  test('email_unverified 有专门的说法，可以和认证失败区分', () {
    expect(shortTextOf(LlmFailure.emailUnverified), '邮箱尚未验证，托管额度未开放');
    expect(shortTextOf(LlmFailure.emailUnverified), isNot(contains('API Key')));
    expect(llmFailureFromName('emailUnverified'), LlmFailure.emailUnverified);
  });

  test('4xx 的邮箱未验证不在自动重试范围内', () {
    const policy = RetryPolicy();
    expect(policy.shouldRetry(LlmFailure.emailUnverified, attempt: 0), isFalse);
    expect(policy.shouldRetry(LlmFailure.auth, attempt: 0), isFalse);
  });

  test('problem+json 的 code 只从代理拒绝里读，提供方错误仍按状态码', () {
    expect(
      problemCodeOf(
        jsonEncode({
          'type': 'urn:zhixin:problem:email_unverified',
          'title': 'email_unverified',
          'status': 403,
          'code': 'email_unverified',
        }),
      ),
      'email_unverified',
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

  test('403 email_unverified 的响应映射成专门失败类型且不重试', () async {
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
                'type': 'urn:zhixin:problem:email_unverified',
                'title': 'email_unverified',
                'status': 403,
                'code': 'email_unverified',
                'detail': '账号还没验证邮箱',
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
              LlmFailure.emailUnverified,
            )
            .having((error) => error.shortText, 'shortText', '邮箱尚未验证，托管额度未开放'),
      ),
    );
    // 4xx 不自动重试：只发出一次请求。
    expect(requests, 1);
  });
}
