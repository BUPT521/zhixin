/// 一次学习判断（01 `assessment`）：模型判断与用户提供的核对依据分开保存。
/// 用户自评由作答记录推出，不再单独保存；两者都只表示来源与依据，不标记是否核对。
library;

import '../rules/coded_enum.dart';

/// 判断来源。
enum AssessmentKind implements CodedEnum {
  model('model', '模型判断'),
  user('user', '用户提供的核对依据'),
  unknown('', '来源未知');

  const AssessmentKind(this.value, this.label);

  @override
  final String value;

  @override
  final String label;

  static AssessmentKind fromValue(String? value) =>
      codedValueOr(AssessmentKind.values, value, unknown: unknown);
}

/// 一条学习判断；只保存来源、结论与依据，不标记是否已经核对。
class Assessment {
  const Assessment({
    required this.id,
    required this.attemptId,
    required this.kind,
    required this.result,
    this.basis,
    this.createdAt,
  });

  final String id;
  final String attemptId;
  final AssessmentKind kind;
  final String result;
  final String? basis;
  final DateTime? createdAt;
}
