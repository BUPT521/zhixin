import '../rules/time_format.dart';

/// 记忆类型（01 `memory.kind`）。
enum MemoryKind {
  preference('preference', '偏好'),
  constraint('constraint', '限制'),
  difficulty('difficulty', '困难'),
  progress('progress', '进展');

  const MemoryKind(this.value, this.label);

  final String value;
  final String label;

  /// 困难与进展跟目标或材料走；偏好与限制跟人走，不写范围。
  bool get followsContext => this == difficulty || this == progress;

  static MemoryKind fromValue(String value) {
    return MemoryKind.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => MemoryKind.progress,
    );
  }
}

/// 记忆召回的用途：规划、讲解与检查各取不同类别的条目。
enum MemoryRecallPurpose {
  plan('plan'),
  explain('explain'),
  check('check'),
  chat('chat');

  const MemoryRecallPurpose(this.value);

  final String value;
}

/// 记忆适用范围：有归属时写 `goal:<id>`，只带入材料时写 `material:<id>`。
String memoryGoalScope(int goalId) => 'goal:$goalId';

String memoryMaterialScope(int materialId) => 'material:$materialId';

/// 一次回答或一条记忆的适用范围：目标优先，其次材料，都没有时是全局。
///
/// 讨论、作答、上下文组装与建议草案原先各写一遍同样的判定，放宽或收紧只在
/// 这里改；全局范围用空值表示。
String? memoryScopeFor({int? goalId, int? materialId}) {
  if (goalId != null) return memoryGoalScope(goalId);
  if (materialId != null) return memoryMaterialScope(materialId);
  return null;
}

/// 搭子记得的一条内容（01 `memory`）。
///
/// 带来源、有效期与状态；纠正是新增或改写后把旧的标为 `superseded`，
/// 删除标为 `deleted`，都不物理删除，导出时按状态保留。
class Memory {
  const Memory({
    required this.id,
    required this.kind,
    required this.content,
    this.scope,
    this.sourceKind = 'user',
    this.sourceId,
    this.validUntil,
    this.status = 'active',
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final MemoryKind kind;
  final String content;
  final String? scope;

  /// `user` / `message` / `attempt` / `session`。
  final String sourceKind;
  final int? sourceId;
  final DateTime? validUntil;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get active => status == 'active';

  bool isValidAt(DateTime now) {
    if (!active) return false;
    final until = validUntil;
    return until == null || !until.isBefore(now);
  }

  bool get fromModel => sourceKind == 'message';

  String get sourceLabel => switch (sourceKind) {
    'user' => '你说的',
    'message' => '推断',
    'attempt' => '来自一次作答',
    'session' => '来自一次学习',
    _ => '来自本机',
  };

  String get validLabel {
    final until = validUntil;
    if (until == null) return '长期有效';
    return '有效至 ${formatDate(until)}';
  }
}
