import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../application/update_service.dart';
import 'theme.dart';
import 'workspace_widgets.dart';

/// 设置页顶部的更新提示：只提示，不打断学习，也不在本机下载或安装。
///
/// 显示版本、更新说明、sha256 与签名核对结果；“去下载”交给系统浏览器
/// （[onDownload] 由页面用 url_launcher 打开），“稍后”关闭本次提示。
class UpdateNoticeCard extends StatelessWidget {
  const UpdateNoticeCard({
    required this.update,
    required this.onDownload,
    required this.onDismiss,
    super.key,
  });

  final AppUpdate update;
  final VoidCallback onDownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final release = update.release;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '发现新版本 ${release.version}（构建 ${release.build}）',
                    style: theme.text.titleMedium,
                  ),
                ),
                SizedBox(width: theme.space.sm),
                StatusTag(
                  update.mandatory ? '必须更新' : '可选更新',
                  tone: update.mandatory ? TagTone.attention : TagTone.accent,
                ),
              ],
            ),
            if (release.notes.trim().isNotEmpty) ...[
              SizedBox(height: theme.space.sm),
              Text(release.notes.trim(), style: theme.text.bodyMedium),
            ],
            SizedBox(height: theme.space.sm),
            Text(
              '安装包 SHA-256：${release.sha256}',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(height: theme.space.xs),
            Text(
              '签名：${update.signatureLabel}',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            if (update.mandatory) ...[
              SizedBox(height: theme.space.xs),
              Text(
                '这个版本低于当前允许的最低版本，建议尽快更新。',
                style: theme.text.bodySmall.copyWith(color: theme.colors.error),
              ),
            ],
            SizedBox(height: theme.space.md),
            Wrap(
              spacing: theme.space.sm,
              runSpacing: theme.space.sm,
              children: [
                forui.FButton(
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(FLucideIcons.download),
                  onPress: onDownload,
                  child: const Text('去下载'),
                ),
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: onDismiss,
                  child: const Text('稍后'),
                ),
              ],
            ),
            SizedBox(height: theme.space.sm),
            Text(
              '应用不在本机自动下载或安装安装包；下载与安装交给系统浏览器和系统安装器。',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
