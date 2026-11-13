import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../application/memory_view.dart';
import 'failure_feedback.dart';
import 'settings_page.dart';
import 'zhixin_toast.dart';

/// 模型未配置或调用失败时，回答下方的恢复入口。
///
/// 讨论与作答原先各写一遍“配置模型”“用模型重新回答”“模型设置”三个按钮，
/// 文案与图标已经对不上；现在两处共用这一组，只由调用方给主按钮的文字。
class ModelRecoveryButtons extends StatelessWidget {
  const ModelRecoveryButtons({
    super.key,
    required this.configured,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onConfigure,
    this.onOpenSettings,
    this.enabled = true,
  });

  /// 是否已经配置模型；未配置时只显示“配置模型”。
  final bool configured;

  /// 已配置时主按钮的文字，例如“重试这次回答”。
  final String primaryLabel;

  final VoidCallback onPrimary;
  final VoidCallback onConfigure;

  /// 已经配置但凭据或地址有问题时，额外给出模型设置的入口。
  final VoidCallback? onOpenSettings;

  /// 生成中禁用按钮。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (configured)
          forui.FButton(
            variant: forui.FButtonVariant.secondary,
            mainAxisSize: MainAxisSize.min,
            onPress: enabled ? onPrimary : null,
            prefix: const Icon(FLucideIcons.refreshCw),
            child: Text(primaryLabel),
          )
        else
          forui.FButton(
            variant: forui.FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: enabled ? onConfigure : null,
            prefix: const Icon(FLucideIcons.keyRound),
            child: const Text('配置模型'),
          ),
        if (configured && onOpenSettings != null)
          forui.FButton(
            variant: forui.FButtonVariant.ghost,
            mainAxisSize: MainAxisSize.min,
            onPress: enabled ? onOpenSettings : null,
            prefix: const Icon(FLucideIcons.settings),
            child: const Text('模型设置'),
          ),
      ],
    );
  }
}

/// 打开设置页并读回模型配置。
///
/// 两页原先各写一段“推设置页 → 读配置 → 失败时给说明”；现在只在这里读，
/// 读取失败用 [describeFailure] 生成说明交给调用方显示。返回的
/// `configured` 为空表示页面已经关闭或读取失败，调用方不必再改状态。
Future<({bool? configured, String? notice})> openModelSettingsPage(
  BuildContext context, {
  required String kind,
  required String kept,
}) async {
  await Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  if (!context.mounted) return (configured: null, notice: null);
  try {
    final config = await AppScope.of(context).settings.edit.config();
    if (!context.mounted) return (configured: null, notice: null);
    return (configured: config?.isConfigured ?? false, notice: null);
  } catch (error, stack) {
    if (!context.mounted) return (configured: null, notice: null);
    return (
      configured: null,
      notice: describeFailure(
        context,
        error,
        stack,
        action: '读取模型配置',
        kind: kind,
        kept: kept,
        next: '可以回到设置页重新保存一次',
      ),
    );
  }
}

/// 用户点“记下”：写入后重读页面并提示，失败只更新页面提示。
Future<void> acceptMemoryCard({
  required BuildContext context,
  required Future<AcceptedMemory> Function() accept,
  required Future<void> Function() reload,
  required String scope,
  required void Function(String notice) showNotice,
}) async {
  await _runMemoryAction(
    context: context,
    action: accept,
    reload: reload,
    actionText: '保存这条记忆',
    kind: '${scope}_memory_accept',
    kept: '这条记忆仍在待确认',
    next: '可以再点一次「记下」',
    showNotice: showNotice,
    toast: (result) => showToast(context, result.notice ?? '已记下这条记忆'),
  );
}

/// 用户点“不记”：只收起卡片，没有写入也不需要撤销。
Future<void> dismissMemoryCard({
  required BuildContext context,
  required Future<void> Function() dismiss,
  required Future<void> Function() reload,
  required String scope,
  required void Function(String notice) showNotice,
}) async {
  await _runMemoryAction(
    context: context,
    action: dismiss,
    reload: reload,
    actionText: '收起这条记忆',
    kind: '${scope}_memory_dismiss',
    kept: '记忆卡片还在页面上',
    next: '可以再试一次',
    showNotice: showNotice,
    toast: null,
  );
}

Future<void> _runMemoryAction<T>({
  required BuildContext context,
  required Future<T> Function() action,
  required Future<void> Function() reload,
  required String actionText,
  required String kind,
  required String kept,
  required String next,
  required void Function(String notice) showNotice,
  required void Function(T result)? toast,
}) async {
  try {
    final result = await action();
    if (!context.mounted) return;
    await reload();
    if (!context.mounted) return;
    toast?.call(result);
  } catch (error, stack) {
    if (!context.mounted) return;
    showNotice(
      describeFailure(
        context,
        error,
        stack,
        action: actionText,
        kind: kind,
        kept: kept,
        next: next,
      ),
    );
  }
}
