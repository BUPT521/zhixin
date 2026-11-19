import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/vector/embedding_codec.dart';

/// 与服务端一致的文本哈希与 FP16 解码；两边口径不同时缓存永远不命中。
void main() {
  group('文本哈希', () {
    test('按 UTF-8 字节计算 SHA-256，输出小写十六进制', () {
      expect(
        embeddingTextHash(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        embeddingTextHash('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      // 中文按 UTF-8 编码，字节数多于字符数；哈希与服务端共用这一份口径。
      expect(
        embeddingTextHash('熵是系统混乱程度的度量。'),
        'a4f893c8878e125c7e5399fbb7cc9518ba09dabb71942718556f121737546e8c',
      );
      expect(
        embeddingTextHash('矩阵 A 的第 b 列记作 a_b。'),
        '3ffc1b8553f049577b0f7127e4115e3412edef66a0257e7f74b995dbd1110a96',
      );
    });

    test('保留空白与原样字节，不做规范化', () {
      expect(
        embeddingTextHash('熵是系统混乱程度的度量。 '),
        isNot(embeddingTextHash('熵是系统混乱程度的度量。')),
      );
    });
  });

  group('FP16 解码', () {
    test('小端序两字节一个数，解出的数值与写入时一致', () {
      final vector = decodeEmbeddingVector('ADwAOADAAAA=', dim: 4);
      expect(vector, isNotNull);
      expect(vector, [1.0, 0.5, -2.0, 0.0]);
    });

    test('次正规数与无穷按 IEEE 754 半精度解释', () {
      final bytes = ByteData(4)
        ..setUint16(0, 0x0001, Endian.little)
        ..setUint16(2, 0x7c00, Endian.little);
      final vector = decodeEmbeddingVector(
        base64Encode(bytes.buffer.asUint8List()),
        dim: 2,
      );
      expect(vector![0], closeTo(5.960464477539063e-8, 1e-20));
      expect(vector[1], double.infinity);
    });

    test('长度与维度不符或 base64 不合法时返回空，由调用方重新嵌入', () {
      expect(decodeEmbeddingVector('ADwAOADAAAA=', dim: 3), isNull);
      expect(decodeEmbeddingVector('***', dim: 4), isNull);
      expect(decodeEmbeddingVector('', dim: 4), isNull);
      expect(decodeEmbeddingVector('ADwAOADAAAA=', dim: 0), isNull);
    });
  });
}
