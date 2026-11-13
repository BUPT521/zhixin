import 'package:path/path.dart' as p;

/// 题目与讨论图片的目录名；导出包与数据库路径都以它为准。
const String questionImagesDirName = 'question_images';

/// 数据库里只存文件名，读取时再拼应用私有目录。
///
/// 这样导出包换到新设备恢复后，附件仍能按同一个相对位置找到。
String resolveAttachment(String filesDir, String stored) {
  final value = stored.trim();
  if (value.isEmpty) return value;
  return p.join(filesDir, questionImagesDirName, value);
}

/// 保存图片后写入数据库的名字；只保留文件名，不带目录。
String storedAttachmentName(String path) => p.basename(path);
