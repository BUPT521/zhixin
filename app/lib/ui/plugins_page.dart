import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../plugins/runtime/plugin.dart';
import 'copy.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 设置页的“插件”：列出运行时注册的第一方插件，逐个启用或停用。
///
/// 停用之后插件提供的入口、工具与导入来源按启停状态消失；启停状态写在
/// `app_meta`，不形成数据提交。本页不提供在线安装与更新，也不列第三方插件。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage>
    with DataVersionWatcher<PluginsPage> {
  bool _loading = true;
  bool _busy = false;
  String? _notice;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    watchDataVersion(AppScope.of(context).dataVersion);
    _load();
  }

  @override
  void onDataVersionChanged() {
    _load();
  }

  Future<void> _load() async {
    try {
      await AppScope.of(context).services.plugins.runtime.load();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = null;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '读取插件设置',
          kind: 'plugins_read',
          kept: '已经保存的启停状态没有改动',
          next: '可以重新打开这一页',
        );
      });
    }
  }

  Future<void> _toggle(FirstPartyPlugin plugin, bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await AppScope.of(context).services.plugins.runtime
          .setEnabled(plugin.manifest.id, enabled);
      if (!mounted) return;
      setState(() {});
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存插件开关',
          kind: 'plugins_toggle',
          kept: '原来的启停状态没有改动',
          next: '可以再试一次',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const DetailScaffold(child: PageLoading());
    }
    final theme = context.zhixin;
    final runtime = AppScope.of(context).services.plugins.runtime;
    final plugins = runtime.plugins;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text(pluginsPageTitle), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(top: theme.space.xl),
        children: [
          const SectionHeading(
            title: pluginsPageTitle,
            subtitle: '随应用编译的第一方插件在这里启用或停用；停用之后，这个插件提供的入口、工具与导入来源不再出现。',
            first: true,
          ),
          if (_notice != null) InlineNotice(message: _notice!),
          for (final plugin in plugins) ...[
            _PluginCard(
              plugin: plugin,
              enabled: runtime.isEnabled(plugin.manifest.id),
              busy: _busy,
              onChanged: (value) => _toggle(plugin, value),
            ),
            SizedBox(height: theme.space.md),
          ],
          Text(
            '插件随版本发布，页面不提供在线安装与更新，也不列出第三方插件。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个插件的说明与开关：名称、类型、版本、说明与权限，右侧是启停。
class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  final FirstPartyPlugin plugin;
  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final manifest = plugin.manifest;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(manifest.name, style: theme.text.titleMedium),
                ),
                forui.FSwitch(
                  value: enabled,
                  onChange: busy ? null : onChanged,
                ),
              ],
            ),
            SizedBox(height: theme.space.xs),
            Text(
              '${pluginKindLabel(manifest.kind)} · 版本 ${manifest.version}'
              ' · ${enabled ? '已启用' : '已停用'}',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(height: theme.space.sm),
            Text(manifest.description, style: theme.text.bodyMedium),
            SizedBox(height: theme.space.xs),
            Text(
              '权限：${pluginPermissionSummary(manifest.permissions)}',
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
