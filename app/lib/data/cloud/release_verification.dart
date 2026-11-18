/// 发布清单的哈希与签名核对：纯函数，便于单元测试覆盖各类不通过的情况。
///
/// 签名对象是安装包 SHA-256 的小写十六进制字符串本身（64 个 ASCII 字节），
/// 不是安装包内容；清单里的 `signature` 是 64 字节 Ed25519 签名的 base64。
/// 公钥以 PEM 内置在应用里，见 `platform/release_signing_key.dart`。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// 安装包字节的 SHA-256 小写十六进制，与清单里的 `sha256` 使用同一表示。
String releaseSha256Hex(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// 清单里的 `sha256` 是否是 64 位小写十六进制。
bool isReleaseSha256Hex(String value) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(value.trim());

/// 用内置公钥核对清单签名；公钥为空、格式不对或签名不匹配时都返回 false。
///
/// [sha256Hex] 是清单里的哈希，[signatureBase64] 是清单里的签名。验签失败一律
/// 按不提示更新处理，调用方不区分具体原因。
Future<bool> verifyReleaseSignature({
  required String publicKeyPem,
  required String sha256Hex,
  required String signatureBase64,
}) async {
  final publicKeyBytes = _ed25519PublicKeyBytes(publicKeyPem);
  if (publicKeyBytes == null) return false;
  final hash = sha256Hex.trim().toLowerCase();
  if (!isReleaseSha256Hex(hash)) return false;
  final signatureBytes = _base64Bytes(signatureBase64);
  if (signatureBytes == null || signatureBytes.length != 64) return false;
  try {
    return await Ed25519().verify(
      // 签名对象是哈希字符串本身，不加换行、不做二次哈希。
      utf8.encode(hash),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    // 畸形公钥或签名在底层实现里可能抛出：按验签失败处理，不向界面抛错。
    return false;
  }
}

/// 从 PEM 里取出 32 字节 Ed25519 公钥；只接受 SPKI 结构或裸 32 字节 base64。
///
/// Ed25519 的 SubjectPublicKeyInfo 前缀固定，长度 44 字节；PEM 的换行与首尾
/// 标签在这里去掉，交给 base64 解码。
List<int>? _ed25519PublicKeyBytes(String pem) {
  final body = pem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s'), '');
  if (body.isEmpty) return null;
  final der = _base64Bytes(body);
  if (der == null) return null;
  if (der.length == 32) return der;
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
  if (der.length != 44) return null;
  for (var i = 0; i < prefix.length; i++) {
    if (der[i] != prefix[i]) return null;
  }
  return der.sublist(prefix.length);
}

List<int>? _base64Bytes(String value) {
  try {
    return base64.decode(value.trim());
  } catch (_) {
    return null;
  }
}
