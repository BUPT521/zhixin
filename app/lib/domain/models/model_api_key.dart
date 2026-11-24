/// 账号下的模型代理密钥信息。完整密钥由签发接口单独返回。
class ModelApiKey {
  const ModelApiKey({
    required this.id,
    required this.name,
    required this.prefix,
    required this.revoked,
    required this.createdAt,
    this.lastUsedAt,
  });

  final String id;
  final String name;
  final String prefix;
  final bool revoked;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
}
