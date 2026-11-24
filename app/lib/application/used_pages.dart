import '../domain/models/buddy_protocol.dart';
import '../domain/models/chat_message_payload.dart';
import '../domain/models/evidence.dart';
import 'context_service.dart' show maxContextMaterialHits;

/// 这次回答可以接着用的材料页：本轮检索列出或工具读取提供的页，去掉记录本身
/// 带入的当前页，最多 [maxContextMaterialHits] 页。
///
/// 这次回答中断、截断或停止之后，重试同一条问题或同一次求助时按这些位置重新
/// 读取当前保存的原文（`docs/02` 第 3.8 节）。只记位置不记原文，所以材料被
/// 更正、删除或换到别的目标之后，读取时自然跳过或取到当前版本。
List<ChatUsedPage> usedPagesOf(
  BuddyContext facts,
  Iterable<CitationSource> provided, {
  (String, int)? currentPage,
}) {
  final keys = <(String, int)>{};
  for (final hit in facts.additionalMaterialHits) {
    if (keys.length >= maxContextMaterialHits) break;
    if (hit.pageKey == currentPage) continue;
    keys.add(hit.pageKey);
  }
  for (final source in provided) {
    if (keys.length >= maxContextMaterialHits) break;
    if (source.pageKey == currentPage) continue;
    keys.add(source.pageKey);
  }
  return [
    for (final key in keys) ChatUsedPage(materialId: key.$1, pageNo: key.$2),
  ];
}

/// 一组接续页的位置，交给 `ContextRequest.reusedPageKeys`。
///
/// 没有材料标识或页码不大于零的条目在这一步丢掉，读取时不用再判断。
List<(String, int)> reusedPageKeysOf(Iterable<ChatUsedPage> pages) => [
  for (final page in pages)
    if (page.materialId.isNotEmpty && page.pageNo > 0) page.pageKey,
];
