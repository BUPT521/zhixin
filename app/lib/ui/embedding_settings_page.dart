import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart' hide Material;

import 'theme.dart';

import '../app_scope.dart';
import '../application/semantic_index_service.dart';
import '../data/vector/embedding_config_store.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import 'failure_feedback.dart';
import 'workspace_widgets.dart';
import 'zhixin_header.dart';
import 'zhixin_select.dart';

/// 语义索引设置：选择嵌入来源、明确可发送的原文范围，并查看索引规模与耗时。
///
/// 没有配置或关闭时，语义检索不可用，原文与关键词检索照常工作；远程嵌入只有
/// 在用户选定范围之后才会发送原文。业务库与向量库都保存在本机。
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
  String _provider = 'remote';
  EmbeddingShareScope _shareScope = EmbeddingShareScope.off;
  final Set<int> _selectedMaterials = {};
  List<Material> _materials = const [];
  SemanticIndexStats? _stats;
  bool _busy = false;
  String? _status;
  String? _notice;

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

  Future<void> _load() async {
    final scope = AppScope.of(context);
    final config = await scope.embeddingStore.read();
    final materials = await scope.materials.list();
    final stats = await scope.semanticIndex.stats();
    if (!mounted) return;
    setState(() {
      _materials = materials;
      _stats = stats;
      if (config != null) {
        _enabled = config.enabled;
        _provider = config.provider;
        _baseUrl.text = config.baseUrl;
        _model.text = config.model;
        _dim.text = '${config.dim}';
        _apiKey.text = config.apiKey;
        _shareScope = config.shareScope;
        _selectedMaterials
          ..clear()
          ..addAll(config.materialIds);
      }
    });
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    final dim = int.tryParse(_dim.text.trim()) ?? 0;
    if (dim <= 0 || dim > 4096) {
      setState(() => _notice = '维度需要是 1 到 4096 之间的整数。');
      return;
    }
    if (_enabled && _provider == 'remote') {
      if (_baseUrl.text.trim().isEmpty || _model.text.trim().isEmpty) {
        setState(() => _notice = '远程嵌入需要填写接口地址和模型名称。');
        return;
      }
      if (_shareScope == EmbeddingShareScope.off) {
        setState(() => _notice = '远程嵌入需要明确选择可发送的原文范围，否则不会发送任何内容。');
        return;
      }
    }
    final config = EmbeddingConfig(
      enabled: _enabled,
      provider: _provider,
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      dim: dim,
      apiKey: _apiKey.text.trim(),
      shareScope: _shareScope,
      materialIds: _selectedMaterials.toList(growable: false),
    );
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await scope.embeddingStore.save(config);
      scope.applyEmbeddingConfig(config, refresh: false);
      await _refresh(scope);
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

  Future<void> _refresh([AppScopeState? scope]) async {
    final app = scope ?? AppScope.of(context);
    setState(() => _busy = true);
    try {
      final result = await app.semanticIndex.refresh();
      final stats = await app.semanticIndex.stats();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stats = stats;
        _status = _describeRefresh(result);
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

  String _describeRefresh(IndexRefreshResult result) {
    if (result.failure == SemanticFailure.notConfigured) {
      return '没有启用语义索引，本次没有读写向量库。';
    }
    return '已处理 ${result.total} 条来源：写入 ${result.embedded} 条，'
        '跳过 ${result.skipped} 条，等待期间来源已变化 ${result.lateSkipped} 条，'
        '失败 ${result.failed} 条，清理 ${result.removed} 条；'
        '嵌入 ${result.embedMs} ms，写索引 ${result.writeMs} ms。';
  }

  /// 用一条固定查询走完整检索：嵌入、查索引与核对来源，界面显示三段耗时。
  Future<void> _probeQuery() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final result = await app.semanticIndex.search(
        '熵与能量有什么关系',
        scope: const EvidenceScope.userAll(),
        limit: 3,
        timeout: const Duration(seconds: 6),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status =
            '测试查询：${result.failure == SemanticFailure.none ? '成功' : result.failure.name}；'
            '命中 ${result.hits.length} 条；'
            '嵌入 ${result.timings.embedMs} ms，查索引 ${result.timings.indexMs} ms，'
            '完整检索 ${result.timings.totalMs} ms。';
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

  Future<void> _clearIndex() async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await scope.semanticIndex.clear();
      final stats = await scope.semanticIndex.stats();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stats = stats;
        _status = '向量索引已经清空，可以按当前数据重新更新。';
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
    final stats = _stats;
    return DetailScaffold(
      header: const ZhixinHeader(title: Text('语义索引'), showBack: true),
      child: ListView(
        padding: theme.space.pageInsets(),
        children: [
          Text(
            '语义检索用来找回措辞不同但可能相关的作答与材料。没有配置或关闭时，'
            '原文查找与关键词检索照常工作。向量索引单独保存在本机，可以按当前数据重建。',
            style: theme.text.bodyMedium,
          ),
          const SizedBox(height: 8),
          forui.FSwitch(
            label: const Text('启用语义索引'),
            description: const Text('关闭时不读取向量库，也不发送任何原文'),
            value: _enabled,
            onChange: (value) => setState(() => _enabled = value),
          ),
          ZhixinSelect<String>(
            value: _provider,
            label: '嵌入来源',
            options: const {
              'remote': '远程嵌入（OpenAI 兼容接口）',
              'local': '本机哈希（不联网，效果有限）',
            },
            onChange: (value) => setState(() => _provider = value ?? 'remote'),
          ),
          if (_provider == 'remote') ...[
            const SizedBox(height: 12),
            forui.FTextField(
              control: .managed(controller: _baseUrl),
              label: const Text('接口地址'),
              hint: 'https://api.example.com/v1',
            ),
            const SizedBox(height: 12),
            forui.FTextField(
              control: .managed(controller: _model),
              label: const Text('模型名称'),
              hint: '中文嵌入模型',
            ),
            const SizedBox(height: 12),
            forui.FTextField(
              control: .managed(controller: _apiKey),
              obscureText: true,
              label: const Text('密钥'),
              description: const Text('只保存在本机安全存储，不进入数据包'),
            ),
            const SizedBox(height: 12),
            forui.FTextField(
              control: .managed(controller: _dim),
              keyboardType: TextInputType.number,
              label: const Text('向量维度'),
            ),
            const SizedBox(height: 16),
            Text('可发送给嵌入服务的原文范围', style: theme.text.titleSmall),
            const SizedBox(height: 4),
            Text(
              '远程嵌入只发送下面选中的范围。讨论消息与作答按所属材料判断；'
              '没有材料归属的记录只有在选择“本机全部记录”时才会发送。',
              style: theme.text.bodySmall,
            ),
            const SizedBox(height: 4),
            for (final scope in EmbeddingShareScope.values)
              forui.FRadio(
                value: _shareScope == scope,
                label: Text(scope.label),
                onChange: (_) => setState(() => _shareScope = scope),
              ),
            if (_shareScope == EmbeddingShareScope.selectedMaterials)
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
          const SizedBox(height: 16),
          Wrap(
            spacing: theme.space.sm,
            runSpacing: theme.space.sm,
            children: [
              forui.FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _save,
                child: const Text('保存并更新索引'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _refresh,
                child: const Text('更新索引'),
              ),
              if (_stats?.configured == true)
                forui.FButton(
                  variant: forui.FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _probeQuery,
                  child: const Text('测试查询'),
                ),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy ? null : _clearIndex,
                child: const Text('清空索引'),
              ),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: forui.FProgress(),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _notice!,
                style: TextStyle(color: theme.colors.error),
              ),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!, style: theme.text.bodySmall),
            ),
          const SizedBox(height: 16),
          Text('索引状态', style: theme.text.titleSmall),
          const SizedBox(height: 4),
          if (stats == null)
            const Text('还没有读取索引状态。')
          else if (!stats.configured)
            const Text('语义索引没有启用；回答只使用原文与关键词检索。')
          else
            Text(
              '${stats.entries} 条向量，${stats.sources} 条来源，'
              '模型 ${stats.modelKey}'
              '${stats.builtAt == null ? '' : '，最近更新 ${stats.builtAt}'}',
              style: theme.text.bodyMedium,
            ),
          if (stats?.lastRefresh != null) ...[
            const SizedBox(height: 8),
            Text(
              _describeRefresh(stats!.lastRefresh!),
              style: theme.text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
