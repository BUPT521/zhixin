import '../domain/models/buddy_protocol.dart';

/// 一种回答模式开放哪些能力；提示词构建与工具声明都从这一份派生。
///
/// 能力矩阵原先在 `buddy_prompt_builder.dart` 与 `buddy_tools.dart` 各写一遍
/// “哪个模式开哪些能力”，加一种模式或调一处开关时要同时改两处，漏一处就会
/// 出现“提示词要求提交建议、工具却没有声明”这类不对称。这里按模式给出一份
/// 判断，两处只读它。
///
/// 记忆、材料补读与来源补搜另受本轮内容影响（有没有检索到摘录、有没有材料
/// 页），由各自的 `can*` 判断决定，不放进这张表。
class BuddyCapabilities {
  const BuddyCapabilities._({
    required this.memories,
    required this.nextSteps,
    required this.citations,
    required this.studySteps,
    required this.assessment,
    required this.planContext,
  });

  /// [mode] 对应的能力：普通问答带记忆、建议与引用，检查带判断，系统学习
  /// 只出步骤与积压事项；提示与讲解只回答正文与记忆。
  factory BuddyCapabilities.of(BuddyMode mode) => switch (mode) {
    BuddyMode.chat => const BuddyCapabilities._(
      memories: true,
      nextSteps: true,
      citations: true,
      studySteps: false,
      assessment: false,
      planContext: false,
    ),
    BuddyMode.hint || BuddyMode.explain => const BuddyCapabilities._(
      memories: true,
      nextSteps: false,
      citations: false,
      studySteps: false,
      assessment: false,
      planContext: false,
    ),
    BuddyMode.check => const BuddyCapabilities._(
      memories: true,
      nextSteps: false,
      citations: false,
      studySteps: false,
      assessment: true,
      planContext: false,
    ),
    BuddyMode.plan => const BuddyCapabilities._(
      memories: false,
      nextSteps: false,
      citations: false,
      studySteps: true,
      assessment: false,
      planContext: true,
    ),
  };

  /// 可以提交记忆提案：系统学习只排步骤，不写记忆。
  final bool memories;

  /// 可以提交下一步建议；只有普通问答有这一项。
  final bool nextSteps;

  /// 可以提交材料引用；只有普通问答核对引用。
  final bool citations;

  /// 必须提交学习步骤；系统学习用强制工具收尾。
  final bool studySteps;

  /// 可以提交学习判断；只有检查作答有这一项。
  final bool assessment;

  /// 提示词里带积压事项与安排说明；只有系统学习用得到。
  final bool planContext;
}
