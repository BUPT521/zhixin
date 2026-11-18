import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart' hide Material;

import 'theme.dart';

import '../app_scope.dart';
import '../application/search_index_service.dart';
import '../data/cloud/server_client.dart';
import '../data/vector/embedding_config_store.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
import 'workspace_widgets.dart';
import 'zhixin_dialog.dart';
import 'zhixin_header.dart';
import 'zhixin_select.dart';

/// 语义索引设置：索引状态、嵌入来源与可发送范围三段。
///
/// 没有配置或关闭时，语义检索不可用，原文与关键词检索照常工作；远程嵌入只有
/// 在用户选定范围之后才会发送原文。业务库与向量库都保存在本机。
///
/// 嵌入来源可以是自填接口、知新服务或本机哈希。选择知新服务时模型从服务端
/// 的嵌入模型里选，后台配置了维度就直接带上，不再让用户填地址与 key。
class EmbeddingSettingsPage extends StatefulWidget {
  const EmbeddingSettingsPage({super.key});

  @override
  State<EmbeddingSettingsPage> createState() => _EmbeddingSettingsPageState();
}

class _EmbeddingSettingsPageState extends State<EmbeddingSettingsPage> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _dim = TextEditingController(text: '1024');
  final _apiKey = TextEditingController();

  bool _enabled = false;
  String _provider = EmbeddingProvider.remote.value;

  /// 是否已经登录；知新服务要登录之后才能用。
  bool _signedIn = false;

  /// 服务端的嵌入模型；没有登录或读取失败时为空。
  List<ServerModel> _serverModels = const [];

  /// 知新服务选中的嵌入模型；与自填接口的模型名分开保存，切换来源不互相覆盖。
  String _serverModel = '';

  /// 服务端模型还在读取。
  bool _serverModelsLoading = false;
  EmbeddingShareScope _shareScope = EmbeddingShareScope.off;
  final Set<String> _selectedMaterials = {};
  List<Material> _materials = const [];
  IndexStats? _stats;
  bool _statsFailed = false;
  bool _busy = false;
  String? _status;
  String? _statusDetail;
  String? _notice;

  /// 首读完成之前只显示骨架，不先摆出默认值再跳成已保存的配置。
  bool _loading = true;

  /// 首读失败：失败说明放到页面顶部，就地给重试。
  bool _loadFailed = false;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面要读应用根上的仓库与设置，等依赖就绪后再读一次。
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _dim.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// 读取设置、材料与索引状态。
  ///
  /// 索引状态与设置分开读：向量库打不开时仍显示已经保存的设置，并把失败原因
  /// 写在页面上；不能因为没有状态就把页面一直停在“还没有读取索引状态”。
  Future<void> _load() async {
    final scope = AppScope.of(context);
    EmbeddingConfig? config;
    var materials = const <Material>[];
    Object? loadFailure;
    StackTrace? loadStack;
    try {
      config = await scope.settings.embedding.read();
      materials = await scope.library.material.list();
    } catch (error, stack) {
      loadFailure = error;
      loadStack = stack;
    }
    var signedIn = false;
    try {
      signedIn = (await scope.accountServices.account.snapshot()).signedIn;
    } catch (_) {
      // 登录状态只影响知新服务的说明；读不到时按未登录处理。
    }
    IndexStats? stats;
    Object? statsFailure;
    StackTrace? statsStack;
    try {
      stats = await scope.library.searchIndex.stats();
    } catch (error, stack) {
      statsFailure = error;
      statsStack = stack;
    }
    if (!mounted) return;
    String? notice;
    if (loadFailure != null) {
      notice = describeFailure(
        context,
        loadFailure,
        loadStack!,
        action: '读取语义索引设置',
        kind: 'embedding_config',
        kept: '已经保存的设置没有改动',
        next: '可以重新打开这一页',
      );
    } else if (statsFailure != null) {
      notice = describeFailure(
        context,
        statsFailure,
        statsStack!,
        action: '读取索引状态',
        kind: 'semantic_index',
        kept: '已经保存的设置没有改动',
        next: '可以点“更新索引”再试',
      );
    }
    // 结果回来时若还在推入动画里，等动画结束再填入。
    await context.afterTransition();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadFailed = loadFailure != null;
      _materials = materials;
      _stats = stats;
      _statsFailed = statsFailure != null;
      _notice = notice;
      _signedIn = signedIn;
      if (config != null) {
        _enabled = config.enabled;
        _provider = config.provider;
        _baseUrl.text = config.baseUrl;
        _dim.text = '${config.dim}';
        if (config.usesServer) {
          _serverModel = config.model;
        } else {
          _model.text = config.model;
        }
        _apiKey.text = config.apiKey;
        _shareScope = config.shareScope;
        _selectedMaterials
          ..clear()
          ..addAll(config.materialIds);
      }
    });
    if (signedIn) unawaited(_loadServerModels(scope));
  }

  /// 读服务端的嵌入模型，要走网络，不挡住本页首读；回来之后补上选项，并按
  /// 服务端给出的维度校正已保存的知新服务配置。
  Future<void> _loadServerModels(AppScopeState scope) async {
    setState(() => _serverModelsLoading = true);
    var models = const <ServerModel>[];
    try {
      models = [
        for (final model in await scope.accountServices.account.models())
          if (model.isEmbedding) model,
      ];
    } catch (_) {
      // 只用于知新服务的选项；读不到时按没有可选模型说明，不打断本页。
    }
    if (!mounted) return;
    setState(() {
      _serverModelsLoading = false;
      _serverModels = models;
      if (_provider == EmbeddingProvider.server.value) {
        _applyServerModel(
          _serverModel.isEmpty && models.isNotEmpty
              ? models.first.id
              : _serverModel,
        );
      }
    });
  }

  /// 首读失败时的重试：回到骨架，再读一次设置、材料与索引状态。
  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _notice = null;
    });
    await _load();
  }

  static String _failureLabel(IndexFailure failure) => switch (failure) {
    IndexFailure.none => '正常',
    IndexFailure.notConfigured => '没有启用语义索引',
    IndexFailure.timeout => '请求超时',
    IndexFailure.cancelled => '已经取消',
    IndexFailure.error => '请求失败',
  };

  /// 知新服务里当前选中的模型；不在列表里时为空。
  ServerModel? get _selectedServerModel {
    for (final model in _serverModels) {
      if (model.id == _serverModel) return model;
    }
    return null;
  }

  /// 选中知新服务的模型：后台配置了维度时直接带上。
  void _pickServerModel(String? id) => setState(() => _applyServerModel(id));

  void _applyServerModel(String? id) {
    _serverModel = id ?? '';
    final dimensions = _selectedServerModel?.dimensions;
    if (dimensions != null) _dim.text = '$dimensions';
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    final source = EmbeddingProvider.fromValue(_provider);
    final dim = int.tryParse(_dim.text.trim()) ?? 0;
    if (dim <= 0 || dim > 4096) {
      setState(() => _notice = '向量维度需要是 1 到 4096 之间的整数。');
      return;
    }
    if (_enabled && source == EmbeddingProvider.remote) {
      if (_baseUrl.text.trim().isEmpty || _model.text.trim().isEmpty) {
        setState(() => _notice = '远程嵌入需要填写接口地址和模型名。');
        return;
      }
    }
    if (_enabled && source == EmbeddingProvider.server) {
      if (!_signedIn) {
        setState(() => _notice = '知新服务要先登录；可以在“我的”里登录之后再回来保存。');
        return;
      }
      if (_selectedServerModel == null) {
        setState(() => _notice = '请先选择一个服务端提供的嵌入模型。');
        return;
      }
    }
    if (_enabled &&
        source != EmbeddingProvider.local &&
        _shareScope == EmbeddingShareScope.off) {
      setState(() => _notice = '远程嵌入需要明确选择可发送的原文范围，否则不会发送任何内容。');
      return;
    }
    final server = source == EmbeddingProvider.server;
    final config = EmbeddingConfig(
      enabled: _enabled,
      provider: _provider,
      // 知新服务的地址与令牌运行时取，不写进配置；自填接口的地址与 key 也
      // 不随来源切换带过去。
      baseUrl: server ? '' : _baseUrl.text.trim(),
      model: server ? _serverModel : _model.text.trim(),
      dim: dim,
      apiKey: server ? '' : _apiKey.text.trim(),
      shareScope: _shareScope,
      materialIds: _selectedMaterials.toList(growable: false),
    );
    setState(() {
      _busy = true;
      _notice = null;
      _status = null;
      _statusDetail = null;
    });
    try {
      await scope.settings.embedding.save(config);
      _report('设置已经保存，正在按当前数据更新索引…');
      await _refresh(scope, true);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '保存语义索引设置',
          kind: 'embedding_config',
          kept: '已经保存的原文与记录没有改动',
          next: '可以稍后再试',
        );
      });
    }
  }

  /// 更新结果同时留在本页的索引状态里，并把毫秒数折叠进“耗时详情”。
  void _report(String summary, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _status = summary;
      _statusDetail = detail;
    });
  }

  Future<void> _refresh([AppScopeState? scope, bool keepBusy = false]) async {
    final app = scope ?? AppScope.of(context);
    if (!keepBusy) setState(() => _busy = true);
    try {
      final result = await app.library.searchIndex.refresh();
      final stats = await app.library.searchIndex.stats();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stats = stats;
        _statsFailed = false;
        _notice = null;
        _status = _describeRefresh(result);
        _statusDetail = _describeRefreshDetail(result);
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '更新语义索引',
          kind: 'semantic_index',
          kept: '已经保存的原文与记录没有改动',
          next: '可以稍后再试；检索会继续使用原文与关键词',
        );
      });
    }
  }

  /// 一次更新的摘要：只说处理了多少来源、写入了多少条，规则写清楚。
  String _describeRefresh(IndexRefreshResult result) {
    if (result.failure == IndexFailure.notConfigured) {
      return '没有启用语义索引，本次没有读写向量库。';
    }
    if (result.failure == IndexFailure.cancelled) {
      return '本次索引更新已经取消。';
    }
    final failed = result.failed > 0 ? '，失败 ${result.failed} 条' : '';
    final problem = result.sourceProblem;
    if (problem != null) {
      return '本次更新在中途停下：$problem。已经写入 ${result.embedded} 条，'
          '其余 ${result.failed} 条等下一次更新再补。';
    }
    if (result.total == 0) {
      return '没有需要更新的来源；下一次记录或材料变化后会自动补上。';
    }
    return '本次检查 ${result.total} 条来源：写入 ${result.embedded} 条，'
        '跳过 ${result.skipped} 条$failed，清理 ${result.removed} 条旧向量。';
  }

  /// 耗时只放在折叠起来的详情里，不占摘要。
  String _describeRefreshDetail(IndexRefreshResult result) =>
      '嵌入耗时 ${result.embedMs} 毫秒，写索引 ${result.writeMs} 毫秒。';

  /// 用一条固定查询走完整检索：嵌入、查索引与核对来源。
  Future<void> _probeQuery() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final result = await app.library.searchIndex.search(
        '熵与能量有什么关系',
        scope: const EvidenceScope.userAll(),
        limit: 3,
        timeout: const Duration(seconds: 6),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = null;
        if (result.failure == IndexFailure.none) {
          _status =
              '测试查询成功，找到 ${result.hits.length} 条相关记录；'
              '索引里现在有 ${result.entries} 条向量。';
          _statusDetail =
              '嵌入耗时 ${result.timings.embedMs} 毫秒，'
              '查索引 ${result.timings.indexMs} 毫秒，'
              '完整检索 ${result.timings.totalMs} 毫秒。';
        } else {
          _status = '测试查询没有完成：${_failureLabel(result.failure)}。';
          _statusDetail = null;
        }
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '测试一次语义查询',
          kind: 'semantic_index',
          kept: '已经保存的原文与记录没有改动',
          next: '可以检查接口地址、模型与网络后再试',
        );
      });
    }
  }

  /// 清空索引会删掉本机全部向量；先做危险确认，入口放在页底。
  Future<void> _clearIndex() async {
    final confirmed = await confirmZhixin(
      context: context,
      title: '清空语义索引',
      content: const Text(
        '将删除本机保存的全部向量索引，原文、作答与材料不受影响，'
        '之后可以按当前数据重新更新。此操作无法撤销。',
      ),
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await scope.library.searchIndex.clear();
      final stats = await scope.library.searchIndex.stats();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stats = stats;
        _statsFailed = false;
        _notice = null;
        _status = '向量索引已经清空，可以按当前数据重新更新。';
        _statusDetail = null;
      });
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = describeFailure(
          context,
          error,
          stack,
          action: '清空语义索引',
          kind: 'semantic_index',
          kept: '已经保存的原文与记录没有改动',
          next: '可以稍后再试',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    if (_loading) {
      return DetailScaffold(
        header: const ZhixinHeader(title: Text('语义索引'), showBack: true),
        child: ListView(
          padding: theme.space.pageInsets(),
          children: const [ListSkeleton(rows: 3, rowHeight: 96)],
        ),
      );
    }
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('语义索引'), showBack: true),
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final theme = context.zhixin;
    final stats = _stats;
    final configured = stats?.configured ?? false;
    final source = EmbeddingProvider.fromValue(_provider);
    final remote = source == EmbeddingProvider.remote;
    final server = source == EmbeddingProvider.server;
    final sendsText = source != EmbeddingProvider.local;
    final serverDimensions = _selectedServerModel?.dimensions;
    return ListView(
      padding: theme.space.pageInsets(),
      children: [
        if (_loadFailed && _notice != null)
          InlineNotice(message: _notice!, onRetry: _retry),
        SectionHeading(
          title: '索引状态',
          subtitle:
              '语义检索用来找回措辞不同但可能相关的作答与材料；'
              '没有启用时，原文与关键词检索照常工作。',
          first: true,
          action: StatusTag(
            configured ? '已启用' : '未启用',
            tone: configured ? TagTone.accent : TagTone.muted,
          ),
        ),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                forui.FSwitch(
                  label: const Text('启用语义索引'),
                  description: const Text('关闭时不读取向量库，也不发送任何原文；改动在保存后生效。'),
                  value: _enabled,
                  onChange: (value) => setState(() => _enabled = value),
                ),
                SizedBox(height: theme.space.md),
                if (stats == null)
                  Text(
                    _statsFailed ? '索引状态暂时无法读取；可以点“更新索引”再试。' : '还没有读取索引状态。',
                    style: theme.text.bodyMedium,
                  )
                else if (!stats.configured)
                  Text('语义索引没有启用；回答只使用原文与关键词检索。', style: theme.text.bodyMedium)
                else ...[
                  TagRow(
                    children: [
                      StatusTag('${stats.sources} 条来源'),
                      StatusTag('${stats.entries} 条向量'),
                    ],
                  ),
                  SizedBox(height: theme.space.xs),
                  Text(
                    '模型 ${stats.modelKey}'
                    '${stats.builtAt == null ? '' : '，最近更新 ${stats.builtAt}'}',
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_status != null) ...[
                  SizedBox(height: theme.space.sm),
                  Text(_status!, style: theme.text.bodyMedium),
                  if (_statusDetail != null)
                    forui.FAccordion(
                      style: const .delta(
                        titlePadding: .value(EdgeInsets.symmetric(vertical: 4)),
                        childPadding: .value(EdgeInsets.only(bottom: 4)),
                        dividerStyle: .delta(color: Colors.transparent),
                      ),
                      children: [
                        forui.FAccordionItem(
                          title: Text('耗时详情', style: theme.text.bodySmall),
                          child: Text(
                            _statusDetail!,
                            style: theme.text.bodySmall.copyWith(
                              color: theme.colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
                if (!_loadFailed && _notice != null) ...[
                  SizedBox(height: theme.space.sm),
                  InlineNotice(message: _notice!),
                ],
                if (_busy)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: theme.space.sm),
                    child: const forui.FProgress(),
                  ),
                SizedBox(height: theme.space.md),
                Wrap(
                  spacing: theme.space.sm,
                  runSpacing: theme.space.sm,
                  children: [
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy || !configured ? null : _refresh,
                      child: const Text('更新索引'),
                    ),
                    forui.FButton(
                      variant: forui.FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy || !configured ? null : _probeQuery,
                      child: const Text('测试查询'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SectionHeading(
          title: '嵌入来源',
          subtitle: '远程嵌入按服务商的接口地址与模型名调用；知新服务用登录账号走服务端；本机哈希不联网，效果有限。',
        ),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZhixinSelect<String>(
                  value: _provider,
                  label: '嵌入来源',
                  options: {
                    EmbeddingProvider.remote.value: '远程嵌入（OpenAI 兼容接口）',
                    EmbeddingProvider.server.value: '知新服务（登录账号）',
                    EmbeddingProvider.local.value: '本机哈希（不联网，效果有限）',
                  },
                  onChange: (value) => setState(() {
                    _provider = value ?? EmbeddingProvider.remote.value;
                    if (_provider == EmbeddingProvider.server.value) {
                      _applyServerModel(
                        _serverModel.isEmpty && _serverModels.isNotEmpty
                            ? _serverModels.first.id
                            : _serverModel,
                      );
                    }
                  }),
                ),
                if (server) ...[
                  SizedBox(height: theme.space.gap),
                  if (!_signedIn)
                    Text(
                      '还没有登录。知新服务用登录账号的访问令牌，按账号计每天的嵌入额度；'
                      '登录之后回到这一页选择模型。',
                      style: theme.text.bodyMedium,
                    )
                  else if (_serverModelsLoading)
                    Text('正在读取服务端的嵌入模型…', style: theme.text.bodyMedium)
                  else if (_serverModels.isEmpty)
                    Text(
                      '服务端暂时没有可用的嵌入模型，或者模型列表没有读到；'
                      '可以稍后重新打开这一页，或者改用自填接口。',
                      style: theme.text.bodyMedium,
                    )
                  else ...[
                    ZhixinSelect<String>(
                      value: _serverModel,
                      label: '嵌入模型',
                      description: '原文经知新服务转给后台配置的提供方，额度与聊天分开计。',
                      options: {
                        for (final model in _serverModels)
                          model.id: model.dimensions == null
                              ? model.id
                              : '${model.id}（${model.dimensions} 维）',
                      },
                      onChange: _pickServerModel,
                    ),
                    SizedBox(height: theme.space.gap),
                    if (serverDimensions != null)
                      Text(
                        '向量维度 $serverDimensions，由服务端给出。',
                        style: theme.text.bodySmall.copyWith(
                          color: theme.colors.onSurfaceVariant,
                        ),
                      )
                    else
                      forui.FTextField(
                        control: .managed(controller: _dim),
                        keyboardType: TextInputType.number,
                        label: const Text('向量维度'),
                        description: const Text('服务端没有给出维度，按模型说明填写'),
                      ),
                  ],
                ],
                if (remote) ...[
                  SizedBox(height: theme.space.gap),
                  forui.FTextField(
                    control: .managed(controller: _baseUrl),
                    label: const Text('接口地址'),
                    hint: 'https://api.example.com/v1',
                  ),
                  SizedBox(height: theme.space.gap),
                  forui.FTextField(
                    control: .managed(controller: _model),
                    label: const Text('模型名'),
                    hint: '中文嵌入模型',
                  ),
                  SizedBox(height: theme.space.gap),
                  forui.FTextField(
                    control: .managed(controller: _apiKey),
                    obscureText: true,
                    label: const Text('API Key'),
                    description: const Text('只保存在本机，不进入数据包'),
                  ),
                  SizedBox(height: theme.space.gap),
                  forui.FTextField(
                    control: .managed(controller: _dim),
                    keyboardType: TextInputType.number,
                    label: const Text('向量维度'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SectionHeading(
          title: '可发送范围',
          subtitle: '远程嵌入与知新服务只发送下面选中的范围；讨论消息与作答按所属材料判断。',
        ),
        forui.FCard(
          child: Padding(
            padding: EdgeInsets.all(theme.space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!sendsText)
                  Text('本机哈希不联网，不需要选择发送范围。', style: theme.text.bodyMedium)
                else ...[
                  for (final scope in EmbeddingShareScope.values)
                    forui.FRadio(
                      value: _shareScope == scope,
                      label: Text(scope.label),
                      semanticsLabel: '可发送范围：${scope.label}',
                      onChange: (_) => setState(() => _shareScope = scope),
                    ),
                  if (_shareScope == EmbeddingShareScope.selectedMaterials) ...[
                    SizedBox(height: theme.space.sm),
                    if (_materials.isEmpty)
                      Text(
                        '还没有材料；可以先在记录里导入材料。',
                        style: theme.text.bodySmall.copyWith(
                          color: theme.colors.onSurfaceVariant,
                        ),
                      )
                    else
                      for (final material in _materials)
                        forui.FCheckbox(
                          value: _selectedMaterials.contains(material.id),
                          label: Text(material.title),
                          onChange: (value) => setState(() {
                            if (value) {
                              _selectedMaterials.add(material.id);
                            } else {
                              _selectedMaterials.remove(material.id);
                            }
                          }),
                        ),
                  ],
                ],
                SizedBox(height: theme.space.md),
                forui.FButton(
                  onPress: _busy ? null : _save,
                  child: const Text('保存并更新索引'),
                ),
              ],
            ),
          ),
        ),
        const SectionHeading(
          title: '危险操作',
          subtitle: '清空索引只删除本机保存的向量索引，原文与记录不受影响。',
        ),
        forui.FTile(
          variant: forui.FItemVariant.destructive,
          prefix: const LeadingIcon(FLucideIcons.trash2, tone: TagTone.muted),
          title: const Text('清空索引'),
          subtitle: const Text('清空之后“按意思找”暂时没有内容，可以按当前数据重新更新。'),
          suffix: const Icon(FLucideIcons.trash2),
          onPress: _busy || !configured ? null : _clearIndex,
        ),
      ],
    );
  }
}
