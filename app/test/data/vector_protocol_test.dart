import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/vector/vector_index.dart';
import 'package:zhixin/data/vector/vector_protocol.dart';

void main() {
  test('每条请求都能编码再解回，参数按名字对应', () {
    final requests = <VectorRequest>[
      const EntryCountRequest(1),
      const SourceCountRequest(2),
      const IndexedSourcesRequest(3, ['message:m1', 'message:m2']),
      const MetaRequest(4, 'built_at'),
      const SetMetaRequest(5, 'built_at', '2026-11-27 10:00:00'),
      const FinishRefreshRequest(6, '2026-11-27 10:00:00', 2, 5),
      const ReplaceSourceRequest(
        7,
        '{"kind":"message"}',
        'v1',
        ['片段'],
        ['hash'],
        [
          [1.0, 0.0],
        ],
        '2026-11-27 10:00:00',
      ),
      const PruneSourcesRequest(8, ['message:m1']),
      const SearchRequest(9, [1.0, 0.0], 3, null),
      const SearchTextRequest(10, '熵', 3, null),
      const ClearRequest(11),
      const CloseRequest(12),
    ];

    for (final request in requests) {
      final decoded = VectorRequest.decode(request.encode());
      expect(decoded.runtimeType, request.runtimeType);
      expect(decoded.id, request.id);
    }

    final replace =
        VectorRequest.decode(requests[6].encode()) as ReplaceSourceRequest;
    expect(replace.locatorJson, '{"kind":"message"}');
    expect(replace.chunks, ['片段']);
    expect(replace.vectors.single, [1.0, 0.0]);
    final refresh =
        VectorRequest.decode(requests[5].encode()) as FinishRefreshRequest;
    expect(refresh.builtAt, '2026-11-27 10:00:00');
    expect(refresh.sourceCount, 2);
    expect(refresh.writtenEntries, 5);
  });

  test('未知操作、缺少编号与类型不对的字段都按格式错误拒绝', () {
    expect(
      () => VectorRequest.decode({'id': 1, 'op': '未知操作'}),
      throwsFormatException,
    );
    expect(
      () => VectorRequest.decode({'op': 'entryCount'}),
      throwsFormatException,
    );
    expect(() => VectorRequest.decode('不是键值表'), throwsFormatException);
    expect(
      () => VectorRequest.decode({'id': 1, 'op': 'meta', 'key': 1}),
      throwsFormatException,
    );
    expect(
      () => VectorRequest.decode({
        'id': 1,
        'op': 'search',
        'query': ['x'],
      }),
      throwsFormatException,
    );
    expect(
      () => VectorRequest.decode({
        'id': 1,
        'op': 'search',
        'query': [1.0],
        'k': 3,
        'prefilter': {'kind': 'material'},
      }),
      throwsFormatException,
    );
  });

  test('回包按形状解码，认不出的形状交回空值', () {
    final success = VectorResponse.decode(
      const VectorSuccess(3, {'value': 1}).encode(),
    );
    expect(success, isA<VectorSuccess>());
    expect((success! as VectorSuccess).value, {'value': 1});

    final failure = VectorResponse.decode(
      const VectorFailure(4, '索引正被占用', '调用栈').encode(),
    );
    expect(failure, isA<VectorFailure>());
    expect((failure! as VectorFailure).message, '索引正被占用');

    // 形状认不出来：编号缺失、既没有 ok 也没有 error、不是键值表。
    expect(VectorResponse.decode({'ok': true}), isNull);
    expect(VectorResponse.decode({'id': 1}), isNull);
    expect(VectorResponse.decode(['id', 1]), isNull);
    expect(VectorResponse.decode(null), isNull);
  });

  test('预过滤条件往返一致，未知类型按格式错误拒绝', () {
    for (final prefilter in <VectorPrefilter?>[
      null,
      const MaterialVectorPrefilter('material-1'),
      ConversationVectorPrefilter(
        conversationId: 'conv-1',
        sourceKeys: {'message:m1'},
      ),
      SourceKeysVectorPrefilter({'message:m1', 'message:m2'}),
    ]) {
      final decoded = decodePrefilter(encodePrefilter(prefilter));
      expect(decoded.toString(), prefilter.toString());
    }

    expect(() => decodePrefilter({'kind': '未知类型'}), throwsFormatException);
    expect(() => decodePrefilter('material'), throwsFormatException);
  });
}
