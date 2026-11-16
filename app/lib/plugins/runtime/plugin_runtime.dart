/// 插件运行时：注册第一方插件、读写启停状态、在调用点核对权限，并向提示词
/// 提供当前启用的人格段落。
///
/// 运行时只认清单与元数据库，不加载第三方代码，也不直接访问数据层与界面；
/// 未知插件标识一律拒绝。启停状态与人格配置写在 `app_meta`，不形成提交。
library;

import '../../domain/models/buddy_protocol.dart' show BuddyPersona;
import '../persona/persona_catalog.dart';
import 'plugin.dart';
import 'plugin_access.dart';
import 'plugin_manifest.dart';
import 'plugin_metadata_store.dart';

/// 启停状态的设置键前缀：完整键为 `plugin.enabled.<插件标识>`，值为 `1` 或 `0`。
const pluginEnabledKeyPrefix = 'plugin.enabled.';

/// 某个插件的启停设置键。
String pluginEnabledKey(String pluginId) => '$pluginEnabledKeyPrefix$pluginId';

/// 注册失败：清单不合格、标识重复或同时注册了多个人格插件。
final class PluginRegistrationException implements Exception {
  const PluginRegistrationException(this.pluginId, this.messages);

  final String pluginId;
  final List<String> messages;

  @override
  String toString() => '插件 $pluginId 无法注册：${messages.join('；')}';
}

/// 运行时没有注册这个标识；查询、启停与权限判断都拒绝，不返回默认值。
final class PluginNotFound implements Exception {
  const PluginNotFound(this.id);

  final String id;

  @override
  String toString() => '没有注册这个插件：$id';
}

/// 启用插件时启动入口失败；启停状态不写入，保持原来的值。
final class PluginStartException implements Exception {
  const PluginStartException(this.pluginId, this.cause);

  final String pluginId;
  final Object cause;

  @override
  String toString() => '插件 $pluginId 启动失败：$cause';
}

/// 第一方插件的注册表与启停状态；应用根只建一份。
class PluginRuntime {
  PluginRuntime({
    required this.store,
    required this.personas,
    required Iterable<FirstPartyPlugin> plugins,
  }) {
    for (final plugin in plugins) {
      _register(plugin);
    }
  }

  final PluginMetadataStore store;

  /// 人格清单与启用项；插件运行时只在启用了人格插件时把当前人格交给提示词。
  final PersonaCatalog personas;

  final Map<String, FirstPartyPlugin> _plugins = {};
  final Map<String, PluginAccess> _access = {};
  final Set<String> _enabled = {};
  final Set<String> _running = {};
  final List<PluginStartException> _startFailures = [];
  FirstPartyPlugin? _personaPlugin;

  /// 注册的插件，按注册顺序排列。
  List<FirstPartyPlugin> get plugins => List.unmodifiable(_plugins.values);

  /// 装载阶段的启动失败；启用状态保持启用，失败原因供诊断与界面说明。
  List<PluginStartException> get startFailures =>
      List.unmodifiable(_startFailures);

  /// 按标识取插件；未知标识拒绝。
  FirstPartyPlugin byId(String id) {
    final plugin = _plugins[id];
    if (plugin == null) throw PluginNotFound(id);
    return plugin;
  }

  /// 插件是否启用；未知标识拒绝。
  bool isEnabled(String id) {
    byId(id);
    return _enabled.contains(id);
  }

  /// 清单声明的权限；未知标识拒绝。
  PluginPermissions permissionsOf(String id) => byId(id).manifest.permissions;

  /// 从 `app_meta` 读取启停状态与人格配置；启动已启用的插件。
  ///
  /// 应用启动、整库恢复与清空之后调用；重复调用只重读状态，已经在运行的插件
  /// 不再次启动。
  Future<void> load() async {
    await personas.load();
    _enabled.clear();
    _startFailures.clear();
    for (final plugin in _plugins.values) {
      final id = plugin.manifest.id;
      final stored = await store.read(pluginEnabledKey(id));
      // 没有写过启停状态时默认启用：第一方插件随版本提供，用户明确停用才写 0。
      if (stored == '0') continue;
      _enabled.add(id);
      if (_running.contains(id)) continue;
      try {
        await plugin.start(_access[id]!);
        _running.add(id);
      } catch (error) {
        _startFailures.add(PluginStartException(id, error));
      }
    }
  }

  /// 恢复、清空或撤销之后重读状态；与 [load] 相同。
  Future<void> reload() => load();

  /// 启用或停用一个插件；未知标识拒绝，启动失败时不写入新状态。
  Future<void> setEnabled(String id, bool enabled) async {
    final plugin = byId(id);
    if (enabled) {
      if (!_running.contains(id)) {
        try {
          await plugin.start(_access[id]!);
        } catch (error) {
          throw PluginStartException(id, error);
        }
        _running.add(id);
      }
      _enabled.add(id);
      _startFailures.removeWhere((failure) => failure.pluginId == id);
    } else {
      _enabled.remove(id);
      _running.remove(id);
    }
    await store.write(pluginEnabledKey(id), enabled ? '1' : '0');
  }

  /// 人格插件是否启用；没有注册人格插件时为空。
  bool get personaPluginEnabled {
    final plugin = _personaPlugin;
    return plugin != null && _enabled.contains(plugin.manifest.id);
  }

  /// 当前启用的人格；人格插件停用或没有启用人格时为空。
  ///
  /// 提示词构建只读这一段；停用之后下一次请求立即没有人格段落。
  BuddyPersona? get activePersonaPrompt {
    if (!personaPluginEnabled) return null;
    final persona = personas.active;
    if (persona == null || persona.text.trim().isEmpty) return null;
    return BuddyPersona(name: persona.name, text: persona.text);
  }

  /// 回答前重新读一次 `app_meta` 再取当前人格。
  ///
  /// 提示词构建走这里：整库恢复或清空之后即使页面还没重读，下一轮回答也用
  /// 恢复后的状态，不继续带旧人格。
  Future<BuddyPersona?> loadActivePersonaForPrompt() async {
    await personas.load();
    return activePersonaPrompt;
  }

  /// 切换当前启用的人格；传空表示停用。未知人格标识由人格清单拒绝。
  Future<void> setActivePersona(String? id) async {
    if (_personaPlugin == null) throw const PluginNotFound('persona');
    await personas.setActive(id);
  }

  void _register(FirstPartyPlugin plugin) {
    final manifest = plugin.manifest;
    final errors = manifest.validate();
    if (errors.isNotEmpty) {
      throw PluginRegistrationException(manifest.id, errors);
    }
    if (_plugins.containsKey(manifest.id)) {
      throw PluginRegistrationException(manifest.id, ['插件标识重复：${manifest.id}']);
    }
    if (manifest.kind == PluginKind.persona) {
      if (_personaPlugin != null) {
        throw PluginRegistrationException(manifest.id, ['插件运行时只接受一个人格插件']);
      }
      _personaPlugin = plugin;
    }
    _plugins[manifest.id] = plugin;
    _access[manifest.id] = PluginAccess(manifest: manifest);
  }
}
