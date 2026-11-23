import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/domain/models/assessment.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/question.dart';
import 'package:zhixin/domain/models/study.dart';

/// 回答质量对照评测的第一版样例，对应 [02 第 8.4 节](../../../docs/02-产品与交互.md#84-回答质量对照评测)。
///
/// 每例给出同一份合成数据下的系统提示条件与用户输入；提示词覆盖由
/// `answer_quality_test.dart` 检查，真实模型下的回答对照仍按 02 的四项打分表
/// 手工记录。改提示词或样例时把本文件与 `assets/prompts/` 放在同一次提交里。
class AnswerQualityCase {
  const AnswerQualityCase({
    required this.id,
    required this.name,
    required this.scenario,
    required this.userText,
    required this.context,
    required this.expected,
    this.requiredText = const [],
    this.forbiddenText = const [],
    this.orderedText = const [],
  });

  final String id;
  final String name;
  final String scenario;
  final String userText;
  final BuddyContext Function() context;

  /// 02 第 8.4 节的通过条件摘要，供对照时逐条核对。
  final List<String> expected;

  /// 这条样例要求提示词里出现的内容。
  final List<String> requiredText;

  /// 这条样例的上下文里不应出现的内容，用于检查范围没有扩大。
  final List<String> forbiddenText;

  /// 这些片段在提示词里的先后顺序。
  final List<String> orderedText;
}

final DateTime _now = DateTime(2026, 11, 16, 9, 30);

