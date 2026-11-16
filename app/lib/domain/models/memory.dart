import '../rules/coded_enum.dart';
import '../rules/time_format.dart';

/// 记忆类型（01 `memory.kind`）。
enum MemoryKind implements CodedEnum {
  preference('preference', '偏好'),
  constraint('constraint', '限制'),
  difficulty('difficulty', '困难'),
  progress('progress', '进展'),
  unknown('', '类别未知');

  const MemoryKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  /// 困难与进展跟目标或材料走；偏好与限制跟人走，不写范围。
  bool get followsContext => this == difficulty || this == progress;

  static MemoryKind fromValue(String? value) =>
      codedValueOr(MemoryKind.values, value, unknown: unknown);
}

/// 记忆按哪条记录或哪次学习写入（01 `memory.source_kind`）。
enum MemorySourceKind implements CodedEnum {
  user('user', '你说的'),
  message('message', '推断'),
  attempt('attempt', '来自一次作答'),
  session('session', '来自一次学习'),
  unknown('', '来自本机');

  const MemorySourceKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static MemorySourceKind fromValue(String? value) =>
      codedValueOr(MemorySourceKind.values, value, unknown: unknown);
}

/// 记忆当前状态（01 `memory.status`）；删除与取代都不物理删除。
enum MemoryStatus implements CodedEnum {
  active('active', '有效'),
  superseded('superseded', '已被取代'),
  deleted('deleted', '已删除'),
  unknown('', '状态未知');

  const MemoryStatus(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static MemoryStatus fromValue(String? value) =>
      codedValueOr(MemoryStatus.values, value, unknown: unknown);
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
String memoryGoalScope(String goalId) => 'goal:$goalId';

String memoryMaterialScope(String materialId) => 'material:$materialId';

/// 一次回答或一条记忆的适用范围：目标优先，其次材料，都没有时是全局。
///
/// 讨论、作答、上下文组装与建议草案原先各写一遍同样的判定，放宽或收紧只在
/// 这里改；全局范围用空值表示。
String? memoryScopeFor({String? goalId, String? materialId}) {
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
    this.sourceKind = MemorySourceKind.user,
    this.sourceId,
    this.validUntil,
    this.status = MemoryStatus.active,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final MemoryKind kind;
  final String content;
  final String? scope;

  /// 这条记忆从哪来；界面按 [MemorySourceKind.label] 显示。
  final MemorySourceKind sourceKind;
  final String? sourceId;
  final DateTime? validUntil;

  /// 当前状态；[active] 只表示还在用，删掉的仍留在库里。
  final MemoryStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get active => status == MemoryStatus.active;

  bool isValidAt(DateTime now) {
    if (!active) return false;
    final until = validUntil;
    return until == null || !until.isBefore(now);
  }

  bool get fromModel => sourceKind == MemorySourceKind.message;

  String get sourceLabel => sourceKind.label;

  String get validLabel {
    final until = validUntil;
    if (until == null) return '长期有效';
    return '有效至 ${formatDate(until)}';
  }
}
