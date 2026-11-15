/// 本地检索的统一规则：查询切词、二元组索引与摘要片段。
///
/// 关键词检索、FTS5 索引与片段截取原先分散在两个文件里，现在只从这里取：
/// [searchTerms] 去掉虚词得到查询词，[bigrams] 与 [bigramsExpression] 是同一套
/// 二元组规则在 Dart 与 SQL 两侧的写法，[searchSnippet] 是唯一的摘要入口。
library;

import 'text.dart';

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
  if (matchAt < 0) return truncateCodePoints(text, limit);
  final start = (matchAt - (limit ~/ 3)).clamp(0, text.length);
  final end = (start + limit).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}'
      '${end < text.length ? '…' : ''}';
}

bool _isWord(int rune) =>
    bigramRanges.any((range) => rune >= range.$1 && rune <= range.$2);

List<String> bigrams(String text) {
  final tokens = <String>[];
  final segment = <int>[];
  void flush() {
    for (var i = 0; i + 1 < segment.length; i++) {
      tokens.add(String.fromCharCodes(segment.getRange(i, i + 2)));
    }
    if (segment.isNotEmpty) tokens.add(String.fromCharCodes(segment));
    segment.clear();
  }

  for (final rune in text.split('\u0000').first.runes.take(maxInputLength)) {
    if (bigramSpaces.contains(rune)) {
      flush();
    } else if (_isWord(rune)) {
      // SQLite lower() lowercases ASCII. FTS5 handles Unicode case folding.
      segment.add(rune >= 0x41 && rune <= 0x5a ? rune + 0x20 : rune);
    }
  }
  flush();
  return tokens;
}

/// SQL 侧判断字母数字用的码位区间。
///
/// 覆盖 ASCII、拉丁扩展、希腊、西里尔、希伯来、阿拉伯、天城文等南亚文字、
/// 韩文谚文、平假名与片假名、中日韩汉字与扩展区，以及全角数字与字母。区间
/// 之外的字符在 SQL 里按标点处理，中文、英文、数字与常用符号两边一致。
const List<(int, int)> bigramRanges = [
  (0x0030, 0x0039),
  (0x0041, 0x005a),
  (0x005f, 0x005f),
  (0x0061, 0x007a),
  (0x00c0, 0x024f),
  (0x0250, 0x02af),
  (0x0370, 0x03ff),
  (0x0400, 0x052f),
  (0x0591, 0x05ff),
  (0x0600, 0x06ff),
  (0x0900, 0x1fff),
  (0x2e80, 0x2fff),
  (0x3040, 0x30ff),
  (0x3400, 0x4dbf),
  (0x4e00, 0x9fff),
  (0xa000, 0xa48f),
  (0xac00, 0xd7af),
  (0xf900, 0xfaff),
  (0xff10, 0xff19),
  (0xff21, 0xff3a),
  (0xff41, 0xff5a),
  (0xff66, 0xff9f),
  (0x20000, 0x2fa1f),
];

/// SQL 侧判断空白用的码位。
const List<int> bigramSpaces = [
  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, //
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, //
  0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
];

/// 把一段文本按 [bigrams] 的规则切成二元组并拼成一个字符串的 SQL 表达式。
///
/// 表达式里的 `?` 由调用方绑定待切的文本，结果是一段以空格分隔的词，可以
/// 直接写进 FTS5 的外部内容表。做法与 Dart 侧一致：先按空白切成片段，片段内
/// 去掉标点，再取相邻两字与整段本身。
///
/// 片段与位置都用窗口函数算，正文按字符逐个展开；一次最多处理 [maxInputLength]
/// 个字符，更长的正文只按前这么多字符建索引。
String bigramsExpression([String text = '?']) =>
    _expression.replaceAll('%TEXT%', text);

/// 一次切词最多读入的字符数。
const int maxInputLength = 20000;

final String _expression = _buildExpression();

String _buildExpression() {
  // 字符的码位表达式；字母数字与空白按区间判断，其余是标点。
  const code = 'unicode(substr(w.x, w.i, 1))';
  final isWord = [
    for (final (start, end) in bigramRanges) '$code BETWEEN $start AND $end',
  ].join(' OR ');
  final isSpace = '$code IN (${bigramSpaces.join(', ')})';
  // 窗口都显式写 ROWS 帧：默认的 RANGE 帧要按值逐个回扫，正文一长就变成平方级。
  const frame = 'ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW';
  // 片段号：空白处加一。标点不断段，它与 Dart 侧“片段内先去标点”的口径一致。
  final segment =
      'SUM(CASE WHEN $isSpace THEN 1 ELSE 0 END) '
      'OVER (ORDER BY w.i $frame)';
  return '(SELECT COALESCE(group_concat(v, \' \'), \'\') FROM ('
      'WITH RECURSIVE w(i, x) AS (SELECT 1, CAST(%TEXT% AS TEXT) '
      'UNION ALL SELECT i + 1, x FROM w '
      'WHERE i < min(length(x), $maxInputLength)), '
      // 第一层：字、是否空白、是否字母数字、片段号。
      'f(i, ch, br, k, seg) AS (SELECT w.i, lower(substr(w.x, w.i, 1)), '
      'CASE WHEN $isSpace THEN 1 ELSE 0 END, '
      'CASE WHEN $isWord THEN 1 ELSE 0 END, $segment FROM w), '
      // 第二层：只保留字母数字，标点因此不参与配对。
      'w2(i, ch, br, seg) AS (SELECT i, ch, br, seg FROM f WHERE k = 1), '
      // 第三层：片段内序号与片段长度。
      'g(i, ch, seg, pn, tot) AS (SELECT i, ch, seg, '
      'SUM(1) OVER (PARTITION BY seg ORDER BY i $frame), '
      'SUM(1) OVER (PARTITION BY seg) FROM w2), '
      // 每个片段去掉标点后的整段文本只算一次。
      'whole(seg, txt) AS (SELECT seg, group_concat(ch, \'\') FROM '
      '(SELECT seg, ch FROM g ORDER BY seg, pn) GROUP BY seg), '
      'tok(i, v) AS ('
      // 相邻两字：片段内第一个字没有前一个字，第二个字起各出一个。
      'SELECT i, v FROM (SELECT i, '
      'lag(ch) OVER (PARTITION BY seg ORDER BY pn) || ch AS v, '
      'pn FROM g) WHERE pn > 1 '
      'UNION ALL '
      // 整段本身：只在片段末字处补一次。
      'SELECT g.i, whole.txt FROM g JOIN whole ON whole.seg = g.seg '
      'WHERE g.pn = g.tot) '
      'SELECT v FROM tok ORDER BY i))';
}
