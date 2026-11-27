import 'vector_index.dart';

/// 界面线程与后台索引线程之间的协议：一条语句一个请求类，一项结果一个响应类。
///
/// 以前请求是 `{'id': id, 'op': op, 'args': args}`，后台按 `args[0]`、`args[1]`
/// 取值：参数顺序只能靠两边记住，形状不对的回包在界面侧被直接丢弃，对应的
/// 等待方永远不返回。现在参数都有名字，编解码只有这一个文件，认不出的回包由
/// 界面侧按失败处理。
sealed class VectorRequest {
  const VectorRequest(this.id);

  /// 请求编号：界面侧按它把回包交回对应的等待方。
  final int id;

  /// 线上格式：编号、操作名与具名字段。
  Map<String, Object?> encode();

  /// 从线上格式解出请求；形状不对或操作名不认识时抛 [FormatException]。
  ///
  /// 后台线程捕获这个异常并按同一个编号回一条失败，等待方因此不会永久挂起。
  static VectorRequest decode(Object? message) {
    if (message is! Map) throw const FormatException('请求不是键值表');
    final id = message['id'];
    if (id is! int) throw const FormatException('请求缺少编号');
    return switch (message['op']) {
      'entryCount' => EntryCountRequest(id),
      'sourceCount' => SourceCountRequest(id),
      'indexedSources' => IndexedSourcesRequest(id, _strings(message['keys'])),
      'meta' => MetaRequest(id, _string(message['key'])),
      'setMeta' => SetMetaRequest(
        id,
        _string(message['key']),
        _string(message['value']),
      ),
      'finishRefresh' => FinishRefreshRequest(
        id,
        _string(message['builtAt']),
        _int(message['sourceCount']),
        _int(message['writtenEntries']),
      ),
      'replaceSource' => ReplaceSourceRequest(
        id,
        _string(message['locatorJson']),
        _string(message['sourceVersion']),
        _strings(message['chunks']),
        _strings(message['hashes']),
        _vectors(message['vectors']),
        _string(message['createdAt']),
      ),
      'pruneSources' => PruneSourcesRequest(id, _strings(message['keep'])),
      'search' => SearchRequest(
        id,
        _doubles(message['query']),
        _int(message['k']),
        decodePrefilter(message['prefilter']),
      ),
      'searchText' => SearchTextRequest(
        id,
        _string(message['text']),
        _int(message['k']),
        decodePrefilter(message['prefilter']),
      ),
      'clear' => ClearRequest(id),
      'close' => CloseRequest(id),
      final Object? op => throw FormatException('未知的向量索引操作：$op'),
    };
  }
}

final class EntryCountRequest extends VectorRequest {
  const EntryCountRequest(super.id);

  @override
  Map<String, Object?> encode() => {'id': id, 'op': 'entryCount'};
}

final class SourceCountRequest extends VectorRequest {
  const SourceCountRequest(super.id);

  @override
  Map<String, Object?> encode() => {'id': id, 'op': 'sourceCount'};
}

final class IndexedSourcesRequest extends VectorRequest {
  const IndexedSourcesRequest(super.id, this.keys);

  final List<String> keys;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'indexedSources',
    'keys': keys,
  };
}

final class MetaRequest extends VectorRequest {
  const MetaRequest(super.id, this.key);

  final String key;

  @override
  Map<String, Object?> encode() => {'id': id, 'op': 'meta', 'key': key};
}

final class SetMetaRequest extends VectorRequest {
  const SetMetaRequest(super.id, this.key, this.value);

  final String key;
  final String value;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'setMeta',
    'key': key,
    'value': value,
  };
}

final class FinishRefreshRequest extends VectorRequest {
  const FinishRefreshRequest(
    super.id,
    this.builtAt,
    this.sourceCount,
    this.writtenEntries,
  );

  final String builtAt;
  final int sourceCount;
  final int writtenEntries;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'finishRefresh',
    'builtAt': builtAt,
    'sourceCount': sourceCount,
    'writtenEntries': writtenEntries,
  };
}

final class ReplaceSourceRequest extends VectorRequest {
  const ReplaceSourceRequest(
    super.id,
    this.locatorJson,
    this.sourceVersion,
    this.chunks,
    this.hashes,
    this.vectors,
    this.createdAt,
  );

  final String locatorJson;
  final String sourceVersion;
  final List<String> chunks;
  final List<String> hashes;
  final List<List<double>> vectors;
  final String createdAt;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'replaceSource',
    'locatorJson': locatorJson,
    'sourceVersion': sourceVersion,
    'chunks': chunks,
    'hashes': hashes,
    'vectors': vectors,
    'createdAt': createdAt,
  };
}

