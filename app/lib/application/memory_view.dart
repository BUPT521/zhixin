import '../ai/buddy_prompt.dart';
import 'buddy_actions.dart';

/// 一条记忆卡片：待确认的推断记忆，或已经写入、可以撤销的记忆。
///
/// 讨论与作答共用这一份；[ownerId] 在讨论里是回答消息的编号，在作答里是
/// 帮助在尝试上的序号，两者都只用来指回存储位置。
class MemoryItemView {
  const MemoryItemView({
    required this.ownerId,
    required this.itemId,
    required this.draft,
    required this.status,
    this.commitId,
  });

  final int ownerId;
  final String itemId;
  final MemoryDraft draft;
  final String status;
  final int? commitId;

  bool get pending => status == 'pending';
  bool get applied => status == 'accepted';
}

/// 用户点“记下”后的结果；重复或过长时没有写入。
class AcceptedMemory {
  const AcceptedMemory({required this.applied, this.change, this.notice});

  final bool applied;
  final AppliedChange? change;
  final String? notice;
}
