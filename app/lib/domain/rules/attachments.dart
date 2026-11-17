import 'dart:convert';

import 'package:path/path.dart' as p;

/// 题目与讨论图片的目录名；导出包与数据库路径都以它为准。
const String questionImagesDirName = 'question_images';

/// 解析数据库里的图片字段：值是文件名的 JSON 数组，空值与坏值都按没有图片处理。
List<String> decodeStoredAttachmentPaths(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return {
      for (final item in decoded)
        if (item is String && item.trim().isNotEmpty) item,
    }.toList(growable: false);
  } catch (_) {
    return const [];
  }
}

/// 数据库里只存文件名，读取时再拼应用私有目录。
///
/// 这样导出包换到新设备恢复后，附件仍能按同一个相对位置找到。
String resolveAttachment(String filesDir, String stored) {
  final value = stored.trim();
  if (value.isEmpty) return value;
  return p.join(filesDir, questionImagesDirName, value);
}
