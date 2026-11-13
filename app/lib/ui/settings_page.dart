import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../app_scope.dart';
import '../platform/app_info.dart';
import '../platform/data_package_export.dart';
import 'about_page.dart';
import 'data_version_page.dart';
import 'failure_feedback.dart';
import 'memory_page.dart';
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
  bool _systemCamera = false;
  ThemeMode _themeMode = ThemeMode.system;
  int _cutoff = 4;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  bool _started = false;
  AppScopeState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _scope = AppScope.of(context);
    _scope!.dataVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _scope?.dataVersion.removeListener(_load);
    _baseUrl.dispose();
    _model.dispose();
    _contextWindow.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context);
    try {
      final config = await scope.settingsService.config();
      final cutoff = await scope.settingsService.cutoffHour();
      final systemCamera = await scope.settingsService.useSystemCamera();
      final themeMode = scope.themeMode.value;
      if (!mounted) return;
      setState(() {
        _config = config;
        _cutoff = cutoff;
        _systemCamera = systemCamera;
        _themeMode = themeMode;
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
      await AppScope.of(context).settingsService.saveConfig(_formConfig());
      if (!mounted) return;
      _report('模型配置已保存到本机；回到原来的讨论或题目即可接着回答');
      await _load();
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
      final duration = await AppScope.of(context).settingsService
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
    await AppScope.of(context).settingsService.clearConfig();
    if (!mounted) return;
    _report('已删除本机保存的 API Key');
    await _load();
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final uri = await saveDataPackage(
        fileName:
            'zhixin-repository-${now.year}${two(now.month)}${two(now.day)}.zip',
        writePackage: AppScope.of(context).backupRepository,
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
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openVersions() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const DataVersionPage()));
  }

  Future<void> _resetAll() async {
    final confirmed = await showZhixinAlert<bool>(
      context: context,
      title: '清空全部记录',
      content: const Text(
        '将删除目标、题目、作答、日程、记忆、讨论记录和保存的版本，且无法撤销。'
        '模型配置会保留。确定清空？',
      ),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        forui.FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(true),
          child: const Text('清空'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppScope.of(context).settingsService.resetAllData();
      if (!mounted) return;
      _report('本机记录已清空');
      await _load();
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
    if (_loading) {
      return const DetailScaffold(
        child: Center(child: forui.FCircularProgress()),
      );
    }
    final theme = context.zhixin;
    final configured = _config?.isConfigured ?? false;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('设置'), showBack: true),
      child: ListView(
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
                  const SizedBox(height: 8),
                  ZhixinSelect<LlmApi>(
                    value: _api,
                    label: '接口风格',
                    description: '按服务商选择；DeepSeek 与多数兼容地址用 Chat Completions。',
                    options: {for (final api in LlmApi.values) api: api.label},
                    onChange: (value) =>
                        setState(() => _api = value ?? LlmApi.chat),
                  ),
                  const SizedBox(height: 8),
                  forui.FTextField(
                    control: .managed(controller: _baseUrl),
                    label: const Text('接口地址'),
                    hint: 'https://api.deepseek.com/v1',
                  ),
                  const SizedBox(height: 8),
                  forui.FTextField(
                    control: .managed(controller: _model),
                    label: const Text('模型名'),
                    description: const Text('需要模型支持工具调用（function calling）'),
                  ),
                  const SizedBox(height: 8),
                  forui.FTextField(
                    control: .managed(controller: _key),
                    obscureText: true,
                    label: const Text('API Key'),
                  ),
                  const SizedBox(height: 8),
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
                    value: _systemCamera,
                    onChange: (value) async {
                      final previous = _systemCamera;
                      setState(() => _systemCamera = value);
                      try {
                        await AppScope.of(context).settingsService
                            .setUseSystemCamera(value);
                      } catch (error, stack) {
                        if (!mounted || !context.mounted) return;
                        setState(() => _systemCamera = previous);
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
                      }
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
            onPress: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const MemoryPage())),
          ),
          SizedBox(height: theme.space.md),
          ZhixinSelect<int>(
            value: _cutoff,
            label: '每天的截止时间',
            description: '截止时刻前的凌晨记录计入前一天；保存后立即生效，可在数据版本页撤销。',
            options: {for (var hour = 0; hour <= 6; hour++) hour: '$hour 点'},
            onChange: (value) async {
              if (value == null) return;
              setState(() => _cutoff = value);
              try {
                await AppScope.of(context).settingsService
                    .saveCutoffHour(value);
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
                await _load();
              }
            },
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.info),
            title: const Text('关于'),
            subtitle: Text('版本 $appVersion · 开源许可'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const AboutPage())),
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
      ),
    );
  }
}
