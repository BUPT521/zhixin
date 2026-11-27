import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhixin/application/embedding_client.dart';
import 'package:zhixin/domain/rules/embedding.dart';

/// 知新服务来源的解码规则：序号要么不写、按返回顺序落位，要么是范围内的整数。
void main() {
  RemoteEmbeddingClient clientFor(List<Object?> data) => RemoteEmbeddingClient(
    spec: const EmbeddingModelSpec(id: 'embed-test', dim: 2),
    credentials: () async =>
        (endpoint: 'https://embed.test/v1', apiKey: 'token'),
    httpClient: MockClient(
      (request) async => http.Response(
        jsonEncode({'data': data}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );

  test('序号是范围内的整数时按序号落位', () async {
    final client = clientFor([
      {
        'index': 1,
        'embedding': [0, 1],
      },
      {
        'index': 0,
        'embedding': [1, 0],
      },
    ]);
    final vectors = await client.embedBatch(['第一段', '第二段']);
    expect(vectors[0], [1, 0]);
    expect(vectors[1], [0, 1]);
    client.dispose();
  });

  test('没有序号时按返回顺序落位', () async {
    final client = clientFor([
      {
        'embedding': [1, 0],
      },
      {
        'embedding': [0, 1],
      },
    ]);
    final vectors = await client.embedBatch(['第一段', '第二段']);
    expect(vectors[0], [1, 0]);
    expect(vectors[1], [0, 1]);
    client.dispose();
  });

  test('序号不是整数时拒绝整批结果，不再截断成某个槽位', () async {
    final client = clientFor([
      {
        'index': 0,
        'embedding': [1, 0],
      },
      {
        'index': 1.5,
        'embedding': [0, 1],
      },
    ]);
    await expectLater(
      client.embedBatch(['第一段', '第二段']),
      throwsA(
        isA<EmbeddingUnavailable>().having(
          (error) => error.message,
          'message',
          contains('整数'),
        ),
      ),
    );
    client.dispose();
  });

  test('序号越界时拒绝整批结果', () async {
    final client = clientFor([
      {
        'index': 2,
        'embedding': [1, 0],
      },
    ]);
    await expectLater(
      client.embedBatch(['第一段']),
      throwsA(isA<EmbeddingUnavailable>()),
    );
    client.dispose();
  });
}
