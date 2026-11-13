import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const _channel = MethodChannel('com.zhixin.app/data_package');

/// 暂存完整压缩包，再由 Android 分块写入用户选择的文档。
Future<String?> saveDataPackage({
  required String fileName,
  required Future<void> Function(String path) writePackage,
}) async {
  final temporary = await Directory.systemTemp.createTemp('zhixin-export-');
  try {
    final path = p.join(temporary.path, 'zhixin.zip');
    await writePackage(path);
    return await _channel.invokeMethod<String>('save', {
      'path': path,
      'fileName': fileName,
    });
  } finally {
    await temporary.delete(recursive: true);
  }
}
