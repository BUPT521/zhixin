import '../data/repository/evidence_repository.dart';
import '../data/vector/embedding_config_store.dart';
import 'embedding_client.dart';

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
