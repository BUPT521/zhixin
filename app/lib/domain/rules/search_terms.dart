/// 本地检索的关键词切分：去掉标点，保留单字术语；[maxTerms] 为空时不限制个数。
///
/// 只用于把当前问题与材料页、较早记录做粗匹配，不替代语义检索。
/// 用户整句提问时，再按常见虚词切开；否则整句连在一起，永远匹配不上
/// 材料页里的短句。单字课程术语（例如“熵”“秩”）也要能检索，因此不再按
/// 长度过滤，只去掉空白与标点。
const _stopWords = [
  '的',
  '是',
  '在',
  '有',
  '和',
  '与',
  '我',
  '你',
  '他',
  '她',
  '它',
  '这',
  '那',
  '什么',
  '怎么',
  '怎样',
  '如何',
  '为什么',
  '请问',
  '请',
  '帮',
  '一下',
  '告诉',
  '吗',
  '呢',
  '吧',
  '啊',
  '里',
  '中',
  '上',
  '下',
  '个',
  '还',
  '就',
  '也',
  '都',
  '很',
  '能',
  '会',
  '要',
  '把',
  '被',
  '给',
  '对',
  '从',
  '到',
  '为',
  '以',
  '及',
  '或',
  '而',
  '但',
  '如果',
  '因为',
  '所以',
  '可以',
  '需要',
  '应该',
];

List<String> searchTerms(String query, {int? maxTerms}) {
  final parts = query
      .split(RegExp(r'[\s，。；：！？、,.;:?!()（）《》【】"“”‘’\-—…]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  final terms = <String>[];
  for (final part in parts) {
    if (part.length <= 4) {
      terms.add(part);
      continue;
    }
    final pieces = part
        .split(RegExp(_stopWords.join('|')))
        .map((piece) => piece.trim())
        .where((piece) => piece.isNotEmpty);
    if (pieces.isEmpty) {
      terms.add(part);
    } else {
      terms.addAll(pieces);
    }
  }
  final unique = <String>[];
  for (final term in terms) {
    if (!unique.contains(term)) unique.add(term);
  }
  if (unique.isEmpty) {
    final single = query.trim();
    return single.isEmpty ? const [] : [single];
  }
  return maxTerms == null
      ? unique
      : unique.take(maxTerms).toList(growable: false);
}

String searchSnippet(String content, Iterable<String> terms, {int limit = 80}) {
  final text = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= limit) return text;
  var matchAt = -1;
  for (final term in terms) {
    final index = text.toLowerCase().indexOf(term.toLowerCase());
    if (index >= 0 && (matchAt < 0 || index < matchAt)) matchAt = index;
  }
  if (matchAt < 0) return '${text.substring(0, limit)}…';
  final start = (matchAt - (limit ~/ 3)).clamp(0, text.length);
  final end = (start + limit).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}'
      '${end < text.length ? '…' : ''}';
}
