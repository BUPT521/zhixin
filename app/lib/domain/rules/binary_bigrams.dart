/// 中文切词与关键词检索共用的二元组分块规则。
///
/// 没有分词词典时按字符二元组切分，索引、查询与排序使用同一套规则：连续字母
/// 数字组成的片段先去标点，再取相邻两字与整段本身。这样“熵等于能量吗”与
/// “熵衡量系统的混乱程度，不等于能量”能共享“等于”“能量”等片段，题号与
/// 公式里的字符也不会因为标点被丢掉。
///
/// [bigrams] 是 Dart 侧用于查询的切分，[bigramsExpression] 是同一套规则在 SQL
/// 里的写法，材料页、消息与作答的 FTS5 索引由触发器用它计算。两边用同一张
/// 码位区间表判断字母数字与空白，测试用同一段文本比对两边结果。
library;

final RegExp _stripMarks = RegExp(r'[^\p{L}\p{N}_]+', unicode: true);

List<String> bigrams(String text) {
  final tokens = <String>[];
  for (final segment in text.toLowerCase().split(RegExp(r'\s+'))) {
    final clean = segment.replaceAll(_stripMarks, '');
    if (clean.isEmpty) continue;
    final chars = clean.runes.toList(growable: false);
    if (chars.length >= 2) {
      for (var index = 0; index + 1 < chars.length; index++) {
        tokens.add(
          '${String.fromCharCode(chars[index])}'
          '${String.fromCharCode(chars[index + 1])}',
        );
      }
      tokens.add(clean);
    }
  }
  return tokens;
}

/// 交给 FTS5 索引列的文本：片段之间用空格分开，分词器因此把每个片段当成一个词。
String bigramIndexText(String text) => bigrams(text).join(' ');

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
    '$code BETWEEN 48 AND 57',
    '$code BETWEEN 65 AND 90',
    '$code = 95',
    '$code BETWEEN 97 AND 122',
    for (final (start, end) in bigramRanges)
      if (start > 0x7f) '$code BETWEEN $start AND $end',
  ].join(' OR ');
  final isSpace =
      '$code < 33 OR $code BETWEEN 133 AND 160 OR $code = 1680 OR '
      '$code BETWEEN 8192 AND 8202 OR '
      '$code IN (8232, 8233, 8239, 8287, 12288)';
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
      'WHERE g.tot >= 2 AND g.pn = g.tot) '
      'SELECT v FROM tok ORDER BY i))';
}
