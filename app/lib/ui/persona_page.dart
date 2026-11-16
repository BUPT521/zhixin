import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import '../app_scope.dart';
import '../plugins/persona/persona.dart';
import 'copy.dart';
import 'data_version_watcher.dart';
import 'failure_feedback.dart';
import 'theme.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';

/// 设置页的“人格”：列出内置人格与当前启用项，可以切换启用与停用。
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
        next: '可以重新打开这一页',
      );
    }
    setState(() {
      _loading = false;
      _notice = notice;
    });
  }

  Future<void> _select(Persona persona, bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await AppScope.of(context).services.plugins.runtime
          .setActivePersona(enabled ? persona.id : null);
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const DetailScaffold(child: PageLoading());
    }
    final theme = context.zhixin;
    final plugins = AppScope.of(context).services.plugins;
    final personas = plugins.personas.items;
    final active = plugins.personas.active;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text(personaPageTitle), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(top: theme.space.xl),
        children: [
          const SectionHeading(
            title: personaPageTitle,
            subtitle: personaBoundaryNotice,
            first: true,
          ),
          if (_notice != null) InlineNotice(message: _notice!),
          if (!plugins.runtime.personaPluginEnabled)
            Padding(
              padding: EdgeInsets.only(bottom: theme.space.sm),
              child: Text(
                personaPluginDisabled,
                style: theme.text.bodySmall.copyWith(
                  color: theme.colors.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.md),
            child: Text(
              active == null ? personaDefaultTone : '当前人格：${active.name}',
              style: theme.text.bodyMedium,
            ),
          ),
          for (final persona in personas) ...[
            _PersonaCard(
              persona: persona,
              active: active?.id == persona.id,
              busy: _busy,
              onChanged: (value) => _select(persona, value),
            ),
            SizedBox(height: theme.space.md),
          ],
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

/// 一个人格：名称、启用开关、作者、说明与完整设定文本。
class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.persona,
    required this.active,
    required this.busy,
    required this.onChanged,
  });

  final Persona persona;
  final bool active;
  final bool busy;
  final ValueChanged<bool> onChanged;

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
                forui.FSwitch(value: active, onChange: busy ? null : onChanged),
              ],
            ),
            SizedBox(height: theme.space.xs),
            Text(
              '作者：${persona.author}${active ? ' · 当前启用' : ''}',
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
