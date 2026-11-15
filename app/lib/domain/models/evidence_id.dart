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

  /// 解析标识；格式不对或编号不是整数时返回空。
  static EvidenceId? tryParse(String value) {
    final text = value.trim();
    final parts = text.split(':');
    if (parts.isEmpty) return null;
    final kind = parts.first;
    if (kind == 'material_page') {
      if (parts.length != 3) return null;
      if (int.tryParse(parts[1]) == null || int.tryParse(parts[2]) == null) {
        return null;
      }
    } else if (_singleIdKinds.contains(kind)) {
      if (parts.length != 2 || int.tryParse(parts[1]) == null) return null;
    } else {
      return null;
    }
    return EvidenceId(text);
  }

  static const Set<String> _singleIdKinds = {
    'message',
    'attempt',
    'question',
    'conversation',
  };

  /// 类型前缀：material_page、message、ttempt、question 或 conversation。
  String get kind => value.split(':').first;

  /// 第二段编号：材料页是材料编号，其余是记录编号。
  int? get primaryId {
    final parts = value.split(':');
    return parts.length < 2 ? null : int.tryParse(parts[1]);
  }

  /// 材料页的页码；其他类型为空。
  int? get pageNo {
    final parts = value.split(':');
    return parts.length < 3 ? null : int.tryParse(parts[2]);
  }

  final String value;

  @override
  bool operator ==(Object other) => other is EvidenceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
