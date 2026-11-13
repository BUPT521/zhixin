import '../domain/models/buddy_protocol.dart';
import '../domain/models/evidence.dart';
import '../domain/models/memory.dart';
import '../domain/models/study_plan.dart' show StudyStepDraft;
import '../domain/rules/study_plan_steps.dart';
import 'agent_read_budget.dart';
import 'agent_tools.dart';
import 'llm_client.dart';
import 'material_page_tool.dart';
import 'search_sources_tool.dart';

/// 普通问答可以提交的记忆。
const String proposeMemoriesTool = 'propose_memories';

/// 普通问答可以提交的下一步建议。
const String proposeNextStepsTool = 'propose_next_steps';

/// 普通问答可以提交的材料引用。
const String proposeCitationsTool = 'propose_citations';

/// 检查作答时可以提交的学习判断。
const String proposeAssessmentTool = 'propose_assessment';

/// 系统学习时可以提交的学习步骤。
const String proposeStudyStepsTool = 'propose_study_steps';

/// 每轮独立暂存提案。只有回答成功时，应用才取出这些提案。
class BuddyTurnTools {
  BuddyTurnTools(BuddyContext context) {
    final mode = context.mode;
    final budget = AgentReadBudget();
    // 首轮材料页与本轮补搜到的页放在同一份可补读集合里，读取工具都能分段读。
    final pages = {
      for (final hit in context.additionalMaterialHits) hit.pageKey: hit,
    };
    registry = AgentToolSet([
      if (mode != BuddyMode.plan) _proposeMemories(_memories),
      if (mode == BuddyMode.chat) ...[
        _proposeNextSteps(_nextSteps),
        _proposeCitations(_citations),
      ],
      if (mode == BuddyMode.check) _proposeAssessment(),
      if (mode == BuddyMode.plan)
        _proposeStudySteps(
          context.uniqueOutlinePages.map((page) => page.pageNo).toSet().toList()
            ..sort(),
        ),
      if (canReadMaterial(context))
        materialPageReader(pages, readBudget: budget),
      if (canSearchSources(context))
        searchSourcesReader(
          context.sourceSearch!,
          budget: budget,
          providedSources: _providedSources,
          pages: pages,
        ),
    ], requiredTool: mode == BuddyMode.plan ? proposeStudyStepsTool : null);
  }

  late final AgentToolSet registry;
  final _memories = _Proposals<MemoryDraft>(5, (draft) => draft.contentId);
  final _nextSteps = _Proposals<NextStepDraft>(3, (draft) => draft.contentId);
  final _citations = _Proposals<CitationDraft>(5, (draft) => draft.contentId);
  final _providedSources = <CitationSource>[];
  var _studySteps = <StudyStepDraft>[];
  AssessmentDraft? _assessment;

  BuddyReply finish(String text) {
    final body = text.trim();
    if (registry.requiredTool != null ? _studySteps.isEmpty : body.isEmpty) {
      throw FormatException(
        registry.requiredTool != null ? '模型没有返回学习步骤' : '回答没有正文',
      );
    }
    return BuddyReply(
      text: body,
      memories: _memories.values,
      nextSteps: _nextSteps.values,
      citations: _citations.values,
      studySteps: List.unmodifiable(_studySteps),
      assessment: _assessment,
      providedSources: List.unmodifiable(_providedSources),
    );
  }

  AgentTool _proposeAssessment() => AgentTool(
    schema: _assessmentSchema,
    continuesAfterText: false,
    execute: (args, _) {
      if (_assessment != null) return _alreadyStaged;
      _assessment = AssessmentDraft(
        result: args['result'] as String,
        basis: _optionalText(args, 'basis'),
      );
      return _staged;
    },
  );

