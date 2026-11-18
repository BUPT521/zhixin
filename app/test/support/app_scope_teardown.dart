import 'dart:io';

import 'package:zhixin/app_scope.dart';

/// 关掉用例打开的应用根，再删除它的临时目录。
///
/// 应用根会在后台 isolate 里打开 zvec 索引；索引句柄关闭之前，Windows 不允许
/// 删除目录里的索引文件，所以只关业务库时删除临时目录会报“另一个程序正在
/// 使用此文件”。这里先关索引与业务库，删除仍被占用时等一会儿重试，最后仍然
/// 删不掉就留给系统清理临时目录，不让收尾的目录删除盖过用例本身的结果。
Future<void> closeAppScope(AppScopeState? scope, Directory directory) async {
  await scope?.library.searchIndex.close();
  await scope?.testing.db.close();
  for (var attempt = 0; attempt <= 20; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 20) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
