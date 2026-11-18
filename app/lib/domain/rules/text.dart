/// 文本入库与展示的两条统一规则：可选文本归一、按码位截断。
library;

/// 人格设定文本的上限，按 Unicode 码位计数；口径见 `docs/02` 第 6 节与
/// `docs/adr/0010`。超过时拒绝保存，提示词构建处只在读取到异常数据时兜底截断。
const int personaTextLimit = 800;

/// 可选文本入库前的归一：去掉首尾空白，空串写成 `null`。
///
/// 仓库原先各写一份 `_clean`，同样的列在不同写入路径上可能存成空串或 null；
/// 统一从这里取，读取侧只需要处理一种表示。
String? nullableText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

/// 联系邮箱的轻量格式核对：排除没有 `@`、含空白或域名没有点的输入。
///
/// 最终以服务端的校验为准（server/README.md 的“应用内反馈”）；这里只拦下明显
/// 写错的地址，不重复实现完整的邮箱语法。
bool looksLikeEmailAddress(String value) {
  final text = value.trim();
  if (text.isEmpty || text.length > 254 || text.contains(RegExp(r'\s'))) {
    return false;
  }
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text);
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