  AgentTool _proposeStudySteps(List<int> pageNos) => AgentTool(
    schema: _studyStepsSchema,
    continuesAfterText: false,
    execute: (args, _) {
      if (_studySteps.isNotEmpty) return _alreadyStaged;
      final steps = [
        for (final item in (args['steps'] as List).cast<ToolArguments>())
          StudyStepDraft(
            title: (item['title'] as String).trim(),
            pageFrom: item['page_from'] as int?,
            pageTo: item['page_to'] as int?,
            note: _optionalText(item, 'note'),
            isPrerequisite: item['is_prerequisite'] == true,
          ),
      ];
      if (pageNos.isNotEmpty) {
        final problem = studyStepsProblem(
          steps: steps,
          pageNos: pageNos,
          pageFrom: pageNos.first,
          pageTo: pageNos.last,
        );
        if (problem != null) {
          return AgentToolResult.error(
            'invalid_study_plan',
            '$problem，请重新提交完整方案',
          );
        }
      }
      final unique = {for (final step in steps) step.contentId: step};
      _studySteps = unique.values.toList(growable: false);
      return const AgentToolResult('已暂存提案', concludesTurn: true);
    },
  );
}

const _staged = AgentToolResult('已暂存提案');
const _alreadyStaged = AgentToolResult.unchanged('本轮已有同类提案，请继续回答');

/// 以规范化内容去重，单轮内保留最先提交的条目。
class _Proposals<T> {
  _Proposals(this.limit, this.id);

  final int limit;
  final String Function(T value) id;
  final _values = <String, T>{};

  List<T> get values => List.unmodifiable(_values.values);

  AgentToolResult addAll(Iterable<T> drafts) {
    final before = _values.length;
    for (final draft in drafts) {
      if (_values.length >= limit) break;
      _values.putIfAbsent(id(draft), () => draft);
    }
    return _values.length > before ? _staged : _alreadyStaged;
  }
}

AgentTool _proposeMemories(_Proposals<MemoryDraft> proposals) => AgentTool(
  schema: _memoriesSchema,
  continuesAfterText: false,
  partialList: 'memories',
  execute: (args, _) {
    final drafts = <MemoryDraft>[];
    for (final item in (args['memories'] as List).cast<ToolArguments>()) {
      final validUntil = _optionalText(item, 'valid_until');
      final expiry = validUntil == null ? null : DateTime.tryParse(validUntil);
      if (validUntil != null && expiry == null) continue;
      drafts.add(
        MemoryDraft(
          kind: MemoryKind.values.byName(item['kind'] as String),
          content: (item['content'] as String).trim(),
          validUntil: expiry,
          source: MemorySource.values.byName(item['source'] as String),
        ),
      );
    }
    if (drafts.isEmpty) {
      return const AgentToolResult.invalid('valid_until 应为有效日期或 null');
    }
    return proposals.addAll(drafts);
  },
);

AgentTool _proposeNextSteps(_Proposals<NextStepDraft> proposals) => AgentTool(
  schema: _nextStepsSchema,
  continuesAfterText: false,
  partialList: 'steps',
  execute: (args, _) => proposals.addAll([
    for (final item in (args['steps'] as List).cast<ToolArguments>())
      NextStepDraft(
        title: (item['title'] as String).trim(),
        action: _optionalText(item, 'action'),
        endCondition: _optionalText(item, 'end_condition'),
        minutes: item['minutes'] as int?,
      ),
  ]),
);

AgentTool _proposeCitations(_Proposals<CitationDraft> proposals) => AgentTool(
  schema: _citationsSchema,
  continuesAfterText: false,
  partialList: 'citations',
  execute: (args, _) => proposals.addAll([
    for (final item in (args['citations'] as List).cast<ToolArguments>())
      CitationDraft(
        materialId: item['material_id'] as int,
        pageNo: item['page_no'] as int,
        quote: (item['quote'] as String).trim(),
      ),
  ]),
);

String? _optionalText(ToolArguments args, String field) {
  final text = (args[field] as String?)?.trim();
  return text == null || text.isEmpty ? null : text;
}