final List<AnswerQualityCase> answerQualityCases = [
  AnswerQualityCase(
    id: 'V1-独立求助',
    name: '独立求助',
    scenario: 'V1',
    userText: '我能把 2(x+3) 展成 2x+3 吗？',
    context: () => BuddyContext(now: _now, mode: BuddyMode.chat),
    requiredText: [
      '不要要求用户先建立目标或归类',
      'next_steps 只是建议',
      '依据本轮提供的记录',
      '本次材料：（没有带入）',
    ],
    forbiddenText: ['材料原文：', '已接受的学习事项', 'material_id='],
    expected: ['指出括号内两项都要乘 2，并给出可执行的检查办法', '普通求助没有产生已写入的待办或预约'],
  ),
  AnswerQualityCase(
    id: 'V1-工具参数无效',
    name: '工具参数无效',
    scenario: 'V1',
    userText: '沿用上一问，让测试模型返回正确正文与参数无效的建议提案',
    context: () => BuddyContext(now: _now, mode: BuddyMode.chat),
    requiredText: ['next_steps 只是建议', '整轮回答需要有完整正文'],
    expected: ['保留正文，丢弃无效提案', '记录及安排的变化符合 V1 通过条件'],
  ),
  AnswerQualityCase(
    id: 'V3-引用与范围',
    name: '引用与范围',
    scenario: 'V3',
    userText: '本课讲义怎么定义矩阵的迹？请引原文',
    context: () {
      const goal = LearningGoal(id: 'goal-linear', title: '线性代数');
      const material = Material(
        id: 'mat-linear',
        title: '线性代数复习讲义',
        goalId: 'goal-linear',
      );
      const page = MaterialPage(
        id: 'page-3',
        materialId: 'mat-linear',
        pageNo: 3,
        content: '矩阵的迹是主对角元素之和。',
        label: '例 3-2',
      );
      return BuddyContext(
        now: _now,
        mode: BuddyMode.chat,
        goal: goal,
        goals: const [goal],
        material: material,
        materialPage: page,
        materialHits: const [
          MaterialHit(
            materialId: 'mat-linear',
            materialTitle: '线性代数复习讲义',
            pageNo: 1,
            content: '矩阵的主对角线从左上到右下。',
            label: '第 1 页',
          ),
        ],
      );
    },
    requiredText: [
      '本次材料：material_id=mat-linear',
      '矩阵的迹是主对角元素之和。',
      'citations 只在依据了下面材料原文时提交',
      'quote 必须逐字摘录该页内容',
    ],
    forbiddenText: ['程序设计', 'mat-program'],
    expected: ['只引当前范围内第 3 页的逐字内容，回答随更正更新', '缺少证据时说明待核对'],
  ),
  AnswerQualityCase(
    id: 'V6-判断依据',
    name: '判断依据',
    scenario: 'V6',
    userText: '提交矩阵迹的答案，自评未判断，并附上自行核对的计算式',
    context: () {
      final attempt = Attempt(
        id: 'attempt-6',
        conversationId: 'conv-6',
        userAnswer: '3',
        helps: [
          HelpEntry(
            kind: 'hint',
            content: '先看主对角线',
            at: DateTime(2026, 11, 16, 9),
          ),
        ],
        submittedAt: DateTime(2026, 11, 16, 9, 10),
      );
      return BuddyContext(
        now: _now,
        mode: BuddyMode.check,
        question: const Question(id: 'conv-6', stem: '求矩阵的迹'),
        attempt: attempt,
        assessmentRecords: const [
          Assessment(
            id: 'assessment-6',
            attemptId: 'attempt-6',
            kind: AssessmentKind.user,
            result: '我重算了一遍',
            basis: '自己重算了一遍',
          ),
        ],
      );
    },
    requiredText: [
      '当前题目：求矩阵的迹',
      '本次尝试：已提交',
      '自评对错未记录',
      '独立性未说明',
      '最近一次帮助：先看主对角线',
      '用户提供的核对依据',
      '；依据：自己重算了一遍',
    ],
    forbiddenText: ['用户自评正确', '用户自评有误'],
    expected: ['分别列出自评、应用内帮助和用户提供的依据', '没有足够依据时保留未判断，独立性以记录为据'],
  ),
  AnswerQualityCase(
    id: 'V11-偏好冲突',
    name: '偏好冲突',
    scenario: 'V11',
    userText: '这次先给定义，例题先略过',
    context: () => BuddyContext(
      now: _now,
      mode: BuddyMode.explain,
      persona: const BuddyPersona(name: '先定义', text: '先讲定义，例题从简。'),
      memories: const [
        Memory(id: 'memory-11', kind: MemoryKind.semantic, content: '讲解先给例题'),
      ],
    ),
    requiredText: [
      '当前启用的人格：先定义',
      '人格只影响语气、称呼、讲解风格与篇幅倾向',
      '用户本轮说明优先于人格',
      '人格优先于记忆里的做法',
      '讲解先给例题',
    ],
    orderedText: ['规则：', '当前启用的人格：先定义', '当前时间：', '记得的事（[情景]'],
    expected: ['先给定义，省略例题；本轮要求优先', '失效记忆不出现在本轮上下文'],
  ),
  AnswerQualityCase(
    id: 'V11-跨次回看',
    name: '跨次回看',
    scenario: 'V11',
    userText: '上次我怎么做的，后来有没有独立做对？',
    context: () {
      final question = const Question(id: 'conv-11', stem: '求矩阵的迹');
      final earlier = Attempt(
        id: 'attempt-10',
        conversationId: 'conv-11',
        feedback: '漏了主对角元素',
        submittedAt: DateTime(2026, 11, 15, 20),
      );
      final attempt = Attempt(
        id: 'attempt-11',
        conversationId: 'conv-11',
        userAnswer: '1+2+3',
        isCorrect: true,
        delayed: true,
        submittedAt: DateTime(2026, 11, 16, 9),
      );
      final recent = Attempt(
        id: 'attempt-9',
        conversationId: 'conv-9',
        userAnswer: '2+3',
        feedback: '上一次漏掉了最后一项',
        submittedAt: DateTime(2026, 11, 14, 20),
      );
      return BuddyContext(
        now: _now,
        mode: BuddyMode.hint,
        question: question,
        attempt: attempt,
        priorFeedback: [earlier],
        recentAttempts: [
          AttemptWithQuestion(attempt: earlier, question: question),
          AttemptWithQuestion(
            attempt: recent,
            question: const Question(id: 'conv-9', stem: '求行列式'),
          ),
        ],
        crossSessionNotes: const ['后来有没有独立做对缺少记录', '独立性未说明'],
      );
    },
    requiredText: [
      '这道题以前留下的困难',
      '漏了主对角元素',
      '本次尝试：已提交',
      '间隔后重做',
      '最近提交的尝试',
      '跨次综合时待确认的内容',
      '后来有没有独立做对缺少记录',
    ],
    forbiddenText: ['用户记录为独立完成'],
    expected: ['“上次”对应最近一次提交', '区分自评、应用内提示、外部帮助与独立性未知'],
  ),
  AnswerQualityCase(
    id: '人格与记忆偏好',
    name: '人格与记忆偏好',
    scenario: 'V11',
    userText: '同一问题分别在不说明与说“这次先给例题”时各问一次',
    context: () => BuddyContext(
      now: _now,
      mode: BuddyMode.explain,
      persona: const BuddyPersona(name: '先讲定义', text: '先讲定义，例题从简。'),
      memories: const [
        Memory(
          id: 'memory-persona',
          kind: MemoryKind.semantic,
          content: '讲解先给例题',
        ),
      ],
    ),
    requiredText: ['当前启用的人格：先讲定义', '讲解先给例题', '用户本轮说明优先于人格', '人格优先于记忆里的做法'],
    orderedText: ['规则：', '当前启用的人格：先讲定义', '记得的事（[情景]'],
    expected: ['不说明时按人格的顺序，说明时按本轮要求', '判分、引用与写入规则不随人格改变'],
  ),
];

/// 02 第 8.4 节的四项打分维度；每例都按这四项记录通过、失败或不适用。
const List<String> answerQualityDimensions = [
  '回答当前问题',
  '结论有依据',
  '引用及来源范围',
  '工具及写入行为',
];
