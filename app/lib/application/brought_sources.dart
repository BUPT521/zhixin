/// 用户从查找结果带入本次回答的来源；只对下一次回答有效。
///
/// 来源按业务标识记录，例如 `attempt:12`、`message:88`、
/// `material_page:3:7`。讨论页发送时读取这份标识并随本轮请求交给检索，
/// 回答结束后清空，因此带入不会写进讨论、记录或下一轮上下文。
class BroughtSources {
  static final _identity = RegExp(
    r'^(material_page:\d+:\d+|message:\d+|question:\d+|attempt:\d+)$',
  );

  final _identities = <String>{};

  Set<String> get identities => Set.unmodifiable(_identities);
  bool get isEmpty => _identities.isEmpty;
  int get length => _identities.length;

  /// 认得来源标识时才加入；重复加入不增加条数。
  bool add(String identity) {
    final value = identity.trim();
    if (!_identity.hasMatch(value)) return false;
    return _identities.add(value);
  }

  void remove(String identity) => _identities.remove(identity);

  void clear() => _identities.clear();
}
