import '../domain/models/buddy_protocol.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/time_format.dart';
import 'material_page_tool.dart';
import 'prompt_text.dart';
import 'search_sources_tool.dart';

import '../domain/rules/text.dart';

/// 系统提示：只依据给定上下文回答；正文用 Markdown，需要附带数据时调用工具。
///
/// 工具与上下文按本次请求类型裁剪：普通问答只要回答、记忆、引用与下一步建议，
/// 提示与讲解不要建议，检查只要判断，系统学习只要步骤，避免每次问答都携带
/// 用不上的工具说明与整份安排。规则与上下文说明的文案在
/// `assets/prompts/buddy_system.md`，这里只按条件选取并替换占位符。
String buildBuddySystemPrompt(BuddyContext context) {
  final text = PromptText.instance;
  final mode = context.mode;
  final withMemories = mode != BuddyMode.plan;
  final withNextSteps = mode == BuddyMode.chat;
  final withCitations = mode == BuddyMode.chat;
  final withStudySteps = mode == BuddyMode.plan;
  final withAssessment = mode == BuddyMode.check;
  final withPlanContext = mode == BuddyMode.plan;
  final currentGoal = context.goal;
  final goals = uniqueById(
    context.goals,
    (goal) => goal.id,
  ).where((goal) => goal.id != currentGoal?.id);
  final materialHits = context.additionalMaterialHits;
  final attemptIds = <String>{};
  final persona = context.persona;
  final unit = context.material?.isDocx == true
      ? text['system.unit.docx']
      : text['system.unit.page'];

  final rules = <String>[
    text['system.rule.grounded'],
    text['system.rule.answer_first'],
    text['system.rule.no_grading'],
    text['system.rule.length'],
    text['system.rule.markdown'],
    if (!withStudySteps) text['system.rule.tools'],
    if (withMemories) text['system.rule.memories'],
    if (withMemories && context.memories.isNotEmpty)
      text['system.rule.memory_use'],
    if (canReadMaterial(context))
      text.format('system.rule.read_material', {'tool': readMaterialPageTool}),
    if (canSearchSources(context))
      text.format('system.rule.search_sources', {'tool': searchSourcesTool}),
    if (withMemories) text['system.rule.memory_scope'],
    if (context.memories.isNotEmpty) text['system.rule.memory_conflict'],
    if (withNextSteps) text['system.rule.next_steps'],
    text['system.rule.no_goal'],
    if (withCitations) text['system.rule.citations'],
    if (withStudySteps) text.format('system.rule.study_steps', {'unit': unit}),
    if (withAssessment) text['system.rule.assessment'],
    if (persona != null) text['system.rule.persona'],
  ];

  final lines = <String>[
    text['system.intro'],
    text['system.rules_header'],
    for (var index = 0; index < rules.length; index++)
      '${index + 1}. ${rules[index]}',
    if (persona != null) ...[
      '',
      text.format('system.persona_header', {'name': persona.name}),
      truncateCodePoints(persona.text, personaTextLimit),
    ],
    '',
    text.format('system.time', {'time': formatDateTime(context.now)}),
    text.format('system.goal', {
      'title': currentGoal?.title ?? text['system.goal_none'],
      'due': currentGoal?.dueDate == null
          ? ''
          : text.format('system.goal_due', {'date': currentGoal!.dueDate!}),
    }),
  ];

  if (goals.isEmpty) {
    lines.add(text['system.goals_none']);
  } else {
    lines.add(text['system.goals_header']);
    for (final goal in goals) {
      lines.add(
        text.format('system.goal_line', {
          'title': goal.title,
          'due': goal.dueDate == null
              ? ''
              : text.format('system.goal_due', {'date': goal.dueDate!}),
        }),
      );
    }
  }

  final material = context.material;
  final page = context.materialPage;
  if (material != null && page != null) {
    lines
      ..add(
        text.format('system.material', {
          'id': material.id,
          'title': material.title,
          'position': material.position(page.pageNo),
          'label': page.label == null
              ? ''
              : text.format('system.label', {'label': page.label!}),
        }),
      )
      ..add(text['system.material_content'])
      ..add(page.content);
  } else {
    lines.add(text['system.material_none']);
  }

  if (context.outlinePages.isNotEmpty) {
    lines.add(text.format('system.outline', {'unit': unit}));
    for (final outline in context.uniqueOutlinePages) {
      lines.add(
        text.format('system.outline_line', {
          'position':
              material?.position(outline.pageNo) ??
              text.format('system.page_no', {'page': '${outline.pageNo}'}),
          'label': outline.label == null
              ? ''
              : text.format('system.label', {'label': outline.label!}),
          'content': material != null && outline.pageKey == page?.pageKey
              ? text['system.outline_here']
              : outline.content.replaceAll(RegExp(r'\s+'), ' ').trim(),
        }),
      );
    }
  }

  if (context.conversationFocus?.trim().isNotEmpty == true) {
    lines
      ..add(text['system.conversation_focus'])
      ..add(context.conversationFocus!);
  }

  if (materialHits.isNotEmpty) {
    lines.add(text['system.material_hits']);
    for (final hit in materialHits) {
      lines.add(
        text.format('system.material_hit_line', {
          'id': hit.materialId,
          'title': hit.materialTitle,
          'position': hit.position,
          'label': hit.label == null
              ? ''
              : text.format('system.label', {'label': hit.label!}),
          'snippet': hit.snippet,
        }),
      );
    }
  }

  if (context.relatedRecords.isNotEmpty) {
    lines.add(text['system.related_records']);
    for (final record in uniqueById(
      context.relatedRecords,
      (record) => record.conversationId,
    )) {
      lines.add(
        text.format('system.related_line', {
          'title': record.title ?? text['system.untitled_record'],
          'snippet': record.snippet,
        }),
      );
    }
  }

  if (context.evidence.isNotEmpty) {
    lines.add(text['system.evidence']);
    for (final hit in uniqueById(context.evidence, (hit) => hit.identity)) {
      lines.add(
        text.format('system.evidence_line', {
          'kind': hit.kind.label,
          'title': hit.title,
          'identity': hit.identity,
          'snippet': hit.snippet,
        }),
      );
    }
  }

  if (context.question != null) {
    final question = context.question!;
    final attempt = context.attempt;
    if (attempt != null) attemptIds.add(attempt.id);
    final earlier = context.priorFeedback
        .where((entry) => attemptIds.add(entry.id))
        .toList();
    lines
      ..add(text.format('system.question', {'stem': question.displayStem}))
      ..add(
        text.format('system.source', {
          'source': question.sourceRef ?? text['system.source_none'],
        }),
      );
    if (earlier.isNotEmpty) {
      lines.add(text['system.prior_feedback']);
      for (final attempt in earlier) {
        final at = attempt.submittedAt;
        lines.add(
          text.format('system.prior_feedback_line', {
            'date': at == null
                ? ''
                : text.format('system.date_prefix', {'date': formatDate(at)}),
            'feedback': attempt.feedback ?? '',
          }),
        );
      }
    }
    if (attempt != null) {
      lines.add(
        text.format('system.attempt', {
          'status': attempt.submitted
              ? text['system.attempt_submitted']
              : text['system.attempt_unsubmitted'],
          'answer': attempt.userAnswer == null
              ? ''
              : text.format('system.attempt_answer', {
                  'value': attempt.userAnswer!,
                }),
          'solution': attempt.solution == null
              ? ''
              : text.format('system.attempt_solution', {
                  'value': attempt.solution!,
                }),
          'correct': attempt.isCorrect == null
              ? text['system.attempt_correct_unknown']
              : attempt.isCorrect!
              ? text['system.attempt_correct']
              : text['system.attempt_incorrect'],
          'independent': attempt.independent == null
              ? text['system.attempt_independent_unknown']
              : attempt.independent!
              ? text['system.attempt_independent']
              : text['system.attempt_external_help'],
          'delayed': attempt.delayed
              ? text['system.attempt_delayed']
              : text['system.attempt_on_time'],
          'helps': attempt.helps.isEmpty
              ? ''
              : text.format('system.attempt_helps', {
                  'count': '${attempt.helps.length}',
                }),
        }),
      );
      if (attempt.helps.isNotEmpty) {
        lines.add(
          text.format('system.last_help', {
            'content': attempt.helps.last.content,
          }),
        );
      }
      if (context.assessmentRecords.isNotEmpty) {
        lines.add(text['system.assessments']);
        for (final assessment in uniqueById(
          context.assessmentRecords,
          (assessment) => assessment.id,
        )) {
          lines.add(
            text.format('system.assessment_line', {
              'kind': assessment.kind.label,
              'result': assessment.result,
              'basis': assessment.basis == null
                  ? ''
                  : text.format('system.assessment_basis', {
                      'basis': assessment.basis!,
                    }),
            }),
          );
        }
      } else {
        lines.add(text['system.assessment_none']);
      }
    }
  }
  if (context.crossSessionNotes.isNotEmpty) {
    lines.add(text['system.cross_session']);
    for (final note in context.crossSessionNotes) {
      lines.add(text.format('system.cross_line', {'note': note}));
    }
  }

  lines.add(
    text.format('system.mode', {'label': text['mode.${context.mode.value}']}),
  );

  if (withPlanContext) {
    lines.add(text['system.plan_items']);
    if (context.openItems.isEmpty) {
      lines.add(text['system.plan_none']);
    } else {
      for (final item in uniqueById(context.openItems, (item) => item.id)) {
        lines.add(
          text.format('system.plan_line', {
            'id': item.id,
            'title': item.title,
            'note': item.note == null
                ? ''
                : text.format('system.plan_note', {'note': item.note!}),
            'due': item.dueAt == null
                ? ''
                : text.format('system.plan_due', {
                    'date': formatDateTime(item.dueAt!),
                  }),
          }),
        );
      }
    }

    lines.add(text['system.today_blocks']);
    if (context.todayBlocks.isEmpty) {
      lines.add(text['system.plan_none']);
    } else {
      for (final block in uniqueById(
        context.todayBlocks,
        (block) => block.block.id,
      )) {
        lines.add(
          text.format('system.block_line', {
            'start': formatDateTime(block.block.startAt),
            'end': formatDateTime(block.block.endAt),
            'title': block.itemTitle,
          }),
        );
      }
    }
  }

  // 普通讨论也要看得到最近作答；这些记录本来已经读进上下文，只列给规划提示
  // 会让“上次卡在哪里”只能靠本地兜底回答。
  final recent = context.recentAttempts
      .where((entry) => attemptIds.add(entry.attempt.id))
      .toList();
  if (recent.isNotEmpty) {
    lines.add(text['system.recent_attempts']);
    for (final entry in recent) {
      final attempt = entry.attempt;
      lines.add(
        text.format('system.recent_line', {
          'stem': entry.question.displayStem,
          'judgment': attempt.judgmentLabel,
          'self': attempt.selfResult.isEmpty
              ? ''
              : text.format('system.recent_self', {'self': attempt.selfResult}),
          'feedback':
              attempt.feedback == null || attempt.feedback!.trim().isEmpty
              ? ''
              : text.format('system.recent_feedback', {
                  'feedback': attempt.feedback!.trim(),
                }),
        }),
      );
    }
  }

  lines.add(text['system.memories']);
  if (context.memories.isEmpty) {
    lines.add(text['system.memory_none']);
  } else {
    for (final memory in uniqueById(context.memories, (memory) => memory.id)) {
      lines.add(
        text.format('system.memory_line', {
          'kind': memory.kind.label,
          'content': _memoryText(memory.content),
          'valid': memory.validUntil == null
              ? ''
              : text.format('system.memory_valid', {
                  'date': formatDate(memory.validUntil!),
                }),
        }),
      );
    }
  }

  return lines.join('\n');
}

/// 单条记忆进入提示词时最多 [memoryContentLimit] 字；超出部分截断，避免一条
/// 长记忆挤占上下文。
String _memoryText(String content) {
  return truncateCodePoints(content, memoryContentLimit);
}
