import 'package:forui/forui.dart' as forui;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/settings_service.dart';
import '../domain/rules/time_policy.dart';
import '../data/diagnostics/crash_log.dart';
import '../platform/diagnostics_store.dart';
import 'failure_feedback.dart';
import 'live_view.dart';
import 'navigation.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_select.dart';

/// 操作结果挂在触发它的那一段卡片下方：长页里也能就近看到，不集中到页底。
enum _Area { model, learning, appearance, diagnostics, danger }

/// 一段操作的最近一次结果；失败用错误描边的就地说明，成功用一行小字。
class _Result {
  const _Result(this.message, {this.failed = false});

  final String message;
  final bool failed;
}

/// 设置：模型、语义索引、学习、外观、诊断与危险操作。
///
/// 只放偏好配置；账号、记忆、人格、插件、数据版本与关于从底栏“我的”进入。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _baseUrl = TextEditingController();
  LlmApi _api = LlmApi.chat;
  LlmSource _source = LlmSource.custom;
  final _model = TextEditingController();
  final _contextWindow = TextEditingController();
  final _key = TextEditingController();

  LlmConfig? _config;
  AccountSnapshot? _account;

  /// 服务端代理允许的模型；登录且读得到时显示，作为模型名的参照。
  List<String> _serverModels = const [];
  bool _allowImages = true;
  ThemeMode _themeMode = ThemeMode.system;

  bool _reportCrashes = true;
  bool _loading = true;
  bool _busy = false;
  final Map<_Area, _Result> _results = {};

  /// 语义索引入口的副标题：没有可用来源时写“未启用”，否则写来源条数。
  bool _embeddingUsable = false;
  int? _embeddingSources;

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
      next: '可以在页面顶部重试',
    );
    setState(() => _loadFailure = message);
  }

  /// 读本机保存的模型配置与诊断设置，以及语义索引的规模。
  Future<void> _loadLocal(AppScopeState scope) async {
    try {
      final config = await scope.settings.edit.config();
      final account = await scope.accountServices.account.snapshot();
      var serverModels = const <String>[];
      if (account.signedIn) {
        try {
          serverModels = [
            for (final model in await scope.accountServices.account.models())
              model.id,
          ];
        } catch (_) {
          // 模型列表只用于提示；读不到时保持空，不打断设置页。
        }
      }
      final reportCrashes = await DiagnosticsStore(scope.paths.filesDir)
          .read(fallback: !kReleaseMode);
      CrashLog.reportEnabled = reportCrashes;
      final themeMode = scope.themeMode.value;
      final embedding = await _readEmbeddingSummary(scope);
      if (!mounted) return;
      // 结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _account = account;
        _serverModels = serverModels;
        _applyConfig(config);
        _reportCrashes = reportCrashes;
        _themeMode = themeMode;
        _embeddingUsable = embedding.usable;
        _embeddingSources = embedding.sources;
        _loading = false;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailure = describeFailure(
          context,
          error,
          stack,
          action: '读取设置',
          kind: 'settings_read',
          kept: '现有设置没有改动',
          next: '可以在页面顶部重试',
        );
      });
    }
  }

  /// 顶部说明失败之后的重试：重新订阅库里设置项，并把本机配置再读一次。
  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _loadFailure = null;
      _stream = AppScope.of(context).settings.edit.watchSettings();
    });
    await _loadLocal(AppScope.of(context));
  }

  /// 语义索引是否可用与来源条数；读取失败时按没有索引状态处理，不影响整页。
  Future<({bool usable, int? sources})> _readEmbeddingSummary(
    AppScopeState scope,
  ) async {
    var usable = false;
    try {
      final config = await scope.settings.embedding.read();
      usable = config?.usable ?? false;
    } catch (_) {
      // 配置读不出来时按未启用显示，入口照常可以打开。
    }
    int? sources;
    if (usable) {
      try {
        sources = (await scope.library.searchIndex.stats()).sources;
      } catch (_) {
        // 索引状态读不出来时副标题写说明，不停在“0 条来源”。
      }
    }
    return (usable: usable, sources: sources);
  }

  String get _embeddingSubtitle {
    if (!_embeddingUsable) return '未启用';
    final sources = _embeddingSources;
    return sources == null ? '索引状态暂时无法读取' : '$sources 条来源';
  }

  Future<void> _openEmbedding() async {
    final scope = AppScope.of(context);
    await openEmbeddingSettings(context);
    if (!mounted) return;
    final embedding = await _readEmbeddingSummary(scope);
    if (!mounted) return;
    setState(() {
      _embeddingUsable = embedding.usable;
      _embeddingSources = embedding.sources;
    });
  }

  /// 把一份模型配置填回输入框；为空时回到默认值与空输入。
  void _applyConfig(LlmConfig? config) {
    _config = config;
    _allowImages = config?.allowImages ?? true;
    _source = config?.source ?? LlmSource.custom;
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
    if (_source == LlmSource.server) {
      final base = _account?.serverBaseUrl ?? '';
      return LlmConfig(
        source: LlmSource.server,
        api: LlmApi.chat,
        baseUrl: base.isEmpty ? '' : '$base/v1/llm',
        model: _model.text.trim().isEmpty
            ? LlmConfig.defaultModel
            : _model.text.trim(),
        allowImages: _allowImages,
        contextWindowTokens: window,
      );
    }
    return LlmConfig(
      api: _api,
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      apiKey: _key.text.trim(),
      allowImages: _allowImages,
      contextWindowTokens: window,
      source: LlmSource.custom,
    );
  }

  /// 改了接口地址还沿用旧 Key 时先停下；旧 Key 只对原地址有效。
  void _rejectStaleKey() {
    if (_source != LlmSource.custom) return;
    final config = _formConfig();
    if (config.reusesKeyFrom(_config)) {
      throw const LlmException(LlmFailure.auth, '接口地址已修改，请重新填写这个地址的 API Key');
    }
  }

  /// 结果留在触发操作的那一段卡片下方；失败另用错误描边的就地说明。
  void _report(_Area area, String message, {bool failed = false}) {
    if (!mounted) return;
    setState(() => _results[area] = _Result(message, failed: failed));
  }

  Widget? _resultFor(_Area area) {
    final result = _results[area];
    if (result == null) return null;
    final theme = context.zhixin;
    if (result.failed) return InlineNotice(message: result.message);
    return Padding(
      padding: EdgeInsets.only(top: theme.space.sm),
      child: Text(result.message, style: theme.text.bodySmall),
    );
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
      _report(_Area.model, '模型配置已保存到本机；回到原来的讨论或题目即可接着回答');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.model,
        describeFailure(
          context,
          error,
          stack,
          action: '保存模型配置',
          kind: 'settings_model_save',
          kept: '原来的配置没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConfig() async {
    if (_busy) return;
    setState(() => _busy = true);
    _report(_Area.model, '正在测试连接…');
    try {
      _rejectStaleKey();
      final duration = await AppScope.of(context).settings.edit
          .testConfig(_formConfig());
      if (!mounted) return;
      _report(_Area.model, '连接成功，用时 ${duration.inSeconds} 秒');
    } on LlmException catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.model,
        describeFailure(
          context,
          error,
          stack,
          action: '测试模型连接',
          kind: 'settings_connection',
          kept: '已保存的配置没有改动',
          next: '可以检查接口地址、模型名与 API Key 后重试',
        ),
        failed: true,
      );
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.model,
        describeFailure(
          context,
          error,
          stack,
          action: '测试模型连接',
          kind: 'settings_connection',
          kept: '已保存的配置没有改动',
          next: '可以检查网络与接口地址后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除整份模型配置：清掉接口地址、模型名与 API Key，先做危险确认。
  Future<void> _clearConfig() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '删除模型配置',
      content: const Text(
        '将删除本机保存的接口地址、模型名与 API Key，且无法撤销。'
        '删除之后仍然可以直接提问、记录作答与安排时间，回答区给本地步骤；'
        '之后重新填写即可恢复。',
      ),
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await AppScope.of(context).settings.edit.clearConfig();
      if (!mounted) return;
      setState(() => _applyConfig(null));
      _report(_Area.danger, '已删除本机保存的模型配置');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.danger,
        describeFailure(
          context,
          error,
          stack,
          action: '删除模型配置',
          kind: 'settings_model_clear',
          kept: '原来的配置没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    }
  }

  /// 打开账号页；返回之后重新读登录状态，模型来源跟着变。
  Future<void> _openAccount() async {
    final scope = AppScope.of(context);
    await openAccount(context);
    if (!mounted) return;
    await _loadLocal(scope);
  }

  Future<void> _resetAll() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '清空全部记录',
      content: const Text(
        '将删除目标、题目、作答、日程、记忆、讨论记录、图片和保存的版本，'
        '以及本机语义索引，且无法撤销。模型配置、外观与人格设置会保留。确定清空？',
      ),
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await AppScope.of(context).settings.edit.resetAllData();
      if (!mounted) return;
      _report(_Area.danger, '本机记录已清空');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.danger,
        describeFailure(
          context,
          error,
          stack,
          action: '清空全部记录',
          kind: 'settings_reset',
          kept: '本机数据没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LiveView<SettingsView>(
      stream: _stream,
      onData: _onSettings,
      onError: _onSettingsError,
      builder: (context, settings, loading) {
        // 首读期间保留标题栏，内容用与卡片同高的骨架占位。
        if (_loading || (loading && _loadFailure == null)) {
          return DetailScaffold(
            header: const ZhixinHeader(title: Text('设置'), showBack: true),
            child: ListView(
              padding: theme.space.pageInsets(),
              children: const [ListSkeleton(rows: 3, rowHeight: 96)],
            ),
          );
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
    final signedIn = _account?.signedIn ?? false;
    final configured =
        _config != null &&
        (_config!.isConfigured || (_config!.isServer && signedIn));
    // 首读失败时按默认值显示，原因写在页面顶部的就地说明里。
    final cutoff = settings?.cutoffHour ?? defaultDayCutoffHour;
    final systemCamera = settings?.useSystemCamera ?? false;
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        if (_loadFailure != null)
          InlineNotice(message: _loadFailure!, onRetry: _retry),
        SectionHeading(
          title: '模型',
          first: _loadFailure == null,
          action: StatusTag(
            configured ? '已配置' : '未配置',
            tone: configured ? TagTone.accent : TagTone.muted,
          ),
        ),
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
                ZhixinSelect<LlmSource>(
                  value: _source,
                  label: '模型来源',
                  description: '自填 Key 直连提供方；知新服务用登录账号的访问令牌走服务端代理，不保存 key。',
                  options: {
                    for (final source in LlmSource.values) source: source.label,
                  },
                  onChange: (value) =>
                      setState(() => _source = value ?? LlmSource.custom),
                ),
                SizedBox(height: context.zhixin.space.gap),
                if (_source == LlmSource.custom) ...[
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
                ] else ...[
                  Text(
                    signedIn
                        ? '请求发到 ${_account!.serverBaseUrl}/v1/llm，'
                              '密钥由服务端保管；每日额度用完后可以改用自己的 API Key。'
                        : '还没有登录。登录之后才能使用知新服务；现在仍可以使用自填 Key。',
                    style: theme.text.bodySmall.copyWith(
                      color: signedIn
                          ? theme.colors.onSurfaceVariant
                          : theme.colors.error,
                    ),
                  ),
                  if (!signedIn) ...[
                    SizedBox(height: context.zhixin.space.sm),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: forui.FButton(
                        variant: forui.FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _busy ? null : _openAccount,
                        prefix: const Icon(FLucideIcons.logIn),
                        child: const Text('登录或注册'),
                      ),
                    ),
                  ],
                  if (signedIn && _serverModels.isNotEmpty) ...[
                    SizedBox(height: context.zhixin.space.xs),
                    Text(
                      '服务端允许的模型：${_serverModels.join('、')}',
                      style: theme.text.bodySmall.copyWith(
                        color: theme.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  SizedBox(height: context.zhixin.space.gap),
                ],
                forui.FTextField(
                  control: .managed(controller: _model),
                  label: const Text('模型名'),
                  description: const Text('需要模型支持工具调用（function calling）'),
                ),
                SizedBox(height: context.zhixin.space.gap),
                if (_source == LlmSource.custom) ...[
                  forui.FTextField(
                    control: .managed(controller: _key),
                    obscureText: true,
                    label: const Text('API Key'),
                  ),
                  SizedBox(height: context.zhixin.space.gap),
                ],
                SizedBox(height: context.zhixin.space.gap),
                forui.FTextField(
                  control: .managed(controller: _contextWindow),
                  keyboardType: TextInputType.number,
                  label: const Text('模型上下文上限（token）'),
                  description: const Text('按服务商公布的上限填写，留空使用 65536。'),
                ),
                SizedBox(height: context.zhixin.space.gap),
                forui.FSwitch(
                  label: const Text('允许上传题目图片'),
                  description: const Text('请求提示、讲解或读图时发送当前图片。'),
                  value: _allowImages,
                  onChange: (value) => setState(() => _allowImages = value),
                ),
                SizedBox(height: context.zhixin.space.md),
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
                  ],
                ),
              ],
            ),
          ),
        ),
        ?_resultFor(_Area.model),
        SizedBox(height: theme.space.md),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.network),
          title: const Text('语义索引'),
          subtitle: Text(_embeddingSubtitle),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: _busy ? null : _openEmbedding,
        ),
        const SectionHeading(title: '学习', subtitle: '每天的截止时间与拍照方式影响记录与拍题。'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZhixinSelect<int>(
                  value: cutoff,
                  label: '每天的截止时间',
                  description: '截止时刻前的凌晨记录计入前一天；保存后立即生效，可在数据版本页撤销。',
                  options: {
                    for (var hour = 0; hour <= 6; hour++) hour: '$hour 点',
                  },
                  onChange: (value) async {
                    if (value == null) return;
                    try {
                      // 截止小时保存成一条提交，订阅随这次提交重读，界面不另外改值。
                      await AppScope.of(context).settings.edit
                          .saveCutoffHour(value);
                      _report(_Area.learning, '每日截止时间已保存');
                    } catch (error, stack) {
                      if (!mounted || !context.mounted) return;
                      _report(
                        _Area.learning,
                        describeFailure(
                          context,
                          error,
                          stack,
                          action: '保存每日截止时间',
                          kind: 'settings_cutoff',
                          kept: '截止时间保持原样',
                          next: '可以再选一次',
                        ),
                        failed: true,
                      );
                    }
                  },
                ),
                SizedBox(height: theme.space.gap),
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
                        _Area.learning,
                        describeFailure(
                          context,
                          error,
                          stack,
                          action: '保存拍照方式',
                          kind: 'settings_camera',
                          kept: '拍照方式保持原样',
                          next: '可以再选一次',
                        ),
                        failed: true,
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
        ?_resultFor(_Area.learning),
        const SectionHeading(title: '外观'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: ZhixinSelect<ThemeMode>(
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
                    _Area.appearance,
                    describeFailure(
                      context,
                      error,
                      stack,
                      action: '保存外观',
                      kind: 'settings_theme',
                      kept: '当前外观没有改动',
                      next: '可以再选一次',
                    ),
                    failed: true,
                  );
                  return;
                }
                if (!mounted) return;
                setState(() => _themeMode = value);
              },
            ),
          ),
        ),
        ?_resultFor(_Area.appearance),
        const SectionHeading(title: '诊断'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: forui.FSwitch(
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
                  _report(_Area.diagnostics, '设置没有保存，可以再试一次', failed: true);
                }
              },
            ),
          ),
        ),
        ?_resultFor(_Area.diagnostics),
        const SectionHeading(
          title: '危险操作',
          subtitle: '这两项都无法撤销；删除模型配置只影响本机保存的模型设置。',
        ),
        forui.FTile(
          variant: forui.FItemVariant.destructive,
          prefix: const LeadingIcon(FLucideIcons.keyRound, tone: TagTone.muted),
          title: const Text('删除模型配置'),
          subtitle: const Text('删除本机保存的接口地址、模型名与 API Key；之后的回答按本地步骤给出。'),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy || !configured ? null : _clearConfig,
        ),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          variant: forui.FItemVariant.destructive,
          prefix: const LeadingIcon(FLucideIcons.trash2, tone: TagTone.muted),
          title: const Text('清空全部记录'),
          subtitle: const Text(
            '删除目标、题目、作答、日程、记忆、讨论记录、图片、保存的版本与语义索引；'
            '模型配置、外观与人格设置保留。',
          ),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy ? null : _resetAll,
        ),
        ?_resultFor(_Area.danger),
        SizedBox(height: theme.space.md),
        Text(
          '知新是开源学习搭子，学习数据默认保存在本机；登录之后才会使用项目组自建服务端的'
          '云端备份、增量同步与模型代理，模型调用也可以自填 API Key 直连提供方。',
          style: theme.text.bodySmall,
        ),
      ],
    );
  }
}
