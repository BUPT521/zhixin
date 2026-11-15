/// 文本入库与展示的两条统一规则：可选文本归一、按码位截断。
library;

/// 可选文本入库前的归一：去掉首尾空白，空串写成 `null`。
///
/// 仓库原先各写一份 `_clean`，同样的列在不同写入路径上可能存成空串或 null；
/// 统一从这里取，读取侧只需要处理一种表示。
String? nullableText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// 按 Unicode 码位截断；超出时补 [ellipsis]。
///
/// 字符串下标按 UTF-16 码元计数，直接 `substring` 会把表情或代理对切成两半；
/// 摘要与提示词统一按码位截断。
String truncateCodePoints(String text, int max, {String ellipsis = '…'}) {
  final runes = text.runes;
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max))}$ellipsis';
}
