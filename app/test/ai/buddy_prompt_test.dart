import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/question.dart';
import 'package:zhixin/domain/models/study.dart';

LlmToolCall call(String name, Object? arguments) => LlmToolCall(
  id: '',
  name: name,
  arguments: arguments is String ? arguments : jsonEncode(arguments),
);

BuddyTurnTools _tools(BuddyMode mode) =>
    BuddyTurnTools(BuddyContext(now: DateTime(2026, 11, 6), mode: mode));

Future<BuddyReply> _runTools({
  required String text,
  required BuddyMode mode,
  required List<LlmToolCall> calls,
}) async {
  final tools = _tools(mode);
  final budget = LlmRequestBudget(timeout: const Duration(seconds: 1));
  final prepared = tools.registry.prepare(calls, budget);
  await tools.registry.execute(prepared, budget, extraResultTokens: 0);
  return tools.finish(text);
}

void main() {
  test('正文与工具调用一起解析成记忆、建议与引用', () async {
    final reply = await _runTools(
      text: '先检查这一步。',
      mode: BuddyMode.chat,
      calls: [
        call(proposeMemoriesTool, {
          'memories': [
            {
              'kind': 'constraint',
              'content': '本周晚上只有半小时',
              'valid_until': null,
              'source': 'user',
            },
          ],
        }),
        call(proposeNextStepsTool, {
          'steps': [
            {
              'title': '重做第 8 题',
              'action': '不看答案',
              'end_condition': '写出放缩依据',
              'minutes': 20,
            },
          ],
        }),
        call(proposeCitationsTool, {
          'citations': [
            {'material_id': 1, 'page_no': 3, 'quote': '原文逐字摘录'},
          ],
        }),
      ],
    );

    expect(reply.text, '先检查这一步。');
    expect(reply.memories.single.kind, MemoryKind.constraint);
    expect(reply.memories.single.source, MemorySource.user);
    expect(reply.nextSteps.single.title, '重做第 8 题');
    expect(reply.nextSteps.single.minutes, 20);
    expect(reply.citations.single.pageNo, 3);
  });

  test('没有工具调用时整段都是正文', () async {
    final reply = await _runTools(
      text: '先看定义，再回到这一步。',
      mode: BuddyMode.chat,
      calls: const [],
    );
    expect(reply.text, '先看定义，再回到这一步。');
    expect(reply.memories, isEmpty);
    expect(reply.nextSteps, isEmpty);
    expect(reply.citations, isEmpty);
  });

  test('工具参数损坏时只丢那一条，正文照常返回', () async {
    final reply = await _runTools(
      text: '先做第一题。',
      mode: BuddyMode.chat,
      calls: const [
        LlmToolCall(
          id: 'broken',
          name: proposeNextStepsTool,
          arguments: '{"steps": [{"title":',
        ),
      ],
    );
    expect(reply.text, '先做第一题。');
    expect(reply.nextSteps, isEmpty);
  });

  test('未知工具忽略，坏条目丢掉、好的保留', () async {
    final reply = await _runTools(
      text: '好。',
      mode: BuddyMode.chat,
      calls: [
        call('unknown_tool', {'x': 1}),
        call(proposeCitationsTool, {
          'citations': [
            {'material_id': 'x'},
            {'material_id': 1, 'page_no': 2, 'quote': '原文'},
          ],
        }),
        call(proposeNextStepsTool, {
          'steps': [
            {'title': ''},
            {'title': '读定义'},
          ],
        }),
      ],
    );
    expect(reply.citations.single.pageNo, 2);
    expect(reply.nextSteps.single.title, '读定义');
  });

  test('无效的记忆类别与判断被丢掉', () async {
    final reply = await _runTools(
      text: '好。',
      mode: BuddyMode.check,
      calls: [
        call(proposeMemoriesTool, {
          'memories': [
            {'kind': 'unknown', 'content': '不该保存', 'source': 'user'},
          ],
        }),
        call(proposeAssessmentTool, {'result': '掌握'}),
      ],
    );
    expect(reply.memories, isEmpty);
    expect(reply.assessment, isNull);
  });

  test('只有工具调用没有正文时拒绝，系统学习除外', () async {
    await expectLater(
      _runTools(
        text: '',
        mode: BuddyMode.chat,
        calls: [
          call(proposeNextStepsTool, {'steps': []}),
        ],
      ),
      throwsFormatException,
    );

    final plan = await _runTools(
      text: '',
      mode: BuddyMode.plan,
      calls: [
        call(proposeStudyStepsTool, {
          'steps': [
            {'title': '读第 1–2 页', 'page_from': 1, 'page_to': 2},
          ],
        }),
      ],
    );
    expect(plan.text, isEmpty);
    expect(plan.studySteps.single.title, '读第 1–2 页');
  });

  test('系统学习没有步骤时按格式错误处理', () async {
    await expectLater(
      _runTools(text: '', mode: BuddyMode.plan, calls: const []),
      throwsFormatException,
    );
  });

  test('同一步多次调用同名工具时合并，条数按上限截断', () async {
    final reply = await _runTools(
      text: '做这几步。',
      mode: BuddyMode.chat,
      calls: [
        call(proposeNextStepsTool, {
          'steps': [
            {'title': '第一步'},
            {'title': '第二步'},
          ],
        }),
        call(proposeNextStepsTool, {
          'steps': [
            {'title': '第三步'},
            {'title': '第四步'},
          ],
        }),
      ],
    );
    expect(reply.nextSteps.map((step) => step.title), ['第一步', '第二步', '第三步']);
  });

  test('按请求类型裁剪工具：普通问答带建议，检查只有判断，学习只有步骤', () async {
    expect(
      _tools(BuddyMode.chat).registry.schemas.map((tool) => tool.name),
      containsAll([
        proposeMemoriesTool,
        proposeNextStepsTool,
        proposeCitationsTool,
      ]),
    );
    expect(
      _tools(BuddyMode.chat).registry.schemas.map((tool) => tool.name),
      isNot(contains(proposeStudyStepsTool)),
    );
    expect(_tools(BuddyMode.hint).registry.schemas.map((tool) => tool.name), [
      proposeMemoriesTool,
    ]);
    expect(
      _tools(BuddyMode.check).registry.schemas.map((tool) => tool.name),
      containsAll([proposeMemoriesTool, proposeAssessmentTool]),
    );
    expect(_tools(BuddyMode.plan).registry.schemas.map((tool) => tool.name), [
      proposeStudyStepsTool,
    ]);
    expect(_tools(BuddyMode.plan).registry.requiredTool, proposeStudyStepsTool);
    expect(_tools(BuddyMode.chat).registry.requiredTool, isNull);
  });

  test('上下文里带上记忆、题目与同时有效的目标', () async {
    final context = BuddyContext(
      now: DateTime(2026, 11, 6, 20),
      goals: const [
        LearningGoal(id: 1, title: '概率论期末'),
        LearningGoal(id: 2, title: '线性代数作业'),
      ],
      memories: const [
        Memory(
          id: 1,
          kind: MemoryKind.difficulty,
          content: '放缩方向不确定',
          status: 'active',
        ),
      ],
      mode: BuddyMode.hint,
    );
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, contains('放缩方向不确定'));
    expect(prompt, contains('只给一个提示'));
    expect(prompt, contains('概率论期末'));
    expect(prompt, contains('线性代数作业'));
    expect(prompt, contains('本次讨论归属：没有归属（正常回答）'));
    expect(prompt, contains('工具'));
    expect(prompt, isNot(contains('next_steps')));
    expect(prompt, isNot(contains('已接受的学习事项')));
  });

  test('同一道题以前的困难单独列出，不混在记忆里', () async {
    final context = BuddyContext(
      now: DateTime(2026, 11, 7, 20),
      mode: BuddyMode.hint,
      question: const Question(id: 1, stem: '求极限'),
      priorFeedback: [
        Attempt(
          id: 1,
          conversationId: 1,
          feedback: '放缩方向还不确定',
          submittedAt: DateTime(2026, 11, 6, 20),
        ),
      ],
    );
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, contains('这道题以前留下的困难'));
    expect(prompt, contains('放缩方向还不确定'));
  });

  test('提示词按请求类型说明工具用途，不再写数据块', () async {
    final chat = buildBuddySystemPrompt(
      BuddyContext(now: DateTime(2026, 11, 7, 20), mode: BuddyMode.chat),
    );
    expect(chat, contains('next_steps'));
    expect(chat, contains('citations'));
    expect(chat, isNot(contains('study_steps')));
    expect(chat, isNot(contains('zhixin')));
    expect(chat, isNot(contains('代码块')));

    final plan = buildBuddySystemPrompt(
      BuddyContext(now: DateTime(2026, 11, 7, 20), mode: BuddyMode.plan),
    );
    expect(plan, contains('学习步骤'));
    expect(plan, contains('今天已排的时间块'));
    expect(plan, isNot(contains('next_steps')));
    expect(plan, isNot(contains('学习判断')));

    final check = buildBuddySystemPrompt(
      BuddyContext(now: DateTime(2026, 11, 7, 20), mode: BuddyMode.check),
    );
    expect(check, contains('学习判断'));
    expect(check, isNot(contains('学习步骤')));
    expect(check, isNot(contains('next_steps')));
    expect(check, isNot(contains('今天已排的时间块')));
  });

  test('讨论明确选择目标时，提示里写清归属', () async {
    final context = BuddyContext(
      now: DateTime(2026, 11, 6, 20),
      goal: const LearningGoal(id: 1, title: '概率论期末'),
      goals: const [LearningGoal(id: 1, title: '概率论期末')],
    );
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, contains('本次讨论归属：概率论期末'));
    expect('概率论期末'.allMatches(prompt), hasLength(1));
    expect(prompt, isNot(contains('本次讨论归属：没有归属')));
  });

  test('材料页带编号，模型引用时不用猜材料 id', () async {
    final context = BuddyContext(
      now: DateTime(2026, 11, 6, 20),
      material: const Material(id: 1, title: '概率论讲义'),
      materialPage: const MaterialPage(
        id: 1,
        materialId: 1,
        pageNo: 2,
        content: '条件概率 P(A|B)=P(AB)/P(B)。',
      ),
      materialHits: const [
        MaterialHit(
          materialId: 2,
          materialTitle: '线性代数笔记',
          pageNo: 1,
          content: '矩阵的秩是行向量组的极大线性无关组的向量个数。',
        ),
      ],
    );
    final prompt = buildBuddySystemPrompt(context);
    expect(prompt, contains('material_id=1 《概率论讲义》第 2 页'));
    expect(prompt, contains('material_id=2 《线性代数笔记》第 1 页'));
  });

  test('材料按材料编号与页码去重，系统学习引用已经带入的原文', () async {
    const selected = MaterialPage(
      id: 1,
      materialId: 1,
      pageNo: 2,
      content: '指定页原文',
    );
    const other = MaterialPage(
      id: 2,
      materialId: 1,
      pageNo: 3,
      content: '另一页原文',
    );
    final context = BuddyContext(
      now: DateTime(2026, 11, 7),
      mode: BuddyMode.plan,
      material: const Material(id: 1, title: '讲义'),
      materialPage: selected,
      outlinePages: const [selected, selected, other, other],
      materialHits: const [
        MaterialHit(
          materialId: 1,
          materialTitle: '讲义',
          pageNo: 2,
          content: '重复的检索摘录',
        ),
        MaterialHit(
          materialId: 2,
          materialTitle: '其他讲义',
          pageNo: 2,
          content: '另一份材料的同页码',
        ),
      ],
    );
    final prompt = buildBuddySystemPrompt(context);
    expect('指定页原文'.allMatches(prompt), hasLength(1));
    expect('另一页原文'.allMatches(prompt), hasLength(1));
    expect(prompt, contains('原文见本次材料'));
    expect(prompt, contains('另一份材料的同页码'));
    expect(prompt, isNot(contains('重复的检索摘录')));
  });
}
