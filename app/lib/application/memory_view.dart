import '../ai/buddy_prompt.dart';
import 'buddy_actions.dart';

/// 一条记忆卡片：待确认的推断记忆，或已经写入、可以撤销的记忆。
///
/// 讨论与作答共用这一份，卡片指回的存储位置不同：讨论里是回答消息的编号，
/// 作答里是帮助在尝试上的序号。两者分开存放，界面按卡片来自哪一屏读取对应
/// 的一栏；[draft] 同时带卡片编号、处理状态与提交编号，卡片状态只在草案里
/// 存一份。
class MemoryItemView {
  const MemoryItemView.message({
    required String this.messageId,
    required this.draft,
  }) : helpIndex = null;

  const MemoryItemView.help({required int this.helpIndex, required this.draft})
    : messageId = null;

  /// 讨论里的回答消息编号；作答里的卡片为空。
  final String? messageId;

  /// 作答里的帮助序号；讨论里的卡片为空。
  final int? helpIndex;

  final MemoryDraft draft;

  String get itemId => draft.id;
  int? get commitId => draft.commitId;

  bool get pending => draft.status == MemoryCardStatus.pending;
  bool get applied => draft.status == MemoryCardStatus.accepted;
}

/// 用户点“记下”后的结果；重复或过长时没有写入。
class AcceptedMemory {
  const AcceptedMemory({required this.applied, this.change, this.notice});

  final bool applied;
  final AppliedChange? change;
  final String? notice;
}
