import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_tools.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';

/// 一个工具的契约样例：一份合法规格，以及从解析结果里取出可比较的签名。
class _Contract {
  const _Contract({
    required this.mode,
    required this.toolName,
    required this.arguments,
    required this.signature,
  });

  final BuddyMode mode;
  final String toolName;
  final Map<String, Object?> arguments;
  final String Function(BuddyReply reply) signature;
}

/// 解析一次工具调用；系统学习缺步骤时按格式错误处理，签名留空。
Future<String> _signature(
  _Contract contract,
  Map<String, Object?> arguments,
) async {
  final tools = _tools(contract.mode);
  final budget = LlmRequestBudget(timeout: const Duration(seconds: 1));
  final calls = tools.registry.prepare([
    LlmToolCall(
      id: 'contract',
      name: contract.toolName,
      arguments: jsonEncode(arguments),
    ),
  ], budget);
  final result = await tools.registry.execute(
    calls,
    budget,
    extraResultTokens: 0,
  );
  if (result.outcomes.single.result.errorCode != null) return '';
  try {
    final reply = tools.finish(contract.mode == BuddyMode.plan ? '' : '回答正文');
    return contract.signature(reply);
  } on FormatException {
    return '';
  }
}

BuddyTurnTools _tools(BuddyMode mode) =>
    BuddyTurnTools(BuddyContext(now: DateTime(2026, 11, 6), mode: mode));

/// 去掉数组里每一条的某个字段，其余参数保持不变。
Map<String, Object?> _withoutItemField(
  Map<String, Object?> arguments,
  String listField,
  String itemField,
) {
  final items = (arguments[listField]! as List)
      .whereType<Map>()
      .map((item) => Map<String, Object?>.from(item))
      .toList(growable: false);
  return {
    ...arguments,
    listField: [
      for (final item in items) {...item}..remove(itemField),
    ],
  };
}

void main() {
  final contracts = <_Contract>[
    _Contract(
      mode: BuddyMode.chat,
      toolName: proposeMemoriesTool,
      arguments: {
        'memories': [
          {'kind': 'preference', 'content': '喜欢先看例子', 'source': 'user'},
        ],
      },
      signature: (reply) => [
        for (final draft in reply.memories)
          '${draft.kind.value}|${draft.content}|${draft.source.value}',
      ].join(';'),
    ),
    _Contract(
      mode: BuddyMode.chat,
      toolName: proposeNextStepsTool,
      arguments: {
        'steps': [
          {
            'title': '重做第 8 题',
            'action': '不看答案',
            'end_condition': '写出放缩依据',
            'minutes': 20,
          },
        ],
      },
      signature: (reply) => [
        for (final draft in reply.nextSteps)
          '${draft.title}|${draft.action}|${draft.endCondition}|${draft.minutes}',
      ].join(';'),
    ),
    _Contract(
      mode: BuddyMode.chat,
      toolName: proposeCitationsTool,
      arguments: {
        'citations': [
          {'material_id': 1, 'page_no': 3, 'quote': '原文逐字摘录'},
        ],
      },
      signature: (reply) => [
        for (final draft in reply.citations)
          '${draft.materialId}|${draft.pageNo}|${draft.quote}',
      ].join(';'),
    ),
    _Contract(
      mode: BuddyMode.check,
      toolName: proposeAssessmentTool,
      arguments: {'result': '独立完成', 'basis': '依据原文'},
      signature: (reply) {
        final assessment = reply.assessment;
        if (assessment == null) return '';
        return '${assessment.result}|${assessment.basis}';
      },
    ),
    _Contract(
      mode: BuddyMode.plan,
      toolName: proposeStudyStepsTool,
      arguments: {
        'steps': [
          {
            'title': '读第 1–2 页',
            'page_from': 1,
            'page_to': 2,
            'note': '先看定义',
            'is_prerequisite': false,
          },
        ],
      },
      signature: (reply) => [
        for (final draft in reply.studySteps)
          '${draft.title}|${draft.pageFrom}|${draft.pageTo}|${draft.note}|'
              '${draft.isPrerequisite}',
      ].join(';'),
    ),
  ];

  test('每种模式暴露的工具都有契约样例', () async {
    final exposed = {
      for (final mode in BuddyMode.values)
        for (final tool in _tools(mode).registry.schemas) tool.name,
    };
    expect(contracts.map((contract) => contract.toolName).toSet(), exposed);
  });

  test('工具执行前校验 schema 的必填字段', () async {
    for (final contract in contracts) {
      final tool = _tools(contract.mode).registry.schemas
          .singleWhere((tool) => tool.name == contract.toolName);
      final properties = (tool.parameters['properties']! as Map)
          .cast<String, Object?>();
      final required = (tool.parameters['required']! as List).cast<String>();
      final baseline = await _signature(contract, contract.arguments);
      expect(baseline, isNotEmpty, reason: '${contract.toolName} 的样例应当能解析出内容');

      for (final field in required) {
        expect(
          contract.arguments,
          contains(field),
          reason: '${contract.toolName} 的样例缺少 schema 必填字段 $field',
        );
        final withoutField = Map<String, Object?>.from(contract.arguments)
          ..remove(field);
        expect(
          await _signature(contract, withoutField),
          isEmpty,
          reason: '${contract.toolName}.$field 在 schema 里必填，解析器没有读它',
        );

        final property = properties[field];
        if (property is! Map) continue;
        final items = property['items'];
        if (items is! Map) continue;
        final itemRequired = items['required'];
        if (itemRequired is! List) continue;
        for (final itemField in itemRequired.cast<String>()) {
          for (final item in contract.arguments[field]! as List) {
            expect(
              item,
              contains(itemField),
              reason:
                  '${contract.toolName} 的 $field 条目样例缺少 schema 必填字段 '
                  '$itemField',
            );
          }
          expect(
            await _signature(
              contract,
              _withoutItemField(contract.arguments, field, itemField),
            ),
            isEmpty,
            reason:
                '${contract.toolName} 的 $field 条目里 $itemField 在 schema 里必填，'
                '解析器没有读它',
          );
        }
      }
    }
  });
}
