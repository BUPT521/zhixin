import '../data/repository/settings_repository.dart';
import '../domain/rules/day_key.dart';
import '../domain/rules/time_policy.dart';

/// 每日截止小时与时间口径的唯一持有者。
///
/// 保存截止小时与撤销该提交之后都调用 [refresh] 从设置仓库重读；读到新值时换掉
/// 缓存并通知一次应用根推进数据代次，页面与共用服务下一次读取就拿到新口径。
/// 页面只读 [policy]，不再各自缓存截止小时。
class TimePolicyController {
  TimePolicyController({
    required this.settings,
    required this.clock,
    required this.onChanged,
  });

  final SettingsRepository settings;
  final Clock clock;

  /// 截止小时变化后的通知动作；应用根在这里推进数据代次，让页面重读一次。
  final void Function() onChanged;

  int _cutoffHour = defaultDayCutoffHour;

  /// 当前截止小时；启动时与保存、撤销之后都经 [refresh] 更新。
  int get cutoffHour => _cutoffHour;

  /// 当前时间口径；每次读取按最新截止小时构造，服务不缓存旧口径。
  TimePolicy get policy => TimePolicy(clock: clock, cutoffHour: _cutoffHour);

  /// 从设置仓库重读截止小时；没有变化时不通知。
  Future<void> refresh() async {
    final hour = requireDayCutoffHour(
      await settings.cutoffHour() ?? defaultDayCutoffHour,
    );
    if (hour == _cutoffHour) return;
    _cutoffHour = hour;
    onChanged();
  }
}
