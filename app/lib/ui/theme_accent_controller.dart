import 'package:material_ui/material_ui.dart';

import '../platform/theme_accent_store.dart';
import 'theme.dart';

/// 当前主题色与保存动作；MaterialApp 监听它，设置页通过 [select] 修改。
///
/// 与深浅色共用同一个生命周期：启动前读一次，之后改完立即生效，不必重启。
/// 读不到或存下的名称不认识时回到默认的蓝色。
class ThemeAccentController extends ValueNotifier<ZhixinAccent> {
  ThemeAccentController({ZhixinAccent initial = kDefaultAccent, this.store})
    : super(initial);

  final ThemeAccentStore? store;

  /// 启动前读一次，主题色在第一帧就生效。
  static Future<ThemeAccentController> load(ThemeAccentStore store) async {
    final stored = await store.read();
    return ThemeAccentController(
      initial: ZhixinAccent.parse(stored),
      store: store,
    );
  }

  /// 先写文件再换主题色，写失败时保持原样，由调用方提示。
  Future<void> select(ZhixinAccent accent) async {
    if (accent == value) return;
    await store?.write(accent.name);
    value = accent;
  }
}
