import 'package:forui/forui.dart' as forui;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../ai/llm_client.dart';
import '../ai/llm_config.dart';
import '../app_scope.dart';
import '../application/account_service.dart';
import '../application/embedding_settings.dart';
import '../application/prefetch_service.dart';
import '../application/settings_service.dart';
import '../application/update_check_service.dart';
import '../domain/models/result.dart';
import '../domain/rules/time_policy.dart';
import '../data/diagnostics/crash_log.dart';
import '../platform/app_info.dart';
import '../platform/diagnostics_store.dart';
import 'accent_picker.dart';
import 'account_dialogs.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'live_view.dart';
import 'update_notice.dart';
import 'zhixin_dialog.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_select.dart';

/// 操作结果挂在触发它的那一段卡片下方：长页里也能就近看到，不集中到页底。
enum _Area {
  model,
  developer,
  learning,
  appearance,
  updates,
  diagnostics,
  danger,
}

/// 一级界面切进来之后预读的设置页首屏；字段与预读任务返回的记录一致。
typedef _SettingsPrewarm = ({
  Result<LlmConfig?> config,
  AccountSnapshot account,
  List<String> models,
  EmbeddingSummary embedding,
  bool reportCrashes,
  bool reportUsage,
});

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
  const SettingsPage({super.key, this.updates});

  /// 手动检查更新用的服务；测试注入固定清单，生产使用当前知新服务地址。
  final UpdateCheckService? updates;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _model = TextEditingController();
  final _contextWindow = TextEditingController();

  LlmConfig? _config;
  AccountSnapshot? _account;
  bool? _developerMode;

  /// 服务端允许的模型；登录且读得到时显示，作为模型名的参照。
  List<String> _serverModels = const [];
  bool _allowImages = true;
  ThemeMode _themeMode = ThemeMode.system;

  bool _reportCrashes = true;
  bool _reportUsage = true;

  /// 手动检查更新进行中：按钮禁用，副标题改成读取状态。
  bool _checkingUpdates = false;
  bool _loading = true;
  bool _busy = false;
  final Map<_Area, _Result> _results = {};

  /// 语义索引入口的副标题：没有可用来源时写“未启用”，否则写来源条数。
  bool _embeddingUsable = false;
  int? _embeddingSources;

  bool _started = false;

  /// 首屏已经从预读结果填过；设置项的订阅第一次回来之前不再摆骨架。
  bool _prewarmed = false;

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
    _themeMode = scope.themeMode.value;
    // 从“我的”打开时，一级界面切进来之后已经在后台读过这一页的首屏；
    // 先填上，再让下面这一次完整读取刷新。
    final prewarm = scope.prefetch.take<_SettingsPrewarm>(PrefetchKey.settings);
    if (prewarm != null) {
      _account = prewarm.account;
      _serverModels = prewarm.models;
      _applyConfig(prewarm.config.valueOrNull);
      _reportCrashes = prewarm.reportCrashes;
      _reportUsage = prewarm.reportUsage;
      _embeddingUsable = prewarm.embedding.usable;
      _embeddingSources = prewarm.embedding.sources;
      _loading = false;
      _prewarmed = true;
    }
    _stream = scope.settings.edit.watchSettings();
    _loadLocal(scope);
  }

  @override
  void dispose() {
    _model.dispose();
    _contextWindow.dispose();
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
      final read = await scope.settings.edit.config();
      final config = read.valueOrNull;
      final configFailure = read.failureOrNull;
      final account = await scope.accountServices.account.snapshot();
      final developerMode = await scope.accountServices.account.developerMode();
      var serverModels = const <String>[];
      if (developerMode && account.signedIn) {
        try {
          serverModels = [
            // 嵌入模型给语义索引用，回答选不了，不放进这里的提示。
            for (final model in await scope.accountServices.account.models())
              if (model.isChat) model.id,
          ];
        } catch (_) {
          // 模型列表只用于提示；读不到时保持空，不打断设置页。
        }
      }
      final reportCrashes = await DiagnosticsStore(scope.devicePaths.filesDir)
          .read(fallback: !kReleaseMode);
      CrashLog.reportEnabled = reportCrashes;
      final reportUsage = await scope.accountServices.activeReport.enabled();
      final themeMode = scope.themeMode.value;
      final embedding = await _readEmbeddingSummary(scope);
      if (!mounted) return;
      // 结果回来时若还在推入动画里，等动画结束再填。
      await context.afterTransition();
      if (!mounted) return;
      setState(() {
        _account = account;
        _developerMode = developerMode;
        _serverModels = serverModels;
        _applyConfig(config);
        _reportCrashes = reportCrashes;
        _reportUsage = reportUsage;
        _themeMode = themeMode;
        _embeddingUsable = embedding.usable;
        _embeddingSources = embedding.sources;
        _loading = false;
      });
      if (configFailure != null && mounted) {
        setState(() {
          _loadFailure = describeFailureReason(
            context,
            configFailure,
            kind: 'settings_config_read',
            kept: '其他设置照常显示',
            next: '可以在开发者模式中重新保存模型配置',
          );
        });
      }
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
  Future<EmbeddingSummary> _readEmbeddingSummary(AppScopeState scope) =>
      scope.settings.embedding.summary();

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

  /// 手动检查更新：与启动检查走同一套流程，结果就地说明；有更新时另弹提示。
  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() {
      _checkingUpdates = true;
      _results.remove(_Area.updates);
    });
    try {
      final service =
          widget.updates ?? AppScope.of(context).accountServices.updates;
      final result = await service.check();
      if (!mounted) return;
      switch (result.status) {
        case UpdateCheckStatus.upToDate:
          _report(_Area.updates, '已经是最新版本（$appVersion）');
        case UpdateCheckStatus.failed:
          _report(_Area.updates, result.failureMessage, failed: true);
        case UpdateCheckStatus.updateAvailable:
          final release = result.release!;
          _report(
            _Area.updates,
            '有新版本 ${release.version}（构建号 ${release.build}），可以打开下载地址更新。',
          );
          await showUpdateNotice(context, result);
      }
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  /// 把一份模型配置填回输入框；为空时回到默认值与空输入。
  void _applyConfig(LlmConfig? config) {
    _config = config;
    _allowImages = config?.allowImages ?? true;
    _model.text = config?.model ?? LlmConfig.defaultModel;
    final window = config?.contextWindowTokens;
    _contextWindow.text =
        window == null || window == LlmConfig.defaultContextWindowTokens
        ? ''
        : window.toString();
  }

  LlmConfig _formConfig() {
    final input = _contextWindow.text.trim();
    final window = input.isEmpty
        ? LlmConfig.defaultContextWindowTokens
        : int.tryParse(input);
    if (window == null || window <= 0) {
      throw const FormatException('模型上下文上限须为正整数');
    }
    if (window > LlmConfig.maxContextWindowTokens) {
      throw FormatException('模型上下文上限不能超过 ${LlmConfig.maxContextWindowTokens}');
    }
    return LlmConfig(
      model: _model.text.trim().isEmpty
          ? LlmConfig.defaultModel
          : _model.text.trim(),
      allowImages: _allowImages,
      contextWindowTokens: window,
    );
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

  /// 保存模型配置：只存模型名、上下文上限与图片开关，先确认已经登录。
  Future<void> _saveConfig() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final config = _formConfig();
      await AppScope.of(context).settings.edit.saveConfig(config);
      if (!mounted) return;
      setState(() => _applyConfig(config));
      _report(_Area.model, '模型配置已保存，可以回到原来的讨论或题目重试');
    } on AccountSignedOut catch (error) {
      // 没有登录时先说明原因，再带着这次填的模型名去账号页；回来之后表单还在。
      if (!mounted) return;
      _report(_Area.model, error.userMessage, failed: true);
      await _openAccount();
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

  /// 测试连接：用当前登录账号的地址与令牌向知新服务发一次最小请求。
  Future<void> _testConfig() async {
    if (_busy) return;
    setState(() => _busy = true);
    _report(_Area.model, '正在测试连接…');
    try {
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
          next: error.failure == LlmFailure.modelNotAllowed
              ? '请选择服务端已启用的聊天模型后重试'
              : '可以检查登录状态与网络后重试',
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
          next: '可以检查网络与登录状态后重试',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearConfig() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '恢复默认模型配置',
      content: const Text('将清除本机覆盖的模型名、上下文上限与图片开关，恢复默认配置。'),
      confirmLabel: '恢复默认',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).settings.edit.clearConfig();
      if (!mounted) return;
      setState(() => _applyConfig(null));
      _report(_Area.model, '已恢复默认模型 ${LlmConfig.defaultModel}');
    } catch (error, stack) {
      if (!mounted) return;
      _report(
        _Area.model,
        describeFailure(
          context,
          error,
          stack,
          action: '恢复默认模型配置',
          kind: 'settings_model_clear',
          kept: '原来的配置没有改动',
          next: '可以再试一次',
        ),
        failed: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 打开账号页；返回之后重新读登录状态，模型是否可用跟着变。
  Future<void> _openAccount() async {
    final scope = AppScope.of(context);
    await openAccount(context);
    if (!mounted) return;
    await _loadLocal(scope);
  }

  Future<void> _setDeveloperMode(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _results.remove(_Area.developer);
    });
    try {
      final scope = AppScope.of(context);
      await scope.accountServices.account.setDeveloperMode(enabled);
      if (!mounted) return;
      setState(() => _developerMode = enabled);
      if (enabled) await _loadLocal(scope);
    } catch (_) {
      _report(_Area.developer, '开发者模式设置未保存，请重试', failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editServerAddress() async {
    final scope = AppScope.of(context);
    final saved = await editZhixinServerAddress(
      context,
      serverBaseUrl: _account?.serverBaseUrl ?? '',
      onSave: scope.configureServerBaseUrl,
    );
    if (!mounted || saved != true) return;
    await _loadLocal(scope);
    _report(_Area.developer, '知新服务地址已保存');
  }

  Future<void> _resetAll() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '清空全部记录',
      content: const Text(
        '将删除目标、题目、作答、事项、记忆、讨论记录、图片和保存的版本，'
        '以及本机语义索引，且无法撤销。模型配置与外观会保留，人格、截止时间'
        '等设置回到默认。确定清空？',
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
        // 首读期间保留标题栏，内容用与卡片同高的骨架占位；预读结果已经填过
        // 首屏时直接显示，设置项的订阅回来再补。
        if (_loading || (loading && !_prewarmed && _loadFailure == null)) {
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

  Widget _modelConfiguration({required bool signedIn}) {
    final theme = context.zhixin;
    return forui.FCard(
      child: Padding(
        padding: EdgeInsets.all(theme.space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('模型配置', style: theme.text.titleSmall)),
                StatusTag(
                  _config == null ? '默认模型' : '已自定义',
                  tone: _config == null ? TagTone.muted : TagTone.accent,
                ),
              ],
            ),
            SizedBox(height: theme.space.sm),
            Text(
              signedIn
                  ? '当前模型为 ${_config?.model ?? LlmConfig.defaultModel}；请求发往知新服务。'
                  : '登录后可以通过当前知新服务调用模型。',
              style: theme.text.bodySmall.copyWith(
                color: theme.colors.onSurfaceVariant,
              ),
            ),
            if (signedIn)
              Padding(
                padding: EdgeInsets.only(top: theme.space.xs),
                child: Text(
                  AccountService.responsesEndpoint(_account!.serverBaseUrl),
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
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
            forui.FTextField(
              control: .managed(controller: _model),
              label: const Text('模型名'),
              description: const Text(
                '留空使用 ${LlmConfig.defaultModel}，所选模型需要支持工具调用。',
              ),
            ),
            SizedBox(height: context.zhixin.space.gap),
            forui.FTextField(
              control: .managed(controller: _contextWindow),
              keyboardType: TextInputType.number,
              label: const Text('模型上下文上限（token）'),
              description: const Text('按模型公布的上限填写，留空使用 65536。'),
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
                if (_config != null)
                  forui.FButton(
                    variant: forui.FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy ? null : _clearConfig,
                    child: const Text('恢复默认'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, SettingsView? settings) {
    final theme = context.zhixin;
    final signedIn = _account?.signedIn ?? false;
    // 首读失败时按默认值显示，原因写在页面顶部的就地说明里。
    final cutoff = settings?.cutoffHour ?? defaultDayCutoffHour;
    final systemCamera = settings?.useSystemCamera ?? false;
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        if (_loadFailure != null)
          InlineNotice(message: _loadFailure!, onRetry: _retry),
        const SectionHeading(
          title: '学习',
          subtitle: '每天的截止时间与拍照方式影响记录与拍题。',
          first: true,
        ),
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
        const SectionHeading(title: '外观', subtitle: '深浅色与主题色立即生效，只保存在本机。'),
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
                const _CardDivider(),
                AccentPicker(
                  selected: AppScope.of(context).themeAccent.value,
                  onSelected: (accent) async {
                    try {
                      await AppScope.of(context).themeAccent.select(accent);
                    } catch (error, stack) {
                      if (!mounted || !context.mounted) return;
                      _report(
                        _Area.appearance,
                        describeFailure(
                          context,
                          error,
                          stack,
                          action: '保存主题色',
                          kind: 'settings_accent',
                          kept: '当前主题色没有改动',
                          next: '可以再选一次',
                        ),
                        failed: true,
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        ?_resultFor(_Area.appearance),
        const SectionHeading(
          title: '模型与索引',
          subtitle: '语义索引、服务地址与聊天模型；开发者模式默认关闭。',
        ),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.network),
          title: const Text('语义索引'),
          subtitle: Text(_embeddingSubtitle),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: _busy ? null : _openEmbedding,
        ),
        SizedBox(height: theme.space.sm),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: forui.FSwitch(
              label: const Text('开发者模式'),
              description: const Text('调整服务地址、模型配置与 API Key。'),
              value: _developerMode ?? false,
              onChange: _busy || _developerMode == null
                  ? null
                  : _setDeveloperMode,
            ),
          ),
        ),
        ?_resultFor(_Area.developer),
        if (_developerMode == true) ...[
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.network),
            title: const Text('知新服务地址'),
            subtitle: Text(_account?.serverLabel ?? ''),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: _busy ? null : _editServerAddress,
          ),
          SizedBox(height: theme.space.sm),
          forui.FTile(
            prefix: const LeadingIcon(FLucideIcons.keyRound),
            title: const Text('知新 API Key'),
            subtitle: Text(signedIn ? '申请、查看和撤销模型代理密钥' : '登录账号后管理模型代理密钥'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: _busy
                ? null
                : signedIn
                ? () => openModelApiKeys(context)
                : _openAccount,
          ),
          SizedBox(height: theme.space.md),
          _modelConfiguration(signedIn: signedIn),
          ?_resultFor(_Area.model),
        ],
        const SectionHeading(title: '诊断与隐私'),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                forui.FSwitch(
                  label: const Text('发送崩溃报告'),
                  description: const Text(
                    '错误类型、分类与代码位置；不含学习内容。关闭之后立即停止上报，'
                    '本机诊断记录仍单独保存。',
                  ),
                  value: _reportCrashes,
                  onChange: (value) async {
                    final previous = _reportCrashes;
                    setState(() => _reportCrashes = value);
                    CrashLog.reportEnabled = value;
                    try {
                      await DiagnosticsStore(
                        AppScope.of(context).devicePaths.filesDir,
                      ).write(value);
                    } catch (_) {
                      if (!context.mounted) return;
                      setState(() => _reportCrashes = previous);
                      CrashLog.reportEnabled = previous;
                      _report(_Area.diagnostics, '设置没有保存，可以再试一次', failed: true);
                    }
                  },
                ),
                const _CardDivider(),
                forui.FSwitch(
                  label: const Text('匿名使用统计'),
                  description: const Text(
                    '每天最多一次安装标识、应用版本与平台，不含学习内容，也不与账号关联；'
                    '登录之后由服务端按请求日期统计。关闭之后不再上报。',
                  ),
                  value: _reportUsage,
                  onChange: (value) async {
                    final previous = _reportUsage;
                    setState(() => _reportUsage = value);
                    try {
                      await AppScope.of(context).accountServices.activeReport
                          .setEnabled(value);
                    } catch (_) {
                      if (!context.mounted) return;
                      setState(() => _reportUsage = previous);
                      _report(_Area.diagnostics, '设置没有保存，可以再试一次', failed: true);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        ?_resultFor(_Area.diagnostics),
        SizedBox(height: theme.space.sm),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.shieldCheck),
          title: const Text('用户须知与隐私政策'),
          subtitle: Text(
            AppScope.of(context).networkAllowed
                ? '已同意当前版本；登录、云同步与自动检查更新可用。'
                : '现在只在本机使用；同意之后恢复匿名上报、更新检查与登录。',
          ),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => openUserTerms(context),
        ),
        const SectionHeading(title: '更新', subtitle: '有新版本时提示一次，不在应用内安装。'),
        forui.FTile(
          prefix: const LeadingIcon(FLucideIcons.refreshCw),
          title: const Text('检查更新'),
          subtitle: Text(
            _checkingUpdates ? '正在读取发布清单…' : '当前版本 $appVersionLabel；下载后核对安装包。',
          ),
          suffix: _checkingUpdates
              ? const forui.FCircularProgress(size: .sm)
              : const Icon(FLucideIcons.chevronRight),
          onPress: _busy || _checkingUpdates ? null : _checkUpdates,
        ),
        ?_resultFor(_Area.updates),
        const SectionHeading(title: '危险操作', subtitle: '清空之后无法撤销。'),
        forui.FTile(
          variant: forui.FItemVariant.destructive,
          prefix: const LeadingIcon(FLucideIcons.trash2, tone: TagTone.muted),
          title: const Text('清空全部记录'),
          subtitle: const Text('删除本机学习记录、图片与语义索引；保留账号、模型配置与外观。'),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy ? null : _resetAll,
        ),
        ?_resultFor(_Area.danger),
      ],
    );
  }
}

/// 同一张卡片里两组设置之间的分隔线：左右与卡片内容对齐，上下留一档间距。
class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.space.md),
      child: SizedBox(
        height: 1,
        child: ColoredBox(color: theme.colors.outlineVariant),
      ),
    );
  }
}
