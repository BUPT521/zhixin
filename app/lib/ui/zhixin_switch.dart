import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 开关：Material 3 的 [Switch]，标签与说明排在左边。
///
/// 原来用 Forui 的 FSwitch，轨道是两端全圆的胶囊，与页面里其它 Material 控件
/// 的形状和按压反馈不一致；这里换成 Material 的开关，轨道、圆钮、状态层与
/// 点击区域都交给组件本身，颜色取主题里配好的 `switchTheme`。传了 [label]
/// 时整行都可以按，与 Forui 的写法一致；只有开关、没有可见标签时用
/// [semanticsLabel] 给读屏一个名称。
class ZhixinSwitch extends StatelessWidget {
  const ZhixinSwitch({
    super.key,
    required this.value,
    required this.onChange,
    this.label,
    this.description,
    this.semanticsLabel,
  });

  final bool value;

  /// 为空时开关不可用。
  final ValueChanged<bool>? onChange;

  final Widget? label;

  /// 显示在标签下面的说明。
  final Widget? description;

  /// 没有可见标签时的读屏名称。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    // Material 的开关要有一层 Material 才能画状态层；页面骨架是 Forui 的
    // FScaffold，整棵树里没有 Material，这里只补一层透明的，不影响底色与布局。
    final control = Material(
      type: MaterialType.transparency,
      child: Switch(value: value, onChanged: onChange),
    );
    final label = this.label;
    if (label == null) {
      // 开关自己的语义已经带状态与开关动作，这里只补一个名称。
      return MergeSemantics(
        child: Semantics(label: semanticsLabel, child: control),
      );
    }
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChange == null ? null : () => onChange!(!value),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTextStyle.merge(
                    style: theme.text.bodyMedium.copyWith(
                      color: theme.colors.onSurface,
                    ),
                    child: label,
                  ),
                  if (description case final description?) ...[
                    SizedBox(height: theme.space.xs),
                    DefaultTextStyle.merge(
                      style: theme.text.bodySmall.copyWith(
                        color: theme.colors.onSurfaceVariant,
                      ),
                      child: description,
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: theme.space.sm),
            control,
          ],
        ),
      ),
    );
  }
}
