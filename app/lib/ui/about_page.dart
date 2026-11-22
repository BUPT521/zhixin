import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:url_launcher/url_launcher.dart';

import '../platform/app_info.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 设置页的关于入口：应用名、版本、项目主页与开源许可。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final Uri _homepage = Uri.parse('https://github.com/BUPT521/zhixin');

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('关于'), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(top: theme.space.xl),
        children: [
          const Center(child: ZhixinMark(size: 64)),
          SizedBox(height: theme.space.md),
          Text(
            appName,
            textAlign: TextAlign.center,
            style: theme.text.pageTitle,
          ),
          SizedBox(height: theme.space.xs),
          Text(
            '版本 $appVersionLabel',
            textAlign: TextAlign.center,
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.zhixin.space.gap),
          Text(
            '一个懂你的学习搭子',
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium,
          ),
          Divider(height: theme.space.page, color: theme.colors.outlineVariant),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.fileText),
            title: const Text('开源许可'),
            subtitle: const Text('知新的 MIT 许可与第三方组件许可'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: appVersionLabel,
              applicationLegalese: 'MIT License · Copyright (c) 2026 知新项目组',
              applicationIcon: const ZhixinMark(size: 40),
            ),
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.externalLink),
            title: const Text('项目主页'),
            subtitle: const Text('源代码、使用说明与问题反馈'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => _openHomepage(context),
          ),
          Divider(height: theme.space.page, color: theme.colors.outlineVariant),
          Text(
            '学习记录保存在本机；模型调用经登录后的知新服务发出，'
            '应用不保存密钥，费用由项目组承担。',
            style: theme.text.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _openHomepage(BuildContext context) async {
    try {
      final opened = await launchUrl(
        _homepage,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) _notice(context);
    } catch (_) {
      if (context.mounted) _notice(context);
    }
  }

  void _notice(BuildContext context) {
    showToast(context, '没有可以打开项目主页的浏览器');
  }
}
