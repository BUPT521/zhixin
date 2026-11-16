/// 插件运行时的设置读写：插件启停状态与人格配置都写在 `app_meta`。
///
/// 运行时只依赖这个窄接口，不依赖数据库与界面；生产实现由应用根用
/// `SettingsRepository.setMetadata` 装配，测试换成内存实现。写入不形成数据提交。
library;

/// 按设置键读写一段文本；没有记录时返回空。
abstract interface class PluginMetadataStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}
