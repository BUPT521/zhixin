import '../data/repository/evidence_repository.dart';
import '../data/vector/embedding_config_store.dart';
import 'embedding_client.dart';
import 'search_index_service.dart';

/// 按配置构造嵌入来源与发送范围。
///
/// 远程来源只允许发送用户选定的范围：`all` 发送本机记录，`selectedMaterials`
/// 只发送属于选定材料的来源，`off` 不发送。本机哈希不联网，不做范围限制。
/// 没有配置或配置不完整时返回空来源，语义检索按不可用处理，原文与关键词
/// 检索照常完成。
({EmbeddingClient? client, bool Function(SemanticSource source)? canSend})
embeddingRuntime(EmbeddingConfig? config) {
  if (config == null || !config.usable) {
    return (client: null, canSend: null);
  }
  if (!config.usesRemote) {
    return (
      client: HashingEmbeddingClient(dim: config.dim, id: config.spec.id),
      canSend: null,
    );
  }
  final client = RemoteEmbeddingClient(
    spec: config.spec,
    endpoint: config.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
    apiKey: config.apiKey,
  );
  final scope = config.shareScope;
  final allowed = config.materialIds.toSet();
  bool canSend(SemanticSource source) {
    if (scope == EmbeddingShareScope.off) return false;
    if (scope == EmbeddingShareScope.all) return true;
    final materialId = source.locator.materialId;
    return materialId != null && allowed.contains(materialId);
  }

  return (client: client, canSend: canSend);
}

/// 索引的嵌入配置入口：读写嵌入配置，并把配置应用到索引服务。
///
/// 设置页只调用 [save] 一次，写入安全存储与换掉嵌入来源在同一次调用里完成；
/// 模型或维度改变时，[SearchIndexService.configure] 把旧索引的关闭排进操作
/// 队列，下一次打开等这次关闭完成。应用根启动时用 [read] 与 [apply] 恢复上次
/// 保存的配置。
class EmbeddingSettingsService {
  EmbeddingSettingsService({required this.store, required this.index});

  final EmbeddingConfigStore store;
  final SearchIndexService index;

  EmbeddingConfig? _current;

  /// 当前已经应用的配置；没有读取或配置被关闭时为空。
  EmbeddingConfig? get current => _current;

  /// 是否配置了可用的嵌入来源。
  bool get configured => index.configured;

  /// 读取保存的配置；读坏了按没有配置处理。
  Future<EmbeddingConfig?> read() => store.read();

  /// 保存并应用配置。
  ///
  /// 存储写入失败时抛错，页面据此提示，已经保存的配置没有被替换。
  Future<void> save(EmbeddingConfig config) async {
    await store.save(config);
    apply(config);
  }

  /// 应用一套配置，不写入存储；启动恢复与测试装配走这里。
  void apply(EmbeddingConfig? config) {
    _current = config;
    final runtime = embeddingRuntime(config);
    index.configure(client: runtime.client, canSend: runtime.canSend);
  }
}
