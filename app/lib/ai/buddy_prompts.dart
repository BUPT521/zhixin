import '../domain/models/buddy_protocol.dart';
import '../domain/models/study_plan.dart';
import '../domain/models/material.dart';

/// 作答页按模式给出的提问；讨论入口不经过这里。
///
/// 提问文案属于提示词，原先写在 `LearningService` 里与模型调用混在一起，
/// 现在与系统提示、工具说明放在同一个目录。
String modePrompt(BuddyMode mode) => switch (mode) {
  BuddyMode.hint => '给我一个提示，不直接给答案。',
  BuddyMode.explain => '完整讲这道题，讲清依据。',
  BuddyMode.check => '检查我的做法，指出第一个需要改的地方。',
  BuddyMode.chat => '看看这道题，告诉我现在最该做的一步。',
  BuddyMode.plan => '按材料范围提出学习顺序。',
};

/// 系统学习一批材料时的步骤要求；[earlier] 是前面批次已经给出的步骤摘要。
String studyStepsPrompt({
  required String range,
  required String unit,
  String earlier = '',
}) {
  final prompt = StringBuffer()
    ..write('按本次提供的材料提出学习步骤，覆盖$range，')
    ..write('每一步写清$unit范围与结束条件；材料里没有展开但完成目标必需的内容，')
    ..write('标为前置内容。不得引用本次范围之外的$unit。');
  if (earlier.isNotEmpty) {
    prompt
      ..write('\n前面批次已经给出的步骤：\n$earlier\n')
      ..write('不要重复这些步骤；本批次的内容如果依赖前面的步骤，在说明里写明依赖第几步。');
  }
  return prompt.toString();
}

/// 前面批次已经给出的步骤摘要；只列最近若干步，控制提示长度。
String previousStepsSummary(
  List<StudyStepDraft> steps, {
  required bool isDocx,
}) {
  if (steps.isEmpty) return '';
  final start = steps.length > 12 ? steps.length - 12 : 0;
  final lines = <String>[if (start > 0) '前面共 ${steps.length} 步，以下只列最近 12 步。'];
  for (var index = start; index < steps.length; index++) {
    final step = steps[index];
    final range = materialPosition(
      step.pageFrom,
      to: step.pageTo,
      isDocx: isDocx,
    );
    lines.add('${index + 1}. ${step.title}${range.isEmpty ? '' : '（$range）'}');
  }
  return lines.join('\n');
}
