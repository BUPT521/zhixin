import 'search_terms.dart';

/// 一次查询的形态：按原样匹配，还是按关键词切分。
///
/// 题号、公式、带下划线的符号和被引号括起来的原句按原样查找，不对整句切词，
/// 否则 `例 3-2`、`f(x)`、`a_b` 会被拆成单字，命中大量近似记录；普通问句继续
/// 使用关键词检索，整句原样匹配同时保留，命中原文时以字面命中优先。
class QueryShape {
  const QueryShape({required this.text, required this.literal});

  final String text;

  /// 是否只按原样查找，不再拆成关键词。
  final bool literal;

  /// 关键词检索使用的词；字面查询为空。
  List<String> get terms => literal ? const [] : searchTerms(text);

  bool get isEmpty => text.trim().isEmpty;
}

final RegExp _literalMarks = RegExp(r'''[()\[\]{}_^=<>%*+/\\|"'“”‘’「」『』]''');

final RegExp _referenceLook = RegExp(
  r'^(?:例|第|题)?\s*[\p{L}]*\d[\d\-–—.．、]*$',
  unicode: true,
);

final RegExp _quotePairs = RegExp(r'''^(["“”'‘’])(.*)(["“”'‘’])$''');

QueryShape shapeQuery(String raw) {
  var text = raw.trim();
  var literal = false;
  final quoted = _quotePairs.firstMatch(text);
  if (quoted != null) {
    text = quoted.group(2)!.trim();
    literal = true;
  }
  if (!literal) {
    literal = _literalMarks.hasMatch(text) || _referenceLook.hasMatch(text);
  }
  return QueryShape(text: text, literal: literal);
}
