import '../data/repository/attempt_repository.dart';
import '../data/repository/conversation_repository.dart';
import '../domain/models/memory.dart';

/// 一条讨论或一次作答的记忆适用范围。
///
/// 只认记录上明确写下的目标与材料，两者都没有时不沿用历史场次：清空归属后
/// 新的作答与求助属于独立内容，不能再借到旧场次的目标。
class MemoryScopeService {
  MemoryScopeService({required this.conversations, required this.attempts});

  final ConversationRepository conversations;
  final AttemptRepository attempts;

  /// 本次回答的归属与记忆范围；两者一起返回，避免调用方再读一次记录。
  ///
  /// [record] 是调用方已经读到的记录：讨论发送与作答求助在进入这里之前都要
  /// 先读记录，传进来就不再按编号读一次；传空时按 [conversationId] 读取。
  Future<({int? goalId, String? scope})> resolve(
    int conversationId, {
    ConversationRecord? record,
  }) async {
    final current = record ?? await conversations.byId(conversationId);
    final goalId = current?.goalId;
    if (goalId != null) {
      return (goalId: goalId, scope: memoryGoalScope(goalId));
    }
    final materialId = current?.materialId;
    if (materialId != null) {
      return (goalId: null, scope: memoryMaterialScope(materialId));
    }
    return (goalId: null, scope: null);
  }
}
