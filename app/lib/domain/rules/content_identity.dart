import 'dart:convert';

import 'package:crypto/crypto.dart';

String contentHash(List<int> bytes) => sha256.convert(bytes).toString();

/// 调用者按固定次序提供已规范化的字段，使同类内容获得相同标识。
String contentId(String kind, List<Object?> fields) =>
    '$kind:${contentHash(utf8.encode(jsonEncode(fields)))}';

Iterable<T> uniqueById<T>(Iterable<T> items, Object Function(T) id) sync* {
  final seen = <Object>{};
  for (final item in items) {
    if (seen.add(id(item))) yield item;
  }
}
