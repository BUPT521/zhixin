/// 插件运行时的生产装配：启停状态与人格配置经设置仓库写进 `app_meta`。
///
/// 插件代码不直接依赖数据层，运行时只看到 [PluginMetadataStore]；这一层适配器
/// 由应用根创建，写入沿用 `SettingsRepository.setMetadata`，不形成数据提交。
library;

import '../../domain/rules/time_policy.dart';
import '../../plugins/runtime/plugin_metadata_store.dart';
import 'settings_repository.dart';

/// 把设置仓库适配成插件运行时的元数据读写入口。
class SettingsPluginMetadataStore implements PluginMetadataStore {
  const SettingsPluginMetadataStore(this._settings, this._clock);

  final SettingsRepository _settings;
  final Clock _clock;

  @override
  Future<String?> read(String key) => _settings.metadata(key);

  @override
  Future<void> write(String key, String value) =>
      _settings.setMetadata(key, value, _clock());
}
