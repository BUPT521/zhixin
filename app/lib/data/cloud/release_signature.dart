import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 发布清单签名用的内置公钥：构建时用
/// `--dart-define=ZHIXIN_RELEASE_PUBLIC_KEY=<base64 的 32 字节 raw 公钥>` 注入。
///
/// 没有注入时跳过签名校验，只核对地址是 https、sha256 是 64 位小写十六进制。
const String zhixinReleasePublicKey = String.fromEnvironment(
  'ZHIXIN_RELEASE_PUBLIC_KEY',
  defaultValue: '',
);

/// 是否配置了发布公钥；界面据此说明签名校验是已执行还是跳过。
bool get releasePublicKeyConfigured => zhixinReleasePublicKey.trim().isNotEmpty;

/// 校验发布清单里对 sha256 小写十六进制字符串的 Ed25519 签名。
///
/// 签名对象按契约是 sha256 的小写十六进制字符串本身（64 个字符），不是安装包
/// 字节。公钥、签名不是合法的 base64 或长度不对时一律返回 false，调用方据此
/// 不提示更新。
bool verifyReleaseSignature({
  required String sha256,
  required String signature,
  String? publicKeyBase64,
}) {
  final key = (publicKeyBase64 ?? zhixinReleasePublicKey).trim();
  if (key.isEmpty || sha256.trim().isEmpty || signature.trim().isEmpty) {
    return false;
  }
  final Uint8List publicKey;
  final Uint8List signatureBytes;
  try {
    publicKey = base64.decode(key);
    signatureBytes = base64.decode(signature.trim());
  } on FormatException {
    return false;
  }
  return verifyEd25519Signature(
    publicKey: publicKey,
    message: utf8.encode(sha256.trim().toLowerCase()),
    signature: signatureBytes,
  );
}

/// RFC 8032 的 Ed25519 验证，只做验证，不需要私钥。
///
/// 实现里只有椭圆曲线加法、倍点与标量乘，加上 `package:crypto` 的 SHA-512；
/// 发布校验只需要一个签名算法，不为它引入新的第三方依赖。
bool verifyEd25519Signature({
  required List<int> publicKey,
  required List<int> message,
  required List<int> signature,
}) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final rBytes = signature.sublist(0, 32);
  final s = _fromLittleEndian(signature.sublist(32, 64));
  // S 必须严格小于群的阶，否则签名可被平凡地变形。
  if (s >= _order) return false;
  final publicPoint = _decodePoint(publicKey);
  final rPoint = _decodePoint(rBytes);
  if (publicPoint == null || rPoint == null) return false;
  final digest = sha512.convert([...rBytes, ...publicKey, ...message]).bytes;
  final k = _fromLittleEndian(digest) % _order;
  // RFC 8032 第 5.1.7 节的验证等式，两边都乘上余因子 8。
  final left = _mulByCofactor(_scalarMul(_basePoint, s));
  final right = _mulByCofactor(_pointAdd(rPoint, _scalarMul(publicPoint, k)));
  return _samePoint(left, right);
}

// ---- 椭圆曲线运算 ---------------------------------------------------------
//
// 曲线是 edwards25519：-x^2 + y^2 = 1 + d·x^2·y^2。点用扩展坐标
// (X, Y, Z, T)，x = X/Z、y = Y/Z、T = XY/Z，加法与倍点按 RFC 8032 的公式
// 直接写，避免再做仿射坐标的求逆。

final BigInt _prime = BigInt.parse(
  '7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed',
  radix: 16,
);

/// 群的阶 L = 2^252 + 27742317777372353535851937790883648493。
final BigInt _order = BigInt.parse(
  '1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed',
  radix: 16,
);

final BigInt _d = _mod(-BigInt.from(121665) * _inverse(BigInt.from(121666)));

final BigInt _sqrtMinusOne = _modPow(
  BigInt.two,
  (_prime - BigInt.one) ~/ BigInt.from(4),
);

final _Point _basePoint = _Point(
  BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202',
  ),
  BigInt.parse(
    '46316835694926478169428394003475163141307993866256225615783033603165251855960',
  ),
  BigInt.one,
);

BigInt _mod(BigInt value) {
  final reduced = value % _prime;
  return reduced.isNegative ? reduced + _prime : reduced;
}

