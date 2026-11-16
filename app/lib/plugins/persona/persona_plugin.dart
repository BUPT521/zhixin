/// 人格插件：挂在插件运行时上的纯文本插件，与能力插件共用设置页启停。
///
/// 它不声明任何权限，也没有要注册的工具或入口；启用状态与人格文本都由运行时
/// 与 `app_meta` 管理。
library;

import '../runtime/plugin.dart';
import '../runtime/plugin_access.dart';
import '../runtime/plugin_manifest.dart';
import 'persona_catalog.dart';

/// 人格插件的清单；人格只影响提示词，四项权限都不声明。
const personaManifest = PluginManifest(
  id: 'persona',
  name: '人格',
  version: '1.0.0',
  description: '用一段文本改变搭子的语气、称呼、讲解风格与篇幅倾向，不改变判分、引用与写入。',
  kind: PluginKind.persona,
);

/// 第一方人格插件；状态在 [PersonaCatalog] 里，插件本身无状态。
class PersonaPlugin implements FirstPartyPlugin {
  const PersonaPlugin(this.catalog);

  final PersonaCatalog catalog;

  @override
  PluginManifest get manifest => personaManifest;

  @override
  Future<void> start(PluginAccess access) async {
    // 人格插件只有一段文本，没有要注册的工具或入口。
  }
}
