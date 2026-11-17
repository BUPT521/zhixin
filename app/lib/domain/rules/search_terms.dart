/// 本地检索的统一规则：查询切词、二元组与摘要片段。
///
/// [searchTerms] 去掉虚词得到查询词，[bigrams] 是标题、摘要与记忆正文排序共用
/// 的一套二元组规则，[searchSnippet] 是唯一的摘要入口。关键词索引由 zvec 的
/// 全文子查询承担（ADR-0024），这里不再提供 SQL 侧的切词表达式。
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
      // 字母统一转成小写，查询与正文因此按同一套词比对。
      segment.add(rune >= 0x41 && rune <= 0x5a ? rune + 0x20 : rune);
    }
  }
  flush();
  return tokens;
}

/// 判断字母数字用的码位区间。
///
/// 覆盖 ASCII、拉丁扩展、希腊、西里尔、希伯来、阿拉伯、天城文等南亚文字、
/// 韩文谚文、平假名与片假名、中日韩汉字与扩展区，以及全角数字与字母。区间
/// 之外的字符按标点处理，中文、英文、数字与常用符号的切分因此一致。
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

/// 判断空白用的码位。
const List<int> bigramSpaces = [
  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, //
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, //
  0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
];

/// 一次切词最多读入的字符数。
const int maxInputLength = 20000;
