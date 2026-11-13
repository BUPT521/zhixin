/// 一次学习判断（01 `assessment`）：模型判断与用户提供的核对依据分开保存。
/// 用户自评由作答记录推出，不再单独保存；两者都只表示来源与依据，不标记是否核对。
library;

/// 判断来源。
enum AssessmentKind {
  model('model', '模型判断'),
  user('user', '用户提供的核对依据');

  const AssessmentKind(this.value, this.label);

  final String value;
  final String label;

  static AssessmentKind fromValue(String value) {
    return switch (value) {
      'model' => AssessmentKind.model,
      'user' => AssessmentKind.user,
      _ => throw FormatException('未知的判断来源：$value'),
    };
  }
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

  factory Assessment.fromRow(Map<String, Object?> row) {
    return Assessment(
      id: row['id']! as int,
      attemptId: row['attempt_id']! as int,
      kind: AssessmentKind.fromValue(row['kind']! as String),
      result: row['result']! as String,
      basis: row['basis'] as String?,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
    );
  }

  final int id;
  final int attemptId;
  final AssessmentKind kind;
  final String result;
  final String? basis;
  final DateTime? createdAt;
}
