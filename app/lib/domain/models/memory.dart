import '../rules/coded_enum.dart';
import '../rules/time_format.dart';

/// 记忆类型（01 `memory.kind`）：情景、语义、程序三类（ADR-0051 决定第 1 条）。
///
/// 情景是发生过的一件事，带时间与对象；语义是关于用户的稳定事实与限制；
/// 程序是该怎么做的做法，它在提示词里的优先级低于系统规则、人格与用户本轮
/// 说明。常驻由字段推出：语义或程序、范围是全局、没有有效期，每轮必带。
enum MemoryKind implements CodedEnum {
  episodic('episodic', '情景'),
  semantic('semantic', '语义'),
  procedural('procedural', '程序'),
  unknown('', '类别未知');

  const MemoryKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  /// 可以常驻的两类；情景只靠检索与主动搜索进入回答。
  bool get canBeResident => this == semantic || this == procedural;

  /// 范围跟本次讨论走的类别：情景是发生过的一件事，只在发生它的目标或材料里
  /// 有意义；语义与程序是对全部学习都成立的事实与做法。
  bool get followsContext => this == episodic;

  static MemoryKind fromValue(String? value) =>
      codedValueOr(MemoryKind.values, value, unknown: unknown);
}

/// 按内容把用户手写的偏好与限制归到语义（ADR-0051 决定第 1 条：限制归语义，
/// 偏好按内容归语义或程序）。
///
/// 用户手写不推断程序类，程序只由模型明确给出；含约束词的那条与其余一样落在
/// 语义。判断保留在这里，读代码时能看出这条规则覆盖了限制。
MemoryKind memoryKindForContent(String content) =>
    _hasConstraintMarker(content) ? MemoryKind.semantic : MemoryKind.semantic;

/// 约束词：写成限制的偏好，按 ADR-0051 归语义。
const List<String> memoryConstraintMarkers = ['要', '不要', '只能', '不能', '每次', '先'];

bool _hasConstraintMarker(String content) =>
    memoryConstraintMarkers.any(content.trim().contains);

/// 旧四类标签与三类之间的对应，只在读旧数据时用。
///
/// 困难与进展是发生过的事，归情景；限制是稳定事实，偏好按内容归语义。
MemoryKind memoryKindFromLegacy(String? value) => switch (value) {
  'difficulty' || 'progress' => MemoryKind.episodic,
  'constraint' || 'preference' => MemoryKind.semantic,
  _ => MemoryKind.unknown,
};

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

/// 记忆当前状态（01 `memory.status`）：修改是原地改写，删除只改状态、不物理删行。
enum MemoryStatus implements CodedEnum {
  active('active', '有效'),
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

/// 记忆召回的用途：规划、讲解与检查。三类标签落地之后用途不再挑选类别，
/// 这一项只留给调用方说明本次是哪种回答（ADR-0051 决定第 5 条）。
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
/// 带来源、有效期与状态；修改是原地改写，旧内容由提交日志保存，删除标为
/// `deleted` 且不物理删行，导出时按状态保留。
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
    this.searchTerms = '',
    this.reviewedAt,
  });

  final String id;
  final MemoryKind kind;
  final String content;
  final String? scope;

  /// 这条记忆从哪来；界面按 [MemorySourceKind.label] 显示。
  final MemorySourceKind sourceKind;
  final String? sourceId;
  final DateTime? validUntil;

  /// 写入时顺带给出的检索线索，几条短语用换行分隔，空串表示没有；只进全文
  /// 索引，不在界面显示（ADR-0051 决定第 7 条）。
  final String searchTerms;

  /// 用户确认保留的时间；写这一列不连带更新 [updatedAt]（ADR-0051 决定第 9 条）。
  final DateTime? reviewedAt;

  /// 当前状态；[active] 只表示还在用，删掉的仍留在库里。
  final MemoryStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get active => status == MemoryStatus.active;

  /// 同时满足三条时每轮必带：语义或程序、范围是全局、没有有效期。
  bool get resident =>
      kind.canBeResident && scope == null && validUntil == null;

  bool isValidAt(DateTime now) {
    if (!active) return false;
    final until = validUntil;
    return until == null || !until.isBefore(now);
  }

  bool get fromModel => sourceKind == MemorySourceKind.message;

  String get sourceLabel => sourceKind.label;

  /// 来源对象的指称：讨论消息、作答记录或学习场次的编号。
  ///
  /// 用户自述没有来源对象；旧数据缺少编号时也只写来源类型。
  String get sourceObjectLabel {
    final id = sourceId;
    if (id == null || id.isEmpty) return '';
    final object = switch (sourceKind) {
      MemorySourceKind.message => '讨论消息',
      MemorySourceKind.attempt => '作答记录',
      MemorySourceKind.session => '学习场次',
      MemorySourceKind.user => '你的说明',
      MemorySourceKind.unknown => '本机记录',
    };
    return '$object $id';
  }

  /// 来源一栏的完整说明：来源类型与来源对象。
  String get sourceDetail {
    final object = sourceObjectLabel;
    return object.isEmpty ? sourceLabel : '$sourceLabel · $object';
  }

  String get validLabel {
    final until = validUntil;
    if (until == null) return '长期有效';
    return '有效至 ${formatDate(until)}';
  }
}
