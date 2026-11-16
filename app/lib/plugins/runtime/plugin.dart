/// 第一方插件接口：随应用编译，运行时按清单注册，不加载第三方代码。
///
/// 能力插件与人格插件共用这个接口；人格插件只有一段文本，启动入口不做任何事。
/// 插件不持有数据库连接，也不发网络请求，需要外部能力时只能用运行时交给它的
/// [PluginAccess]。
library;

import 'plugin_access.dart';
import 'plugin_manifest.dart';

/// 一个随应用编译的插件。
abstract class FirstPartyPlugin {
  /// 清单在编译期固定；运行时按它校验、注册、显示权限与写启停状态。
  PluginManifest get manifest;

  /// 能力插件在启用时注册工具与入口；人格插件没有启动动作。
  ///
  /// 停用只改运行时的启停状态，插件提供的入口按状态消失，不再调用这里。
  Future<void> start(PluginAccess access);
}
