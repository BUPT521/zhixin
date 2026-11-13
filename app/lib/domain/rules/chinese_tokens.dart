/// 中文切词与关键词排序共用的分块规则。
///
/// 没有分词词典时按字符二元组切分，查询与原文使用同一套规则：连续字母数字
/// 组成的片段先去标点，再取相邻两字与整段本身。这样“熵等于能量吗”与
/// “熵衡量系统的混乱程度，不等于能量”能共享“等于”“能量”等片段，题号与
/// 公式里的字符也不会因为标点被丢掉。
library;

final RegExp _stripMarks = RegExp(r'[^\p{L}\p{N}_]+', unicode: true);

List<String> bm25Tokens(String text) {
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

/// 交给 BM25 的文本：片段之间用空格分开，包里的切词与查询切词因此一致。
String bm25IndexText(String text) => bm25Tokens(text).join(' ');
