import 'package:material_ui/material_ui.dart';

import '../platform/theme_mode_store.dart';

/// 当前外观与保存动作；MaterialApp 监听它，设置页通过 [select] 修改。
///
/// 设置页与启动装配共用同一个实例，所以改完外观不必重启。
class ThemeModeController extends ValueNotifier<ThemeMode> {
  ThemeModeController({ThemeMode initial = ThemeMode.system, this.store})
    : super(initial);

  final ThemeModeStore? store;

  /// 启动前读一次，外观在第一帧就生效；文件缺失或内容不认识时跟随系统。
  static Future<ThemeModeController> load(ThemeModeStore store) async {
    final stored = await store.read();
    return ThemeModeController(initial: _parse(stored), store: store);
  }

  /// 先写文件再换主题，写失败时保持原样，由调用方提示。
  Future<void> select(ThemeMode mode) async {
    if (mode == value) return;
    await store?.write(mode.name);
    value = mode;
  }

  static ThemeMode _parse(String? stored) {
    for (final mode in ThemeMode.values) {
      if (mode.name == stored) return mode;
    }
    return ThemeMode.system;
  }
}
