import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 数据版本监听：三栏页只在活动时重读，页面销毁时自动退订。
///
/// 安排页、现在页与记录页原先各写一份 `_watchDataVersion` 与 `_dataVersion`
/// 字段；这里统一订阅、活动判断与退订，页面只实现收到变化后要做什么。
mixin DataVersionWatcher<T extends StatefulWidget> on State<T> {
  ValueListenable<int>? _watchedVersion;

  /// 页面当前是否活动；切走的三栏页不响应数据版本变化。
  bool get dataVersionActive => true;

  /// 数据版本变化且页面仍然活动时调用。
  void onDataVersionChanged();

  /// 订阅新的数据版本；应用根替换对象时重新订阅。
  void watchDataVersion(ValueListenable<int> version) {
    if (identical(version, _watchedVersion)) return;
    _watchedVersion?.removeListener(_handleDataVersion);
    _watchedVersion = version;
    version.addListener(_handleDataVersion);
  }

  void _handleDataVersion() {
    if (!mounted || !dataVersionActive) return;
    onDataVersionChanged();
  }

  @override
  void dispose() {
    _watchedVersion?.removeListener(_handleDataVersion);
    super.dispose();
  }
}
