import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../application/active_report_service.dart';
import 'zhixin_dialog.dart';

/// 首次启动时说明匿名使用统计（ADR-0019），只出现一次。
///
/// 说明看过之前 [ActiveReportService] 不上报；用户在这里选择关闭时，设置页的
/// 开关同步关闭。默认保持开启，与 ADR-0019 的“默认开启、可以关闭”一致。
Future<void> showTelemetryNoticeIfNeeded(
  BuildContext context,
  ActiveReportService report,
) async {
  if (await report.noticeSeen()) return;
  if (!context.mounted) return;

  final keep = await showZhixinAlert<bool>(
    context: context,
    title: '关于使用统计',
    content: const Text(
      '知新在不登录时每天最多向服务端上报一次匿名活跃：一个随机安装标识、应用版本与平台，'
      '不含学习内容，也不与账号关联。登录之后由服务端按请求日期统计，不再单独上报。\n\n'
      '可以随时在“设置 → 使用统计”里关闭，关闭之后不再上报，已经上报的记录保留。',
    ),
    actions: [
      forui.FButton(
        variant: forui.FButtonVariant.ghost,
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.of(context).pop(false),
        child: const Text('关闭上报'),
      ),
      forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.of(context).pop(true),
        child: const Text('保持开启'),
      ),
    ],
  );
  // 关闭弹窗（返回空）按默认开启处理：用户已经看过说明，之后仍可在设置里关闭。
  await report.completeNotice(enabled: keep ?? true);
}
