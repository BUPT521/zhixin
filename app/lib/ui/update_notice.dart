/// 更新提示：只在检查全部通过并且确实有更新时出现，展示版本名与更新说明，
/// 给一个打开下载地址的按钮。版本低于清单的 `min_version` 时用“建议尽快更新”
/// 提醒云端同步与在线模型可能不可用，但仍然提供“以后再说”，不阻断使用；
/// 取舍见 02 第 3.16 节与 ADR-0025。提示本身不下载、不安装，用户点了才交给浏览器。
library;

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/update_check_service.dart';
import '../domain/models/server_models.dart' show ServerRelease;
import '../platform/app_info.dart';
import 'theme.dart';
import 'zhixin_dialog.dart';
import 'zhixin_toast.dart';

/// 启动时的自动检查：有更新才提示，其它结果一律静默。
///
/// 失败原因已经由服务写进本机诊断，这里不再弹窗，也不改当前界面；本次启动
/// 只检查一次由调用方保证。
Future<void> showStartupUpdateCheck(
  BuildContext context,
  UpdateCheckService service,
) async {
  final result = await service.check();
  if (!context.mounted || !result.hasUpdate) return;
  await showUpdateNotice(context, result);
}

/// 有新版本时的提示；手动检查与启动检查共用同一份。
Future<void> showUpdateNotice(
  BuildContext context,
  UpdateCheckResult result,
) async {
  final release = result.release;
  if (release == null) return;
  final theme = context.zhixin;
  final notes = release.notes.trim();
  await showZhixinAlert<void>(
    context: context,
    title: result.belowMinimum ? '建议尽快更新' : '有新版本可用',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '当前版本 $appVersion，新版本 ${release.version}（构建号 ${release.build}）。',
          style: theme.text.bodyMedium,
        ),
        if (notes.isNotEmpty) ...[
          SizedBox(height: theme.space.sm),
          Text(notes, style: theme.text.bodyMedium),
        ],
        SizedBox(height: theme.space.sm),
        Text(
          result.belowMinimum
              ? '这个版本低于应用建议的最低版本 ${release.minVersion}，云端同步与在线模型可能不可用；可以先不更新，本机记录照常使用。'
              : '可以按需要更新；不更新不影响本机记录。',
          style: theme.text.bodySmall.copyWith(
            color: theme.colors.onSurfaceVariant,
          ),
        ),
      ],
    ),
    actions: [
      forui.FButton(
        variant: forui.FButtonVariant.ghost,
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.of(context).pop(),
        child: const Text('以后再说'),
      ),
      forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: () async {
          Navigator.of(context).pop();
          await openReleaseDownload(context, release);
        },
        child: const Text('打开下载地址'),
      ),
    ],
  );
}

/// 用系统浏览器打开安装包地址；地址不是 https 时拒绝，避免把用户送去 http。
Future<bool> openReleaseDownload(
  BuildContext context,
  ServerRelease release,
) async {
  final uri = Uri.tryParse(release.url.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    if (context.mounted) showToast(context, '下载地址不是 https，请先不要安装');
    return false;
  }
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      showToast(context, '没有可以打开下载地址的浏览器');
    }
    return opened;
  } catch (_) {
    if (context.mounted) showToast(context, '没有可以打开下载地址的浏览器');
    return false;
  }
}
