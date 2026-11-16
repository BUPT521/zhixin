import 'package:zhixin/plugins/runtime/plugin_metadata_store.dart';

/// 测试用的内存设置存储：记录写入次数，便于断言某次调用没有写设置。
class MemoryPluginMetadataStore implements PluginMetadataStore {
  MemoryPluginMetadataStore([Map<String, String>? initial])
    : values = {...?initial};

  final Map<String, String> values;

  /// 写入次数；读取不计数。
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    writes++;
  }
}
