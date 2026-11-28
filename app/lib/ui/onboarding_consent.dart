import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import 'navigation.dart';
import 'onboarding_controller.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_switch.dart';

/// 同意对话框里的选择；关掉对话框时为空。
class ConsentChoice {
  const ConsentChoice.agreed({required this.telemetryEnabled}) : agreed = true;

  const ConsentChoice.declined() : agreed = false, telemetryEnabled = false;

  final bool agreed;

  /// 同意时匿名使用统计的开关取值。
  final bool telemetryEnabled;
}

/// 弹出用户须知与隐私政策的同意对话框。
///
/// [update] 为真时标题写成“用户须知有更新”，用在已经用过应用的设备上；[telemetryEnabled]
/// 是匿名使用统计开关的初始值。点两份说明打开应用内页面，回来之后对话框还在，
/// 已经勾选的状态不丢。
Future<ConsentChoice?> showOnboardingConsent(
  BuildContext context, {
  required bool update,
  required bool telemetryEnabled,
}) => showZhixinDialog<ConsentChoice>(
  context: context,
  builder: (context) =>
      _ConsentDialog(update: update, telemetryEnabled: telemetryEnabled),
);

/// 引导里要联网之前先取得同意：已经同意过当前版本就直接放行，否则弹对话框并
/// 记下这次的选择。返回值是这次能不能继续联网。
///
/// [report] 为真时同意之后当场尝试一次匿名上报，用在首页上的补同意；引导里
/// 第一次同意用假，等走完引导进入首页再发第一次上报（ADR-0077）。
///
/// 在对话框里选“不同意，仅在本机使用”只记下回答，不改变当前所在的页面，由
/// 调用方决定接着去哪里。
Future<bool> ensureOnboardingConsent(
  BuildContext context, {
  required OnboardingController controller,
  bool report = false,
}) async {
  if (controller.record.consentCurrent) return true;
  final scope = AppScope.of(context);
  final choice = await showOnboardingConsent(
    context,
    update: controller.record.completed,
    telemetryEnabled: controller.telemetryEnabled,
  );
  if (choice == null) return false;
  if (choice.agreed) {
    await controller.acceptTerms();
  } else {
    await controller.declineTerms();
  }
  // 匿名统计的首次说明与开关跟着这次选择写下去；数据库还没打开时等它就绪，
  // 写不进去不影响同意本身。
  try {
    await scope.ready;
    await scope.accountServices.activeReport.completeNotice(
      enabled: choice.agreed && choice.telemetryEnabled,
      report: report && choice.agreed,
    );
  } catch (_) {
    // 引导本身不依赖数据库；这里失败不影响继续。
  }
  return choice.agreed;
}

class _ConsentDialog extends StatefulWidget {
  const _ConsentDialog({required this.update, required this.telemetryEnabled});

  final bool update;
  final bool telemetryEnabled;

  @override
  State<_ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<_ConsentDialog> {
  bool _checked = false;
  late bool _telemetry = widget.telemetryEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return ZhixinDialogLayout(
      title: Text(widget.update ? '用户须知有更新' : '开始使用前，先看这两份说明'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.update
                ? '用户须知与隐私政策改过，同意之后才能继续使用登录、云同步与自动'
                      '检查更新；本机记录、查找与导出不受影响。'
                : '同意之后才能使用登录、云同步、模型调用与自动检查更新；'
                      '不同意也可以只在本机使用。',
            style: theme.text.bodyMedium.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: theme.space.md),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.fileText),
            title: const Text('用户须知'),
            subtitle: const Text('使用规则与账号约定'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => openUserTerms(context, allowAgree: false),
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.shieldCheck),
            title: const Text('隐私政策'),
            subtitle: const Text('收集与保存哪些信息'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => openPrivacyPolicy(context),
          ),
          SizedBox(height: theme.space.md),
          forui.FCheckbox(
            value: _checked,
            label: const Text('我已阅读并同意《用户须知》与《隐私政策》'),
            onChange: (value) => setState(() => _checked = value),
          ),
          const CardDivider(),
          ZhixinSwitch(
            label: const Text('匿名使用统计'),
            description: const Text(
              '采集范围、用途与保存期限见上面《隐私政策》第二部分；'
              '可以随时在设置里关闭。',
            ),
            value: _telemetry,
            onChange: (value) => setState(() => _telemetry = value),
          ),
        ],
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () =>
              Navigator.of(context).pop(const ConsentChoice.declined()),
          child: const Text('不同意，仅在本机使用'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: _checked
              ? () =>
                    Navigator.of(context)
                        .pop(ConsentChoice.agreed(telemetryEnabled: _telemetry))
              : null,
          child: const Text('同意并继续'),
        ),
      ],
    );
  }
}
