import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/llm_config.dart' show SecretStore;
import '../data/atomic_file.dart';
import '../data/db/app_database.dart';
import '../domain/rules/attachments.dart';

/// 应用私有目录下的路径。图片与库分开存，导出时一起打包。
class AppPaths {
  const AppPaths(this.filesDir, {required this.cacheDir});

  /// 应用私有目录下的条目名：空间目录、空间指针与各派生目录。
  ///
  /// 0.2.0 的单体布局清理按这几个名字认条目，名字只在这里定义一处，
  /// platform/legacy_layout.dart 不另抄一份。
  static const String spacesDirName = 'spaces';
  static const String activeSpaceFileName = 'active_space';
  static const String spaceLabelFileName = 'space_label';
  static const String vectorIndexDirName = 'vector_index';
  static const String restorePointsDirName = 'restore_points';
  static const String dataVersionsDirName = 'data_versions';

  final String filesDir;

  /// 引擎日志等可随时清理的缓存目录。
  final String cacheDir;

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    return AppPaths(dir.path, cacheDir: cache.path);
  }

  String get dbPath => p.join(filesDir, zhixinDbFileName);

  /// 语义索引按模型分目录保存；丢失后可以从业务库重建。
  String get vectorIndexPath => p.join(filesDir, vectorIndexDirName);

  /// zvec 引擎的警告日志；不放进数据包，也不随业务数据导出。
  String get vectorLogPath => p.join(cacheDir, 'zvec_logs');

  String get imagesDir => p.join(filesDir, questionImagesDirName);

  String imagePath(String name) => p.join(imagesDir, name);

  /// 数据库里的图片名换成可读文件路径。
  String resolveImage(String stored) => resolveAttachment(filesDir, stored);

  Future<void> ensureDirectories() async {
    await Directory(imagesDir).create(recursive: true);
  }
}

typedef LocalSpace = ({String id, String label, int bytes});

/// 数据目录可以在关库之后整体改名或删除，设备目录始终保持打开。
class AppSpaces {
  const AppSpaces(this.device);

  static const local = 'local';
  static final _accountId = RegExp(r'^[a-f0-9]{32}$');
  final AppPaths device;

  String get _root => p.join(device.filesDir, AppPaths.spacesDirName);
  String get _pointer => p.join(device.filesDir, AppPaths.activeSpaceFileName);

  AppPaths pathsFor(String id) {
    if (id != local && !_accountId.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', '无效的本机空间标识');
    }
    return AppPaths(p.join(_root, id), cacheDir: device.cacheDir);
  }

  Directory _directory(String id) => Directory(pathsFor(id).filesDir);

  Future<String> lastOpened() async {
    try {
      final id = (await File(_pointer).readAsString()).trim();
      return id == local || _accountId.hasMatch(id) ? id : local;
    } on FileSystemException {
      return local;
    }
  }

  Future<void> open(String id, {bool adoptLocal = false, String? label}) async {
    final dir = _directory(id);
    await dir.parent.create(recursive: true);
    if (adoptLocal && id != local && !await dir.exists()) {
      final source = _directory(local);
      if (await source.exists()) await source.rename(dir.path);
      await source.create(recursive: true);
    }
    await dir.create(recursive: true);
    if (label != null && label.isNotEmpty) {
      await AtomicFile(p.join(dir.path, AppPaths.spaceLabelFileName))
          .writeText(label);
    }
    await AtomicFile(_pointer).writeText(id);
  }

  Future<void> delete(String id) async {
    final dir = _directory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<List<LocalSpace>> list() async {
    final result = <LocalSpace>[];
    final root = Directory(_root);
    if (!await root.exists()) return result;
    await for (final entry in root.list(followLinks: false)) {
      final id = p.basename(entry.path);
      if (entry is! Directory || (id != local && !_accountId.hasMatch(id))) {
        continue;
      }
      final labelFile = File(p.join(entry.path, AppPaths.spaceLabelFileName));
      final label = await labelFile.exists()
          ? await labelFile.readAsString()
          : id == local
          ? '本机空间'
          : '账号空间 ${id.substring(0, 8)}';
      var bytes = 0;
      await for (final file in entry.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is File) bytes += (await file.stat()).size;
      }
      result.add((id: id, label: label, bytes: bytes));
    }
    return result;
  }
}

/// 模型配置只含可见设置，访问令牌仍由设备的会话存储管理。
class SpaceModelSettings implements SecretStore {
  SpaceModelSettings(AppPaths paths)
    : _file = AtomicJsonFile(p.join(paths.filesDir, 'model_settings.json'));

  final AtomicJsonFile _file;

  @override
  Future<String?> read(String key) async =>
      (await _file.read())[key] as String?;

  @override
  Future<void> write(String key, String value) =>
      _file.update((data) => data[key] = value);

  @override
  Future<void> delete(String key) => _file.update((data) => data.remove(key));
}
