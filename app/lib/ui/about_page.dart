import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import 'package:url_launcher/url_launcher.dart';

import '../platform/app_info.dart';
import 'zhixin_header.dart';
import 'zhixin_toast.dart';

/// 设置页的关于入口：应用名、版本、项目主页与开源许可。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final Uri _homepage = Uri.parse('https://github.com/BUPT521/zhixin');

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return forui.FScaffold(
      header: const ZhixinHeader(title: Text('关于'), showBack: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: theme.colors.primaryContainer,
              child: Icon(
                FLucideIcons.bookOpenText,
                size: 36,
                color: theme.colors.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            appName,
            textAlign: TextAlign.center,
            style: theme.text.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '版本 $appVersion',
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '一个懂你的学习搭子',
            textAlign: TextAlign.center,
            style: theme.text.bodySmall,
          ),
          const Divider(height: 32),
          forui.FTile(
            prefix: const Icon(FLucideIcons.fileText),
            title: const Text('开源许可'),
            subtitle: const Text('知新的 MIT 许可与第三方组件许可'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: appVersion,
              applicationLegalese: 'MIT License · Copyright (c) 2026 知新项目组',
              applicationIcon: Icon(
                FLucideIcons.bookOpenText,
                size: 40,
                color: theme.colors.primary,
              ),
            ),
          ),
          forui.FTile(
            prefix: const Icon(FLucideIcons.externalLink),
            title: const Text('项目主页'),
            subtitle: const Text('源代码、使用说明与问题反馈'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => _openHomepage(context),
          ),
          const Divider(height: 32),
          Text(
            '学习记录保存在本机；模型调用使用你配置的 API Key，'
            '费用由模型服务商按用量结算。',
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
