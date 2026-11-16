import 'package:forui/forui.dart' as forui;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../app_scope.dart';
import '../application/settings_service.dart';
import '../domain/rules/time_policy.dart';
import 'copy.dart';
import 'format.dart';
import '../data/diagnostics/crash_log.dart';
import '../platform/app_info.dart';
import '../platform/data_package_export.dart';
import '../platform/diagnostics_store.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'restore_flow.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_select.dart';
import 'zhixin_toast.dart';

/// 设置：模型、数据与清空；记忆单独一页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _baseUrl = TextEditingController();
  LlmApi _api = LlmApi.chat;
  final _model = TextEditingController();
  final _contextWindow = TextEditingController();
  final _key = TextEditingController();

  LlmConfig? _config;
  bool _allowImages = true;
  ThemeMode _themeMode = ThemeMode.system;

  bool _reportCrashes = true;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  bool _started = false;

  /// 库里设置项的订阅：截止小时与拍照方式随写入更新（ADR-0014）。
  Stream<SettingsView>? _stream;

  /// 第一次读取设置项失败时的说明；重新订阅之后清除。
  String? _loadFailure;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final scope = AppScope.of(context);
    _stream = scope.settings.edit.watchSettings();
    _loadLocal(scope);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _contextWindow.dispose();
    _key.dispose();
    super.dispose();
  }

  /// 重新订阅设置项：拍照方式写在 app_meta 里，保存不形成提交、没有表通知，
  /// 因此保存之后换一条新流重读（ADR-0014）。
  void _reloadSettings() {
    setState(() {
      _loadFailure = null;
      _stream = AppScope.of(context).settings.edit.watchSettings();
    });
  }

  void _onSettings(SettingsView settings) {
    if (_loadFailure == null) return;
    setState(() => _loadFailure = null);
  }

  void _onSettingsError(Object error, StackTrace stack) {
    if (!mounted) return;
    final message = describeFailure(
      context,
      error,
      stack,
      action: '读取设置',
      kind: 'settings_read',
      kept: '现有设置没有改动',
      next: '可以重新打开设置页',
    );
    setState(() => _loadFailure = message);
    showToast(context, message);
  }

  /// 读本机保存的模型配置与诊断设置；这两项不在库里，只在打开页面时读一次。
  Future<void> _loadLocal(AppScopeState scope) async {
    try {
      final config = await scope.settings.edit.config();
      final reportCrashes = await DiagnosticsStore(scope.paths.filesDir)
          .read(fallback: !kReleaseMode);
      CrashLog.reportEnabled = reportCrashes;
      final themeMode = scope.themeMode.value;
      if (!mounted) return;
      // 结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _applyConfig(config);
        _reportCrashes = reportCrashes;
        _themeMode = themeMode;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = describeFailure(
          context,
          error,
          stack,
          action: '读取设置',
          kind: 'settings_read',
          kept: '现有设置没有改动',
          next: '可以重新打开设置页',
        );
      });
    }
  }

  /// 把一份模型配置填回输入框；为空时回到默认值与空输入。
  void _applyConfig(LlmConfig? config) {
    _config = config;
    _allowImages = config?.allowImages ?? true;
    _api = config?.api ?? LlmApi.chat;
    _baseUrl.text = config?.baseUrl ?? LlmConfig.defaultBaseUrl;
    _model.text = config?.model ?? LlmConfig.defaultModel;
    final window = config?.contextWindowTokens;
    _contextWindow.text =
        window == null || window == LlmConfig.defaultContextWindowTokens
        ? ''
        : window.toString();
    _key.text = config?.apiKey ?? '';
  }

  LlmConfig _formConfig() {
    final input = _contextWindow.text.trim();
    final window = input.isEmpty
        ? LlmConfig.defaultContextWindowTokens
        : int.tryParse(input);
    if (window == null || window <= 0) {
      throw const FormatException('模型上下文上限须为正整数');
    }
    return LlmConfig(
      api: _api,
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      apiKey: _key.text.trim(),
      allowImages: _allowImages,
      contextWindowTokens: window,
    );
  }

  /// 改了接口地址还沿用旧 Key 时先停下；旧 Key 只对原地址有效。
  void _rejectStaleKey() {
    final config = _formConfig();
    if (config.reusesKeyFrom(_config)) {
      throw const LlmException(LlmFailure.auth, '接口地址已修改，请重新填写这个地址的 API Key');
    }
  }

  /// 结果既留在页面底部，也用轻提示提示一次，避免点完按钮看不到。
  void _report(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    showToast(context, message);
  }

  Future<void> _saveConfig() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _rejectStaleKey();
      final config = _formConfig();
      await AppScope.of(context).settings.edit.saveConfig(config);
      if (!mounted) return;
      setState(() => _applyConfig(config));
      _report('模型配置已保存到本机；回到原来的讨论或题目即可接着回答');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '保存模型配置',
          kind: 'settings_model_save',
          kept: '原来的配置没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConfig() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在测试连接…';
    });
    try {
      _rejectStaleKey();
      final duration = await AppScope.of(context).settings.edit
          .testConfig(_formConfig());
      if (!mounted) return;
      _report('连接成功，用时 ${duration.inSeconds} 秒');
    } on LlmException catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '测试模型连接',
          kind: 'settings_connection',
          kept: '已保存的配置没有改动',
          next: '可以检查接口地址、模型名与 API Key 后重试',
        ),
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '测试模型连接',
          kind: 'settings_connection',
          kept: '已保存的配置没有改动',
          next: '可以检查网络与接口地址后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearConfig() async {
    await AppScope.of(context).settings.edit.clearConfig();
    if (!mounted) return;
    setState(() => _applyConfig(null));
    _report('已删除本机保存的 API Key');
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final now = AppScope.of(context).timePolicy.now;
      final uri = await saveDataPackage(
        fileName: 'zhixin-repository-${compactDate(now)}.zip',
        writePackage: AppScope.of(context).data.versions.backupRepository,
      );
      if (!mounted) return;
      _report(uri == null ? '已取消导出' : '已导出：$uri');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '导出当前数据',
          kind: 'settings_export',
          kept: '本机数据没有改动',
          next: '可以检查剩余存储空间后重试',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await runPackageRestore(
        context,
        onStatus: (message) {
          if (mounted) setState(() => _status = message);
        },
      );
      if (!mounted || message == null) return;
      _report(message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openVersions() {
    openDataVersion(context);
  }

  Future<void> _resetAll() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '清空全部记录',
      content: const Text(
        '将删除目标、题目、作答、日程、记忆、讨论记录和保存的版本，且无法撤销。'
        '模型配置会保留。确定清空？',
      ),
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await AppScope.of(context).settings.edit.resetAllData();
      if (!mounted) return;
      _report('本机记录已清空');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        describeFailure(
          context,
          error,
          stack,
          action: '清空全部记录',
          kind: 'settings_reset',
          kept: '本机数据没有改动',
          next: '可以再试一次',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveView<SettingsView>(
      stream: _stream,
      onData: _onSettings,
      onError: _onSettingsError,
      builder: (context, settings, loading) {
        // 首读期间整页只显示等待指示，不先摆出可滚动的表单。
        if (_loading || (loading && _loadFailure == null)) {
          return const DetailScaffold(child: PageLoading());
        }
        return DetailScaffold(
          header: const ZhixinHeader(title: Text('设置'), showBack: true),
          child: _content(context, settings),
        );
      },
    );
  }

  Widget _content(BuildContext context, SettingsView? settings) {
    final theme = context.zhixin;
    final configured = _config?.isConfigured ?? false;
    // 首读失败时按默认值显示，原因写在页面底部的状态行里。
    final cutoff = settings?.cutoffHour ?? defaultDayCutoffHour;
    final systemCamera = settings?.useSystemCamera ?? false;
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        const SectionHeading(title: '外观', first: true),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZhixinSelect<ThemeMode>(
                  value: _themeMode,
                  label: '深浅色',
                  description: '默认跟随系统，也可以固定为浅色或深色；选择立即生效。',
                  options: const {
                    ThemeMode.system: '跟随系统',
                    ThemeMode.light: '浅色',
                    ThemeMode.dark: '深色',
                  },
                  onChange: (value) async {
                    if (value == null) return;
                    try {
                      await AppScope.of(context).themeMode.select(value);
                    } catch (error, stack) {
                      if (!mounted || !context.mounted) return;
                      _report(
                        describeFailure(
                          context,
                          error,
                          stack,
                          action: '保存外观',
                          kind: 'settings_theme',
                          kept: '当前外观没有改动',
                          next: '可以再选一次',
                        ),
                      );
                      return;
                    }
                    if (!mounted) return;
                    setState(() => _themeMode = value);
                  },
                ),
              ],
            ),
          ),
        ),
        const SectionHeading(title: '模型'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  configured
                      ? '已配置模型：${_config!.model}。回到原来的讨论或题目，'
                            '点「用模型重新回答」接着回答同一个问题。'
                      : '还没有配置模型。现在可以直接提问、记录作答与安排时间，回答区给本地步骤；'
                            '配置后回到原来的讨论或题目，可以接着回答同一个问题。',
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: context.zhixin.space.gap),
                ZhixinSelect<LlmApi>(
                  value: _api,
                  label: '接口风格',
                  description: '按服务商选择；DeepSeek 与多数兼容地址用 Chat Completions。',
                  options: {for (final api in LlmApi.values) api: api.label},
                  onChange: (value) =>
                      setState(() => _api = value ?? LlmApi.chat),
                ),
                SizedBox(height: context.zhixin.space.gap),
                forui.FTextField(
                  control: .managed(controller: _baseUrl),
                  label: const Text('接口地址'),
                  hint: 'https://api.deepseek.com/v1',
                ),
                SizedBox(height: context.zhixin.space.gap),
                forui.FTextField(
                  control: .managed(controller: _model),
                  label: const Text('模型名'),
                  description: const Text('需要模型支持工具调用（function calling）'),
                ),
                SizedBox(height: context.zhixin.space.gap),
                forui.FTextField(
                  control: .managed(controller: _key),
                  obscureText: true,
                  label: const Text('API Key'),
                ),
                SizedBox(height: context.zhixin.space.gap),
                forui.FTextField(
                  control: .managed(controller: _contextWindow),
                  keyboardType: TextInputType.number,
                  label: const Text('模型上下文上限（token）'),
                  description: const Text('按服务商公布的上限填写，留空使用 65536。'),
                ),
                forui.FSwitch(
                  label: const Text('允许上传题目图片'),
                  description: const Text('请求提示、讲解或读图时发送当前图片。'),
                  value: _allowImages,
                  onChange: (value) => setState(() => _allowImages = value),
                ),
                Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    forui.FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _saveConfig,
                      child: const Text('保存'),
                    ),
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _testConfig,
                      child: const Text('测试连接'),
                    ),
                    forui.FButton(
                      variant: forui.FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy || !configured ? null : _clearConfig,
                      child: const Text('删除 API Key'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SectionHeading(title: '拍照'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                forui.FSwitch(
                  label: const Text('拍照使用系统相机'),
                  description: const Text(
                    '关闭时用应用内预览，按下快门直接进入框选；打开后画质交给相机应用，'
                    '部分机型拍完要多确认一次。',
                  ),
                  value: systemCamera,
                  onChange: (value) async {
                    try {
                      await AppScope.of(context).settings.edit
                          .setUseSystemCamera(value);
                    } catch (error, stack) {
                      if (!mounted || !context.mounted) return;
                      _report(
                        describeFailure(
                          context,
                          error,
                          stack,
                          action: '保存拍照方式',
                          kind: 'settings_camera',
                          kept: '拍照方式保持原样',
                          next: '可以再选一次',
                        ),
                      );
                      return;
                    }
                    if (!mounted) return;
                    // 拍照方式写在 app_meta 里，不形成提交、没有表通知；
                    // 保存成功之后换一条新流，开关随读到的新值更新。
                    _reloadSettings();
                  },
                ),
              ],
            ),
          ),
        ),
        const SectionHeading(title: '数据'),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.history),
          title: const Text('数据版本'),
          subtitle: const Text('查看提交历史、命名版本、留存与两类数据包。'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: _busy ? null : _openVersions,
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.share),
          title: const Text('备份版本库'),
          subtitle: const Text('将当前数据、HEAD、历史、命名版本与附件导出为 ZIP 文件。'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: _busy ? null : _export,
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.rotateCcw),
          title: const Text('恢复版本库备份'),
          subtitle: const Text('恢复前会先保存当前状态；版本不匹配时会显示原因。'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: _busy ? null : () => _restore(),
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          variant: forui.FItemVariant.destructive,
          title: const Text('清空全部记录'),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy ? null : _resetAll,
        ),
        const SectionHeading(title: '其他'),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.brain),
          title: const Text('学习记忆'),
          subtitle: const Text('查看、修改和删除记忆'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openMemory(context),
        ),
        SizedBox(height: theme.space.md),
        ZhixinSelect<int>(
          value: cutoff,
          label: '每天的截止时间',
          description: '截止时刻前的凌晨记录计入前一天；保存后立即生效，可在数据版本页撤销。',
          options: {for (var hour = 0; hour <= 6; hour++) hour: '$hour 点'},
          onChange: (value) async {
            if (value == null) return;
            try {
              // 截止小时保存成一条提交，订阅随这次提交重读，界面不另外改值。
              await AppScope.of(context).settings.edit.saveCutoffHour(value);
            } catch (error, stack) {
              if (!mounted || !context.mounted) return;
              _report(
                describeFailure(
                  context,
                  error,
                  stack,
                  action: '保存每日截止时间',
                  kind: 'settings_cutoff',
                  kept: '截止时间保持原样',
                  next: '可以再选一次',
                ),
              );
            }
          },
        ),
        SizedBox(height: theme.space.sm),
        const SectionHeading(title: '插件'),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.package),
          title: const Text(pluginsPageTitle),
          subtitle: const Text(pluginsEntrySubtitle),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openPlugins(context),
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.sparkles),
          title: const Text(personaPageTitle),
          subtitle: const Text(personaEntrySubtitle),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openPersona(context),
        ),
        const SectionHeading(title: '诊断'),
        forui.FSwitch(
          label: const Text('发送崩溃报告'),
          description: const Text(
            '报告包含错误类型、错误分类与应用代码位置。启动时按此设置决定是否连接'
            '诊断服务，本机诊断记录单独保存。',
          ),
          value: _reportCrashes,
          onChange: (value) async {
            final previous = _reportCrashes;
            setState(() => _reportCrashes = value);
            CrashLog.reportEnabled = value;
            try {
              await DiagnosticsStore(AppScope.of(context).paths.filesDir)
                  .write(value);
            } catch (_) {
              if (!context.mounted) return;
              setState(() => _reportCrashes = previous);
              CrashLog.reportEnabled = previous;
              showToast(context, '设置没有保存，可以再试一次');
            }
          },
        ),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.info),
          title: const Text('关于'),
          subtitle: Text('版本 $appVersion · 开源许可'),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openAbout(context),
        ),
        const SizedBox(height: 12),
        Text(
          '知新是开源学习搭子，学习数据保存在本机；模型调用使用你配置的 API Key，费用由模型服务商按用量结算。',
          style: theme.text.bodySmall,
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status!, style: theme.text.bodySmall),
          ),
      ],
    );
  }
}
