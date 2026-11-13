import 'package:material_ui/material_ui.dart';

/// 启动时压住第一帧，让原生启动图直接接上首页。
///
/// 没有压住时 Flutter 在开库的这段等待里会先交出一张转圈页，用户看到的是
/// “原生启动图 → 转圈 → 首页”三段。压住之后引擎继续生产帧，但不把它们交给
/// 平台，启动图一直留在屏幕上；首屏数据就绪再放行，第一张真正的画面就是首页。
/// 首帧送达之后再调用就没有作用了，所以只能在 `runApp` 之前压。
class FirstFrameGate {
  FirstFrameGate._();

  static bool _deferred = false;

  /// 压住第一帧；重复调用只压一次，避免多算一次释放。
  static void defer() {
    if (_deferred) return;
    _deferred = true;
    WidgetsBinding.instance.deferFirstFrame();
  }

  /// 放行第一帧；没有压住时什么都不做，测试与不需要启动图的环境可以照常调用。
  static void release() {
    if (!_deferred) return;
    _deferred = false;
    WidgetsBinding.instance.allowFirstFrame();
  }

  /// 是否还压着第一帧；测试据此确认放行只做了一次。
  static bool get isDeferred => _deferred;

  /// 只给测试复位，让同一个进程里的用例互不影响。
  static void resetForTest() => _deferred = false;
}
