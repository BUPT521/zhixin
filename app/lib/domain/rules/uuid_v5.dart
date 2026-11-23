/// 确定性标识：RFC 4122 UUIDv5（SHA-1，命名空间加名字）。
///
/// 与 `uuid_v7.dart` 并列：v7 用在“每次动作生成一个新身份”的地方，v5 用在
/// “同一对输入永远得到同一个身份”的地方，用来去重。ADR-0053 决定第 4 条的基线
/// 提交 `uid` 与审查 S17 的 `memory_usage.id` 都是同一思路：编号由对象身份算
/// 出来，重发或重复汇总得到同一个值，长度固定 36 字符，与业务表主键的形状一
/// 致。UUIDv5 的底层是 SHA-1，这里只用来去重，不涉及安全。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 知新自用的 UUIDv5 命名空间。
///
/// 它是 RFC 4122 的 DNS 命名空间与名字 `zhixin` 生成的 UUIDv5，一次性算好之后
/// 固定在代码里：同一套命名空间不用于其他用途，名字不同就不会与别的身份相撞。
const String zhixinUuidV5Namespace = 'd7dd3b80-3d65-5a31-bf26-da4aa97e2439';

/// 按 RFC 4122 生成 UUIDv5。
///
/// 命名空间的 16 字节与名字的 UTF-8 字节拼接后取 SHA-1，前 16 字节写入版本位
/// （0101）与变体位（10xx），输出 36 位小写文本。[namespace] 是 36 位 UUID
/// 文本，[name] 是这次身份的名字，同一对输入永远得到同一个标识；名字要区分多
/// 个字段时由调用方自己约定分隔符。命名空间不是 UUID 文本时抛出
/// [ArgumentError]。
String uuidV5(String name, {String namespace = zhixinUuidV5Namespace}) {
  final hash = sha1.convert([
    ..._namespaceBytes(namespace),
    ...utf8.encode(name),
  ]);
  final bytes = Uint8List.fromList(hash.bytes.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  // 变体位：RFC 9562 的 10xx。
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return _format(bytes);
}

Uint8List _namespaceBytes(String namespace) {
  final compact = namespace.replaceAll('-', '');
  if (compact.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
    throw ArgumentError.value(namespace, 'namespace', '命名空间不是 UUID 文本');
  }
  return Uint8List.fromList([
    for (var index = 0; index < 32; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

String _format(Uint8List bytes) {
  final buffer = StringBuffer();
  for (var index = 0; index < bytes.length; index++) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      buffer.write('-');
    }
    buffer.write(bytes[index].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
