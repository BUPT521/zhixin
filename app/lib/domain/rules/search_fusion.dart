import '../models/evidence.dart';
import '../models/search.dart';

/// 结果按学习记录汇总时使用的键：有讨论标识时按记录，材料页按页。
///
/// 页面、服务层与融合函数共用这一个键，保证一条记录无论由哪一路找到都只占
/// 一行。
String searchEntryKey(EvidenceHit hit) {
  final conversationId = hit.location.conversationId;
  return conversationId == null ? hit.identity : 'conversation:$conversationId';
}

/// 把本地记录顺序与语义命中合成为一份排序后的记录列表。
///
/// 本地条目保留原有先后并记下名次；语义命中按返回顺序记名次，同一个键只出现
/// 一次。排序规则写在 [compareSearchEntries] 里：含原样命中的记录始终在前，
/// 其余按两路名次的倒数之和从高到低，分数相同按本地名次、再按记录标识。
List<SearchEntry> fuseSearch(
  List<SearchEntry> local,
  List<EvidenceHit> semantic,
) {
  final byKey = <String, SearchEntry>{};
  for (var index = 0; index < local.length; index++) {
    final entry = local[index];
    final ranked = entry.localRank == null
        ? entry.withLocalRank(index + 1)
        : entry;
    byKey[ranked.key] = ranked;
  }
  var rank = 0;
  for (final hit in semantic) {
    rank++;
    final key = searchEntryKey(hit);
    final existing = byKey[key];
    byKey[key] = existing == null
        ? SearchEntry(key: key, hits: [hit], semanticRank: rank)
        : existing.withSemanticRank(rank);
  }
  return byKey.values.toList()..sort(compareSearchEntries);
}

/// 融合后的排序：原样命中优先，其余按名次融合分数，最后保证顺序稳定。
int compareSearchEntries(SearchEntry left, SearchEntry right) {
  if (left.hasLiteral != right.hasLiteral) return left.hasLiteral ? -1 : 1;
  // 原样命中之间保持本地原有先后，题号、公式与原句不因名次分数换位。
  if (left.hasLiteral) return _compareLocal(left, right);
  final byScore = right.fusionScore.compareTo(left.fusionScore);
  if (byScore != 0) return byScore;
  return _compareLocal(left, right);
}

/// 本地名次优先；没有本地名次（只由语义找到）的排在后面，再按记录标识。
int _compareLocal(SearchEntry left, SearchEntry right) {
  final leftRank = left.localRank ?? 1 << 30;
  final rightRank = right.localRank ?? 1 << 30;
  final byRank = leftRank.compareTo(rightRank);
  if (byRank != 0) return byRank;
  return left.key.compareTo(right.key);
}