const LlmTool _memoriesSchema = LlmTool(
  name: proposeMemoriesTool,
  description:
      '提交这次回答里值得记住的事实。只提交，不直接写数据库；用户明确说出的记忆由程序先记下并可撤销，'
      '你推断的记忆由用户点“记下”后才保存。'
      '只记长期有用或本次有效的事实，寒暄、一次性情绪和单次卡点不要提交。'
      '用户明确说出的内容 source 用 user；你根据记录推断的用 inferred，用户没有说过的不要编造。',
  parameters: {
    'type': 'object',
    'properties': {
      'memories': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 5,
        'items': {
          'type': 'object',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['preference', 'constraint', 'difficulty', 'progress'],
            },
            'content': {
              'type': 'string',
              'minLength': 1,
              'maxLength': 200,
              'description': '一句话，不超过 200 字',
            },
            'valid_until': {
              'type': ['string', 'null'],
              'description': 'YYYY-MM-DD HH:MM:SS；长期有效填 null',
            },
            'source': {
              'type': 'string',
              'enum': ['user', 'inferred'],
              'description': '用户明确说出的用 user，你推断的用 inferred',
            },
          },
          'required': ['kind', 'content', 'source'],
        },
      },
    },
    'required': ['memories'],
  },
);

const LlmTool _nextStepsSchema = LlmTool(
  name: proposeNextStepsTool,
  description:
      '提交 1–3 条下一步建议。只是建议，不创建待办、不改动日程；用户点“加入安排”后才由程序保存。'
      '每条写清做什么与做到什么算结束，材料出处或题号写进标题或动作里。'
      '用户没有问下一步时不要提交。',
  parameters: {
    'type': 'object',
    'properties': {
      'steps': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 3,
        'items': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'minLength': 1, 'description': '动作标题'},
            'action': {
              'type': ['string', 'null'],
              'description': '具体动作',
            },
            'end_condition': {
              'type': ['string', 'null'],
              'description': '什么时候算结束',
            },
            'minutes': {
              'type': ['integer', 'null'],
              'description': '预计分钟数，可省略',
            },
          },
          'required': ['title'],
        },
      },
    },
    'required': ['steps'],
  },
);

const LlmTool _citationsSchema = LlmTool(
  name: proposeCitationsTool,
  description:
      '提交这次回答依据的材料页。quote 必须逐字摘录该页原文，material_id 用材料页前面标的编号；'
      '不要改写、拼接或编造页码。没有依据就不要调用。',
  parameters: {
    'type': 'object',
    'properties': {
      'citations': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 5,
        'items': {
          'type': 'object',
          'properties': {
            'material_id': {'type': 'integer'},
            'page_no': {'type': 'integer'},
            'quote': {
              'type': 'string',
              'minLength': 1,
              'description': '原文逐字摘录',
            },
          },
          'required': ['material_id', 'page_no', 'quote'],
        },
      },
    },
    'required': ['citations'],
  },
);

const LlmTool _assessmentSchema = LlmTool(
  name: proposeAssessmentTool,
  description:
      '提交这次学习结果的判断。只提交依据，不替用户判分；'
      '结果区分独立完成、辅助完成与待核实。',
  parameters: {
    'type': 'object',
    'properties': {
      'result': {
        'type': 'string',
        'enum': ['独立完成', '辅助完成', '待核实'],
      },
      'basis': {
        'type': ['string', 'null'],
        'description': '依据哪段原文或哪次提示',
      },
    },
    'required': ['result'],
  },
);

const LlmTool _studyStepsSchema = LlmTool(
  name: proposeStudyStepsTool,
  description:
      '按本次给出的材料页提出学习步骤，覆盖本次范围。每步写清页码范围与补充说明；'
      '完成目标必需、但材料里没有展开的内容标 is_prerequisite=true 并写进 note。'
      '不要替用户安排时间。',
  parameters: {
    'type': 'object',
    'properties': {
      'steps': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 12,
        'items': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'minLength': 1,
              'description': '这一步做什么',
            },
            'page_from': {
              'type': ['integer', 'null'],
            },
            'page_to': {
              'type': ['integer', 'null'],
            },
            'note': {
              'type': ['string', 'null'],
              'description': '补充说明',
            },
            'is_prerequisite': {'type': 'boolean'},
          },
          'required': ['title'],
        },
      },
    },
    'required': ['steps'],
  },
);
