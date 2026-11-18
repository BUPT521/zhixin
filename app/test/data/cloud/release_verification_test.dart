import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/cloud/release_verification.dart';

/// 发布清单的哈希与签名核对：哈希表示、PEM 解析与 Ed25519 验签。
void main() {
  test('SHA-256 是小写十六进制的 64 位字符串', () {
    final hash = releaseSha256Hex(utf8.encode('知新'));
    expect(hash, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    expect(isReleaseSha256Hex(hash), isTrue);
    expect(isReleaseSha256Hex(hash.toUpperCase()), isFalse);
    expect(isReleaseSha256Hex('${hash}0'), isFalse);
    expect(isReleaseSha256Hex(''), isFalse);
  });

  test('用配对私钥生成的签名可以通过，换一把公钥或改哈希都不通过', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final pem = _publicKeyPem(publicKey.bytes);
    final hash = releaseSha256Hex(Uint8List.fromList([1, 2, 3, 4]));
    final signature = await algorithm.sign(utf8.encode(hash), keyPair: keyPair);
    final signatureBase64 = base64.encode(signature.bytes);

    expect(
      await verifyReleaseSignature(
        publicKeyPem: pem,
        sha256Hex: hash,
        signatureBase64: signatureBase64,
      ),
      isTrue,
    );

    final otherPair = await Ed25519().newKeyPair();
    final other = await otherPair.extractPublicKey();
    expect(
      await verifyReleaseSignature(
        publicKeyPem: _publicKeyPem(other.bytes),
        sha256Hex: hash,
        signatureBase64: signatureBase64,
      ),
      isFalse,
    );

    final changed = releaseSha256Hex(Uint8List.fromList([1, 2, 3, 5]));
    expect(
      await verifyReleaseSignature(
        publicKeyPem: pem,
        sha256Hex: changed,
        signatureBase64: signatureBase64,
      ),
      isFalse,
    );
  });

  test('公钥为空、格式不对或签名不是 64 字节时按验签失败处理', () async {
    final hash = releaseSha256Hex(utf8.encode('package'));
    final signature = base64.encode(List<int>.filled(64, 7));
    expect(
      await verifyReleaseSignature(
        publicKeyPem: '',
        sha256Hex: hash,
        signatureBase64: signature,
      ),
      isFalse,
    );
    expect(
      await verifyReleaseSignature(
        publicKeyPem:
            '-----BEGIN PUBLIC KEY-----\n不是 base64\n-----END PUBLIC KEY-----',
        sha256Hex: hash,
        signatureBase64: signature,
      ),
      isFalse,
    );
    expect(
      await verifyReleaseSignature(
        publicKeyPem: '',
        sha256Hex: 'abc',
        signatureBase64: signature,
      ),
      isFalse,
    );
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    expect(
      await verifyReleaseSignature(
        publicKeyPem: _publicKeyPem(publicKey.bytes),
        sha256Hex: hash,
        signatureBase64: base64.encode(List<int>.filled(32, 7)),
      ),
      isFalse,
    );
  });
}

/// 按 Ed25519 的 SubjectPublicKeyInfo 结构拼一份 PEM，与发版流程产出的格式一致。
String _publicKeyPem(List<int> publicKeyBytes) {
  const prefix = <int>[
    0x30,
    0x2a,
    0x30,
    0x05,
    0x06,
    0x03,
    0x2b,
    0x65,
    0x70,
    0x03,
    0x21,
    0x00,
  ];
  final body = base64.encode([...prefix, ...publicKeyBytes]);
  final lines = <String>[
    for (var start = 0; start < body.length; start += 64)
      body.substring(start, math.min(start + 64, body.length)),
  ];
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n'
      '-----END PUBLIC KEY-----\n';
}
