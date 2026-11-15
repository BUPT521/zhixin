/// 证据来源标识的唯一写法：同一业务记录在任何检索路径上得到同一个字符串。
///
/// 关键词、语义与跨次检索都按这个标识合并；散在各处的 `message:$id` 一类
/// 拼接集中到这里，格式改动只需要改一处。
class EvidenceId {
  const EvidenceId(this.value);

  factory EvidenceId.materialPage(int materialId, int pageNo) =>
      EvidenceId('material_page:$materialId:$pageNo');

  factory EvidenceId.message(int messageId) => EvidenceId('message:$messageId');

  factory EvidenceId.attempt(int attemptId) => EvidenceId('attempt:$attemptId');

  factory EvidenceId.question(int conversationId) =>
      EvidenceId('question:$conversationId');

  factory EvidenceId.conversation(int conversationId) =>
      EvidenceId('conversation:$conversationId');

  final String value;

  @override
  bool operator ==(Object other) => other is EvidenceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