BigInt _inverse(BigInt value) => _modPow(value, _prime - BigInt.two);

BigInt _modPow(BigInt base, BigInt exponent) {
  var result = BigInt.one;
  var factor = _mod(base);
  var remaining = exponent;
  while (remaining > BigInt.zero) {
    if (remaining.isOdd) result = _mod(result * factor);
    factor = _mod(factor * factor);
    remaining >>= 1;
  }
  return result;
}

/// 开方 `sqrt(u/v)`；不存在时返回 null。
BigInt? _sqrtRatio(BigInt u, BigInt v) {
  final v3 = _mod(v * v * v);
  final v7 = _mod(v3 * v3 * v);
  final power = (_prime - BigInt.from(5)) ~/ BigInt.from(8);
  var x = _mod(u * v3 * _modPow(_mod(u * v7), power));
  final check = _mod(v * x * x);
  if (check == _mod(u)) return x;
  if (check == _mod(-u)) return _mod(x * _sqrtMinusOne);
  return null;
}

BigInt _fromLittleEndian(List<int> bytes) {
  var result = BigInt.zero;
  for (var index = bytes.length - 1; index >= 0; index--) {
    result = (result << 8) | BigInt.from(bytes[index]);
  }
  return result;
}

/// 解压 32 字节的压缩点：最低位的符号位决定 x 的奇偶；不是合法点时返回 null。
_Point? _decodePoint(List<int> bytes) {
  if (bytes.length != 32) return null;
  final raw = Uint8List.fromList(bytes);
  final sign = raw[31] >> 7;
  raw[31] &= 0x7f;
  final y = _fromLittleEndian(raw);
  if (y >= _prime) return null;
  final ySquared = _mod(y * y);
  final u = _mod(ySquared - BigInt.one);
  final v = _mod(_d * ySquared + BigInt.one);
  var x = _sqrtRatio(u, v);
  if (x == null) return null;
  if (x == BigInt.zero && sign == 1) return null;
  final wantsOdd = sign == 1;
  if (x.isOdd != wantsOdd) x = _mod(-x);
  return _Point(x, y, BigInt.one);
}

class _Point {
  const _Point(this.x, this.y, this.z) : t = null;

  const _Point.full(this.x, this.y, this.z, this.t);

  final BigInt x;
  final BigInt y;
  final BigInt z;

  /// 扩展坐标里的 T = XY/Z；只在完整构造时保存，恒等点用 null 表示 0。
  final BigInt? t;

  BigInt get tValue => t ?? _mod(x * y);
}

_Point _pointAdd(_Point a, _Point b) {
  final aValue = _mod((a.y - a.x) * (b.y - b.x));
  final bValue = _mod((a.y + a.x) * (b.y + b.x));
  final cValue = _mod(_d * a.tValue * b.tValue * BigInt.two);
  final dValue = _mod(a.z * b.z * BigInt.two);
  final e = _mod(bValue - aValue);
  final f = _mod(dValue - cValue);
  final g = _mod(dValue + cValue);
  final h = _mod(bValue + aValue);
  return _Point.full(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
}

_Point _pointDouble(_Point point) {
  final a = _mod(point.x * point.x);
  final b = _mod(point.y * point.y);
  final c = _mod(point.z * point.z * BigInt.two);
  final d = _mod(-a);
  final e = _mod((point.x + point.y) * (point.x + point.y) - a - b);
  final g = _mod(d + b);
  final f = _mod(g - c);
  final h = _mod(d - b);
  return _Point.full(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
}

_Point _scalarMul(_Point point, BigInt scalar) {
  var result = _Point.full(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var addend = point;
  var remaining = scalar;
  while (remaining > BigInt.zero) {
    if (remaining.isOdd) result = _pointAdd(result, addend);
    addend = _pointDouble(addend);
    remaining >>= 1;
  }
  return result;
}

/// 乘上余因子 8：连续三次倍点。
_Point _mulByCofactor(_Point point) =>
    _pointDouble(_pointDouble(_pointDouble(point)));

bool _samePoint(_Point a, _Point b) =>
    _mod(a.x * b.z - b.x * a.z) == BigInt.zero &&
    _mod(a.y * b.z - b.y * a.z) == BigInt.zero;
