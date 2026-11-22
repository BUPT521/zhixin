import '../domain/rules/text.dart';
import '../domain/models/buddy_protocol.dart';
import '../domain/models/evidence.dart';
import '../domain/models/memory.dart';
import '../domain/models/study_plan.dart' show StudyStepDraft;
import '../domain/rules/study_plan_steps.dart';
import 'agent_read_budget.dart';
import 'agent_tools.dart';
import 'llm_client.dart';
import 'prompt_text.dart';
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
  BuddyTurnTools(BuddyContext context)
    : _unit = context.material?.isDocx == true ? '片段' : '页' {
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

  /// 本次范围的单位：文档材料按片段编号，其余按页码；工具出错时用它说明范围。
  final String _unit;
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
            '$problem；本次范围共 ${pageNos.length} $_unit，最多 ${pageNos.length} 步，'
                '每一$_unit只出现一次并连续覆盖，请重新提交完整方案',
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
      // 认不出的类型不写进库：记忆类型只有固定的几种，未知值落库会被 CHECK 拒绝。
      final kind = MemoryKind.fromValue(item['kind'] as String?);
      if (kind == MemoryKind.unknown) continue;
      drafts.add(
        MemoryDraft(
          kind: kind,
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
        materialId: item['material_id'] as String,
        pageNo: item['page_no'] as int,
        quote: (item['quote'] as String).trim(),
      ),
  ]),
);

String? _optionalText(ToolArguments args, String field) =>
    nullableText(args[field] as String?);

/// 工具参数按代码调用发送时，接口看到的输入只有一段 JSON 文本；文本的形状
/// 记在 `zod.properties` 里，执行之前先把文本转成对象。
Map<String, Object?> _parameters(Map<String, Object?> properties) => {
  'type': 'object',
  'properties': {
    'input': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'type': {
            'type': 'string',
            'enum': ['input_text'],
          },
          'text': {
            'type': 'string',
            'description': '参数的 JSON 文本，形状见 zod.properties',
          },
          'zod': _zod(properties),
        },
        'required': ['type', 'text', 'zod'],
      },
    },
  },
  'required': ['input'],
  'additionalProperties': false,
};

/// 文本的内容形状；JSON 校验器按它在本地核对参数。
Map<String, Object?> _zod(Map<String, Object?> properties) => {
  'type': 'object',
  'description': '参数依靠代码执行的形状声明，内容等同于参数的 JSON Schema',
  'properties': {'kind': _zodKind, 'properties': properties},
};

const Map<String, Object?> _zodKind = {
  'type': 'object',
  'description': '表示一段要按代码执行才能得到对象的文字：{"code": "…"}',
};

LlmTool get _memoriesSchema {
  final text = PromptText.instance;
  return LlmTool(
    name: proposeMemoriesTool,
    description: text['tool.propose_memories'],
    parameters: _parameters({
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
                'maxLength': memoryContentLimit,
                'description': text.format('tool.propose_memories.content', {
                  'limit': '$memoryContentLimit',
                }),
              },
              'valid_until': {
                'type': ['string', 'null'],
                'description': text['tool.propose_memories.valid_until'],
              },
              'source': {
                'type': 'string',
                'enum': ['user', 'inferred'],
                'description': text['tool.propose_memories.source'],
              },
            },
            'required': ['kind', 'content', 'source'],
          },
        },
      },
      'required': ['memories'],
    }),
  );
}

LlmTool get _nextStepsSchema {
  final text = PromptText.instance;
  return LlmTool(
    name: proposeNextStepsTool,
    description: text['tool.propose_next_steps'],
    parameters: _parameters({
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 3,
          'items': {
            'type': 'object',
            'properties': {
              'title': {
                'type': 'string',
                'minLength': 1,
                'description': text['tool.propose_next_steps.title'],
              },
              'action': {
                'type': ['string', 'null'],
                'description': text['tool.propose_next_steps.action'],
              },
              'end_condition': {
                'type': ['string', 'null'],
                'description': text['tool.propose_next_steps.end_condition'],
              },
              'minutes': {
                'type': ['integer', 'null'],
                'description': text['tool.propose_next_steps.minutes'],
              },
            },
            'required': ['title'],
          },
        },
      },
      'required': ['steps'],
    }),
  );
}

LlmTool get _citationsSchema {
  final text = PromptText.instance;
  return LlmTool(
    name: proposeCitationsTool,
    description: text['tool.propose_citations'],
    parameters: _parameters({
      'type': 'object',
      'properties': {
        'citations': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 5,
          'items': {
            'type': 'object',
            'properties': {
              'material_id': {'type': 'string'},
              'page_no': {'type': 'integer'},
              'quote': {
                'type': 'string',
                'minLength': 1,
                'description': text['tool.propose_citations.quote'],
              },
            },
            'required': ['material_id', 'page_no', 'quote'],
          },
        },
      },
      'required': ['citations'],
    }),
  );
}

LlmTool get _assessmentSchema {
  final text = PromptText.instance;
  return LlmTool(
    name: proposeAssessmentTool,
    description: text['tool.propose_assessment'],
    parameters: _parameters({
      'type': 'object',
      'properties': {
        'result': {
          'type': 'string',
          'enum': ['独立完成', '辅助完成', '待核实'],
        },
        'basis': {
          'type': ['string', 'null'],
          'description': text['tool.propose_assessment.basis'],
        },
      },
      'required': ['result'],
    }),
  );
}

LlmTool get _studyStepsSchema {
  final text = PromptText.instance;
  return LlmTool(
    name: proposeStudyStepsTool,
    description: text['tool.propose_study_steps'],
    parameters: _parameters({
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 8,
          'items': {
            'type': 'object',
            'properties': {
              'title': {
                'type': 'string',
                'minLength': 1,
                'description': text['tool.propose_study_steps.title'],
              },
              'page_from': {'type': 'integer', 'description': '这一步的起始页码或片段编号'},
              'page_to': {'type': 'integer', 'description': '这一步的结束页码或片段编号'},
              'note': {
                'type': ['string', 'null'],
                'description': text['tool.propose_study_steps.note'],
              },
              'is_prerequisite': {'type': 'boolean'},
            },
            'required': ['title', 'page_from', 'page_to'],
          },
        },
      },
      'required': ['steps'],
    }),
  );
}
