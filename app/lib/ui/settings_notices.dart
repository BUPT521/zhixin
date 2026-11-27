import 'package:flutter/widgets.dart';

import 'workspace_widgets.dart';

/// 设置页的一段操作：结果挂在触发它的那一段卡片下方，长页里也能就近看到。
enum SettingsArea {
  model,
  developer,
  learning,
  appearance,
  updates,
  diagnostics,
  danger,
}

/// 一段操作的最近一次结果：成功是一行小字，失败用错误描边的就地说明。
class SettingsResult {
  const SettingsResult(this.message, {this.failed = false});

  final String message;
  final bool failed;
}

/// 设置页的提示状态：每段操作的最近一次结果与首读失败的说明。
///
/// 页面只调用 [report]、[clear] 与 [setLoadFailure]，读 [loadFailure] 与
/// [widgetFor]；呈现统一交给批 1 的 [ResultNotice]，页面不再各拼一份。
class SettingsNotices extends ChangeNotifier {
  final Map<SettingsArea, SettingsResult> _results = {};
  String? _loadFailure;

  /// 第一次读取设置项失败时的说明；重新订阅之后清除。
  String? get loadFailure => _loadFailure;

  /// 某一段操作现在有没有结果；测试与页面据此决定留不留空位。
  bool has(SettingsArea area) => _results.containsKey(area);

  /// 记下某一段操作的最近一次结果，替换该段上一次的结果。
  void report(SettingsArea area, String message, {bool failed = false}) {
    _results[area] = SettingsResult(message, failed: failed);
    notifyListeners();
  }

  /// 撤掉某一段操作的结果；下一次操作之前不再显示。
  void clear(SettingsArea area) {
    if (_results.remove(area) == null) return;
    notifyListeners();
  }

  void setLoadFailure(String message) {
    if (_loadFailure == message) return;
    _loadFailure = message;
    notifyListeners();
  }

  void clearLoadFailure() {
    if (_loadFailure == null) return;
    _loadFailure = null;
    notifyListeners();
  }

  /// 某一段操作的结果控件；没有结果时为空。
  Widget? widgetFor(SettingsArea area) {
    final result = _results[area];
    if (result == null) return null;
    return ResultNotice(message: result.message, failed: result.failed);
  }
}
