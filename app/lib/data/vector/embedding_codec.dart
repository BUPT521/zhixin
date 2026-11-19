import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 片段文本的哈希：UTF-8 字节的 SHA-256，小写十六进制。
///
/// 服务端的向量缓存以这个哈希为键，两边必须用同一口径。切片时的规范化只在
/// 客户端做一次，哈希按切片之后的正文计算，不再额外处理（ADR-0030 决定第 2 条）。
String embeddingTextHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// 解码服务端返回的一条向量：小端序 FP16 的 base64。
///
/// 返回字节数等于 [dim] 个 FP16 即两倍维度的向量；长度不符或 base64 不合法时
/// 返回空，调用方把这段文本按未命中处理，重新嵌入。数值原样返回，需要归一化时
/// 由调用方按现有方式处理（服务端保存的是嵌入结果，不经归一化）。
List<double>? decodeEmbeddingVector(String encoded, {required int dim}) {
  if (dim <= 0) return null;
  final List<int> bytes;
  try {
    bytes = base64Decode(encoded);
  } on FormatException {
    return null;
  }
  if (bytes.length != dim * 2) return null;
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final vector = List<double>.filled(dim, 0);
  for (var index = 0; index < dim; index++) {
    vector[index] = _halfToDouble(data.getUint16(index * 2, Endian.little));
  }
  return vector;
}

/// IEEE 754 半精度浮点的位模式转双精度，覆盖次正规数、无穷与 NaN。
double _halfToDouble(int bits) {
  final sign = (bits & 0x8000) == 0 ? 1.0 : -1.0;
  final exponent = (bits >> 10) & 0x1f;
  final fraction = bits & 0x3ff;
  if (exponent == 0) {
    // 次正规数按 fraction × 2⁻²⁴ 计算；全零是带符号的零。
    return sign * fraction * math.pow(2, -24).toDouble();
  }
  if (exponent == 0x1f) {
    return fraction == 0 ? sign * double.infinity : double.nan;
  }
  return sign * (1 + fraction / 1024) * math.pow(2, exponent - 15).toDouble();
}