final class PruneSourcesRequest extends VectorRequest {
  const PruneSourcesRequest(super.id, this.keep);

  final List<String> keep;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'pruneSources',
    'keep': keep,
  };
}

final class SearchRequest extends VectorRequest {
  const SearchRequest(super.id, this.query, this.k, this.prefilter);

  final List<double> query;
  final int k;
  final VectorPrefilter? prefilter;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'search',
    'query': query,
    'k': k,
    'prefilter': encodePrefilter(prefilter),
  };
}

final class SearchTextRequest extends VectorRequest {
  const SearchTextRequest(super.id, this.text, this.k, this.prefilter);

  final String text;
  final int k;
  final VectorPrefilter? prefilter;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'op': 'searchText',
    'text': text,
    'k': k,
    'prefilter': encodePrefilter(prefilter),
  };
}

final class ClearRequest extends VectorRequest {
  const ClearRequest(super.id);

  @override
  Map<String, Object?> encode() => {'id': id, 'op': 'clear'};
}

final class CloseRequest extends VectorRequest {
  const CloseRequest(super.id);

  @override
  Map<String, Object?> encode() => {'id': id, 'op': 'close'};
}

/// 后台线程的回包：成功带结果，失败带说明与调用栈。
sealed class VectorResponse {
  const VectorResponse(this.id);

  final int id;

  Map<String, Object?> encode();

  /// 从线上格式解出回包；认不出的形状返回空，由界面侧按失败处理。
  static VectorResponse? decode(Object? message) {
    if (message is! Map) return null;
    final id = message['id'];
    if (id is! int) return null;
    if (message['ok'] == true) {
      return VectorSuccess(id, message['value']);
    }
    final error = message['error'];
    if (error == null) return null;
    return VectorFailure(id, '$error', '${message['stack'] ?? ''}');
  }
}

final class VectorSuccess extends VectorResponse {
  const VectorSuccess(super.id, this.value);

  final Object? value;

  @override
  Map<String, Object?> encode() => {'id': id, 'ok': true, 'value': value};
}

final class VectorFailure extends VectorResponse {
  const VectorFailure(super.id, this.message, this.stack);

  final String message;
  final String stack;

  @override
  Map<String, Object?> encode() => {
    'id': id,
    'ok': false,
    'error': message,
    'stack': stack,
  };
}

/// 预过滤条件的线上格式；检索请求里带着它，编解码与请求放在同一个文件。
Map<String, Object?>? encodePrefilter(VectorPrefilter? prefilter) =>
    switch (prefilter) {
      null => null,
      MaterialVectorPrefilter(:final materialId) => {
        'kind': 'material',
        'materialId': materialId,
      },
      ConversationVectorPrefilter(:final conversationId, :final sourceKeys) => {
        'kind': 'conversation',
        'conversationId': conversationId,
        'sourceKeys': sourceKeys.toList(growable: false),
      },
      SourceKeysVectorPrefilter(:final sourceKeys) => {
        'kind': 'sourceKeys',
        'sourceKeys': sourceKeys.toList(growable: false),
      },
    };

/// 解出预过滤条件；空值表示不限范围，类型不认识时抛 [FormatException]。
VectorPrefilter? decodePrefilter(Object? value) {
  if (value == null) return null;
  if (value is! Map) throw const FormatException('预过滤条件不是键值表');
  return switch (value['kind']) {
    'material' => MaterialVectorPrefilter(_string(value['materialId'])),
    'conversation' => ConversationVectorPrefilter(
      conversationId: value['conversationId'] as String?,
      sourceKeys: _strings(value['sourceKeys']).toSet(),
    ),
    'sourceKeys' => SourceKeysVectorPrefilter(_strings(value['sourceKeys'])),
    final Object? kind => throw FormatException('未知的向量索引预过滤类型：$kind'),
  };
}

String _string(Object? value) {
  if (value is String) return value;
  throw FormatException('应为字符串，实际是 $value');
}

int _int(Object? value) {
  if (value is int) return value;
  throw FormatException('应为整数，实际是 $value');
}

List<String> _strings(Object? value) {
  if (value is List) return value.cast<String>();
  throw FormatException('应为字符串列表，实际是 $value');
}

List<double> _doubles(Object? value) {
  if (value is List) return value.cast<double>();
  throw FormatException('应为数值列表，实际是 $value');
}

List<List<double>> _vectors(Object? value) {
  if (value is! List) throw FormatException('应为向量列表，实际是 $value');
  return [for (final vector in value) _doubles(vector)];
}
