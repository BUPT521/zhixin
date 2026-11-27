import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/db/app_database.dart' show zhixinDbFileName, zhixinDbSideFiles;
import '../data/vector/vector_index.dart' show memoryIndexDirectoryName;
import '../domain/rules/attachments.dart' show questionImagesDirName;
import 'app_paths.dart' show AppPaths;

/// 0.2.0 的单体布局在应用私有目录根下放库、图片、检索索引与恢复点
/// （[ADR-0056](../../../docs/adr/0056-本机数据按账号分空间.md)）。
///
/// 0.3.0 起每个账号一个空间目录，根下的这些条目不再被读取。升级时按
/// [ADR-0017](../../../docs/adr/0017-表结构变化仍清空数据.md) 的数据处置删除，
/// 避免旧的学习记录、图片与整库备份留在设备上，而“清除全部数据”只清当前空间。
/// 目录名从 [AppPaths] 与各自的定义处取，这里不再抄一份。
const List<String> legacyLayoutDirectories = [
  questionImagesDirName,
  AppPaths.vectorIndexDirName,
  memoryIndexDirectoryName,
  AppPaths.restorePointsDirName,
  AppPaths.dataVersionsDirName,
];

/// 0.2.0 上传或下载云端备份时留在根目录的临时包，以及恢复中断留下的目录与
/// 阶段记录。它们都不属于当前空间，也都不再读取。
const List<String> legacyLayoutPrefixes = [
  'cloud_backup_',
  'cloud_download_',
  '.restore-',
];

/// 旧布局清理的完成标记：第一次清完之后写进设备根目录，之后的启动读到它就
/// 不再扫根目录。删不掉的条目这一轮不写标记，下次启动重试。
const String legacyLayoutMarkerName = 'legacy_layout.cleaned';

/// 删除一条旧布局条目失败时的回调；启动流程用它写一条本机诊断，不阻断启动。
typedef LegacyLayoutFailure = void Function(
  String name,
  Object error,
  StackTrace stack,
);

/// 删除 0.2.0 留在应用私有目录根下的学习数据，返回删掉的条目名。
///
/// 只处理 0.2.0 的固定条目与三个前缀，不碰当前布局的 `spaces/`、
/// `active_space`、`cloud.json`、诊断与崩溃记录、匿名上报状态；重复调用不会
/// 重复删除，也不会因为某一项被占用而放弃其余条目。清理成功之后写
/// [legacyLayoutMarkerName]，之后的启动直接返回，不再每次扫一遍根目录。
/// 启动时在打开任何数据库之前调用。
Future<Set<String>> deleteLegacyLayoutData(
  String filesDir, {
  LegacyLayoutFailure? onFailure,
}) async {
  final root = Directory(filesDir);
  if (!await root.exists()) return <String>{};

  final marker = File(p.join(root.path, legacyLayoutMarkerName));
  if (await marker.exists()) return <String>{};

  final removed = <String>{};
  var failed = false;
  Future<void> remove(String name, String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
      removed.add(name);
    } catch (error, stack) {
      failed = true;
      onFailure?.call(name, error, stack);
    }
  }

  for (final suffix in const ['', ...zhixinDbSideFiles, '.incoming']) {
    await remove(
      '$zhixinDbFileName$suffix',
      p.join(root.path, '$zhixinDbFileName$suffix'),
    );
  }
  // 0.2.0 的附件缓存重建标记；附件目录随 legacyLayoutDirectories 一起删除。
  await remove(
    'attachment_cache.pending',
    p.join(root.path, 'attachment_cache.pending'),
  );
  for (final name in legacyLayoutDirectories) {
    await remove(name, p.join(root.path, name));
  }
  await for (final entity in root.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (!legacyLayoutPrefixes.any(name.startsWith)) continue;
    await remove(name, entity.path);
  }
  if (!failed) {
    try {
      await marker.writeAsString('1', flush: true);
    } catch (error, stack) {
      // 标记写不进去只影响下一次启动仍扫一遍，不阻断启动。
      onFailure?.call(legacyLayoutMarkerName, error, stack);
    }
  }
  return removed;
}
