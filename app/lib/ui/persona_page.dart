import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../plugins/persona/persona.dart';
import 'copy.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 设置页的“人格”：列出内置人格与当前启用项，单选，另加“不使用人格”。
///
/// 同一时间只启用一个人格；切换写在 `app_meta`，不形成数据提交。导入、编辑与
/// 分享本次不开放，页面写明而不放不会生效的按钮。
class PersonaPage extends StatefulWidget {
  const PersonaPage({super.key});

  @override
  State<PersonaPage> createState() => _PersonaPageState();
}

class _PersonaPageState extends State<PersonaPage>
    with DataVersionWatcher<PersonaPage> {
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
    String? notice;
    Object? failure;
    StackTrace? failureStack;
    try {
      await AppScope.of(context).services.plugins.runtime.load();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    if (!mounted) return;
    if (failure != null) {
      notice = describeFailure(
        context,
        failure,
        failureStack!,
        action: '读取人格设置',
        kind: 'persona_read',
        kept: '已经保存的人格与启用项没有改动',
        next: '可以在页面顶部重试',
      );
    }
    setState(() {
      _loading = false;
      _notice = notice;
    });
  }

  /// 单选：传入人格启用它，传空表示不使用人格。
  Future<void> _select(Persona? persona) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await AppScope.of(context).services.plugins.runtime
          .setActivePersona(persona?.id);
      if (!mounted) return;
      setState(() {});
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存人格选择',
          kind: 'persona_select',
          kept: '原来的选择没有改动',
          next: '可以再试一次',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 人格插件停用之后，人格设定不会进入提示词；去插件页启用之后回来重读。
  Future<void> _openPluginsPage() async {
    await openPlugins(context);
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    if (_loading) {
      return DetailScaffold(
        header: const ZhixinHeader(
          title: Text(personaPageTitle),
          showBack: true,
        ),
        child: ListView(
          padding: theme.space.pageInsets(),
          children: const [ListSkeleton(rows: 3, rowHeight: 96)],
        ),
      );
    }
    final plugins = AppScope.of(context).services.plugins;
    final personas = plugins.personas.items;
    final active = plugins.personas.active;
    final pluginEnabled = plugins.runtime.personaPluginEnabled;
    final disabled = _busy || !pluginEnabled;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text(personaPageTitle), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(),
        children: [
          SectionHeading(
            title: '内置人格',
            subtitle: personaBoundaryNotice,
            first: true,
            action: StatusTag(
              active == null ? '未启用' : '已启用',
              tone: active == null ? TagTone.muted : TagTone.accent,
            ),
          ),
          if (_notice != null) InlineNotice(message: _notice!, onRetry: _load),
          if (!pluginEnabled)
            InlineNotice(
              message: personaPluginDisabled,
              retryLabel: '去启用',
              onRetry: _openPluginsPage,
            ),
          _NoPersonaCard(
            active: active == null,
            enabled: !disabled,
            onSelected: () => _select(null),
          ),
          SizedBox(height: theme.space.sm),
          for (final persona in personas) ...[
            _PersonaCard(
              persona: persona,
              active: active?.id == persona.id,
              enabled: !disabled,
              onSelected: () => _select(persona),
            ),
            SizedBox(height: theme.space.sm),
          ],
          SizedBox(height: theme.space.md),
          Text(
            personaExtrasUnavailable,
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// “不使用人格”：单选的一项，搭子按默认语气回答。
class _NoPersonaCard extends StatelessWidget {
  const _NoPersonaCard({
    required this.active,
    required this.enabled,
    required this.onSelected,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: forui.FRadio(
          value: active,
          enabled: enabled,
          semanticsLabel: '不使用人格',
          label: Text('不使用人格', style: theme.text.titleMedium),
          description: Text(
            active ? personaDefaultTone : '停用当前人格之后，搭子使用默认语气。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
          onChange: (value) {
            if (value) onSelected();
          },
        ),
      ),
    );
  }
}

/// 一个人格：名称、单选、作者、说明与完整设定文本。
class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.persona,
    required this.active,
    required this.enabled,
    required this.onSelected,
  });

  final Persona persona;
  final bool active;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(persona.name, style: theme.text.titleMedium),
                ),
                forui.FRadio(
                  value: active,
                  enabled: enabled,
                  semanticsLabel: '启用${persona.name}人格',
                  onChange: (value) {
                    if (value) onSelected();
                  },
                ),
              ],
            ),
            if (active) ...[
              SizedBox(height: theme.space.xs),
              const StatusTag('当前启用', tone: TagTone.accent),
            ],
            SizedBox(height: theme.space.xs),
            Text(
              '作者：${persona.author}',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            SizedBox(height: theme.space.xs),
            Text(persona.description, style: theme.text.bodyMedium),
            SizedBox(height: theme.space.sm),
            Text(
              persona.text,
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
