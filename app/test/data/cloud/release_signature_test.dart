import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/cloud/release_signature.dart';

List<int> _hex(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);

void main() {
  group('RFC 8032 向量', () {
    test('TEST 1：空消息的签名通过验证', () {
      expect(
        verifyEd25519Signature(
          publicKey: _hex(
            'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
          ),
          message: const [],
          signature: _hex(
            'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
            '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
          ),
        ),
        isTrue,
      );
    });

    test('TEST 2：单字节消息的签名通过验证', () {
      expect(
        verifyEd25519Signature(
          publicKey: _hex(
            '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
          ),
          message: _hex('72'),
          signature: _hex(
            '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
            '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
          ),
        ),
        isTrue,
      );
    });

    test('TEST 3：两字节消息的签名通过验证', () {
      expect(
        verifyEd25519Signature(
          publicKey: _hex(
            'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
          ),
          message: _hex('af82'),
          signature: _hex(
            '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac'
            '18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
          ),
        ),
        isTrue,
      );
    });

    test('改动的消息、签名与错配的公钥都不通过', () {
      final publicKey = _hex(
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      final signature = _hex(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(
        verifyEd25519Signature(
          publicKey: publicKey,
          message: utf8.encode('changed'),
          signature: signature,
        ),
        isFalse,
      );
      final tampered = Uint8List.fromList(signature)..[0] ^= 0x01;
      expect(
        verifyEd25519Signature(
          publicKey: publicKey,
          message: const [],
          signature: tampered,
        ),
        isFalse,
      );
      expect(
        verifyEd25519Signature(
          publicKey: _hex(
            'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
          ),
          message: const [],
          signature: signature,
        ),
        isFalse,
      );
    });

    test('长度不对的公钥与签名直接拒绝', () {
      expect(
        verifyEd25519Signature(
          publicKey: const [1, 2, 3],
          message: const [],
          signature: List<int>.filled(64, 0),
        ),
        isFalse,
      );
      expect(
        verifyEd25519Signature(
          publicKey: List<int>.filled(32, 0),
          message: const [],
          signature: List<int>.filled(63, 0),
        ),
        isFalse,
      );
    });
  });

  group('发布清单签名', () {
    // 固定向量：私钥由测试用 Python 的 cryptography 生成，只用于核对验证实现；
    // 签名对象是下面这个 sha256 的小写十六进制字符串本身。
    const publicKey = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
    const sha256 =
        '70248747c7a1f9260ad35da8de214707a737e8bec4c83cea33284b563a534c54';
    const signature =
        'uMue4GLdwOj+kjMRptW2enuFxEee147uLv9by9octtcpOmUs8YOo+LvdLkwkKbsXJNu3Z'
        'BGCivyZVPualz00CA==';

    test('对 sha256 十六进制字符串的签名通过验证', () {
      expect(
        verifyReleaseSignature(
          sha256: sha256,
          signature: signature,
          publicKeyBase64: publicKey,
        ),
        isTrue,
      );
      expect(
        verifyReleaseSignature(
          sha256: sha256.toUpperCase(),
          signature: signature,
          publicKeyBase64: publicKey,
        ),
        isTrue,
      );
    });

    test('sha256 改动、公钥未配置或格式不合法时不通过', () {
      expect(
        verifyReleaseSignature(
          sha256: '${sha256.substring(0, 63)}0',
          signature: signature,
          publicKeyBase64: publicKey,
        ),
        isFalse,
      );
      expect(
        verifyReleaseSignature(
          sha256: sha256,
          signature: signature,
          publicKeyBase64: '',
        ),
        isFalse,
      );
      expect(
        verifyReleaseSignature(
          sha256: sha256,
          signature: 'not-base64!',
          publicKeyBase64: publicKey,
        ),
        isFalse,
      );
      expect(
        verifyReleaseSignature(
          sha256: sha256,
          signature: signature,
          publicKeyBase64: 'short',
        ),
        isFalse,
      );
    });

    test('未注入公钥时默认公钥为空，校验返回 false', () {
      expect(zhixinReleasePublicKey, isEmpty);
      expect(releasePublicKeyConfigured, isFalse);
      expect(
        verifyReleaseSignature(sha256: sha256, signature: signature),
        isFalse,
      );
    });
  });
}
