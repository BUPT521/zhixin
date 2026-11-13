import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// 文本处理版本：切块方式或规范化方式改变时递增，旧索引据此失效。
const String semanticTextVersion = 'zhixin-text-v1';

/// 一次嵌入使用的模型；模型标识、维度与文本处理版本共同决定索引是否可复用。
class EmbeddingModelSpec {
  const EmbeddingModelSpec({
    required this.id,
    required this.dim,
    this.textVersion = semanticTextVersion,
    this.provider = 'remote',
  });

  final String id;
  final int dim;
  final String textVersion;
  final String provider;

  String get indexKey => '$id|$dim|$textVersion';

  Map<String, Object?> toJson() => {
    'id': id,
    'dim': dim,
    'text_version': textVersion,
    'provider': provider,
  };

  static EmbeddingModelSpec? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final dim = value['dim'];
    if (id is! String || dim is! int || dim <= 0) return null;
    return EmbeddingModelSpec(
      id: id,
      dim: dim,
      textVersion: (value['text_version'] as String?) ?? semanticTextVersion,
      provider: (value['provider'] as String?) ?? 'remote',
    );
  }
}

/// 把一段原文切成带重叠的块；短文本只有一块。
///
/// 跨块重叠避免一句话正好落在边界时两边都取不到；块序号与原文一起构成向量
/// 条目的位置，合并时按来源标识去重。
List<({int index, String text})> semanticChunks(
  String text, {
  int maxChars = 320,
  int overlap = 40,
}) {
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return const [];
  if (normalized.length <= maxChars) {
    return [(index: 0, text: normalized)];
  }
  final chunks = <({int index, String text})>[];
  final step = math.max(1, maxChars - overlap);
  for (var start = 0; start < normalized.length; start += step) {
    final end = math.min(start + maxChars, normalized.length);
    chunks.add((index: chunks.length, text: normalized.substring(start, end)));
    if (end >= normalized.length) break;
  }
  return chunks;
}

/// 把向量写成小端 float32 字节；sqlite3_vec 只接受这种格式。
Uint8List encodeVector(List<double> values) {
  final floats = Float32List.fromList(values);
  return floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes);
}

List<double> decodeVector(Uint8List bytes) {
  final floats = bytes.buffer.asFloat32List(
    bytes.offsetInBytes,
    bytes.length ~/ 4,
  );
  return List<double>.from(floats);
}

/// 单位化向量，避免检索结果受长度影响。
List<double> normalizeVector(List<double> values) {
  var sum = 0.0;
  for (final value in values) {
    sum += value * value;
  }
  if (sum == 0) return List<double>.filled(values.length, 0);
  final scale = 1 / math.sqrt(sum);
  return [for (final value in values) value * scale];
}

/// 余弦距离（sqlite3_vec 的 `distance_metric=cosine` 距离）越小越相似。
double cosineDistance(List<double> left, List<double> right) {
  final length = math.min(left.length, right.length);
  var dot = 0.0;
  var leftNorm = 0.0;
  var rightNorm = 0.0;
  for (var index = 0; index < length; index++) {
    dot += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }
  if (leftNorm == 0 || rightNorm == 0) return 1;
  return 1 - dot / math.sqrt(leftNorm * rightNorm);
}

/// 向量条目的定位信息；来源标识、所属记录与片段位置都保存在这里。
class SemanticLocator {
  const SemanticLocator({
    required this.kind,
    required this.sourceKey,
    this.conversationId,
    this.messageId,
    this.materialId,
    this.pageNo,
    this.attemptId,
  });

  final String kind;
  final String sourceKey;
  final int? conversationId;
  final int? messageId;
  final int? materialId;
  final int? pageNo;
  final int? attemptId;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'source_key': sourceKey,
    'conversation_id': conversationId,
    'message_id': messageId,
    'material_id': materialId,
    'page_no': pageNo,
    'attempt_id': attemptId,
  };

  static SemanticLocator? fromJson(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final kind = value['kind'];
      final sourceKey = value['source_key'];
      if (kind is! String || sourceKey is! String) return null;
      return SemanticLocator(
        kind: kind,
        sourceKey: sourceKey,
        conversationId: value['conversation_id'] as int?,
        messageId: value['message_id'] as int?,
        materialId: value['material_id'] as int?,
        pageNo: value['page_no'] as int?,
        attemptId: value['attempt_id'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}
