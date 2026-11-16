import 'prompt_text.dart';

import '../domain/models/buddy_protocol.dart';
import '../domain/models/study_plan.dart';
import '../domain/models/material.dart';

/// 作答页按模式给出的提问；讨论入口不经过这里。
///
/// 提问文案属于提示词，文本在 `assets/prompts/buddy_prompts.md`。
String modePrompt(BuddyMode mode) =>
    PromptText.instance['request.${mode.value}'];

/// 系统学习一批材料时的步骤要求；[earlier] 是前面批次已经给出的步骤摘要。
String studyStepsPrompt({
  required String range,
  required String unit,
  String earlier = '',
}) {
  final text = PromptText.instance;
  final prompt = StringBuffer()
    ..write(text.format('request.study_steps', {'range': range, 'unit': unit}));
  if (earlier.isNotEmpty) {
    prompt
      ..write('\n')
      ..write(text.format('request.study_earlier', {'earlier': earlier}));
  }
  return prompt.toString();
}

/// 前面批次已经给出的步骤摘要；只列最近若干步，控制提示长度。
String previousStepsSummary(
  List<StudyStepDraft> steps, {
  required bool isDocx,
}) {
  if (steps.isEmpty) return '';
  final text = PromptText.instance;
  final start = steps.length > 12 ? steps.length - 12 : 0;
  final lines = <String>[
    if (start > 0)
      text.format('request.previous_prefix', {'count': '${steps.length}'}),
  ];
  for (var index = start; index < steps.length; index++) {
    final step = steps[index];
    final range = materialPosition(
      step.pageFrom,
      to: step.pageTo,
      isDocx: isDocx,
    );
    lines.add(
      text.format('request.previous_line', {
        'index': '${index + 1}',
        'title': step.title,
        'range': range.isEmpty
            ? ''
            : text.format('request.previous_range', {'range': range}),
      }),
    );
  }
  return lines.join('\n');
}
