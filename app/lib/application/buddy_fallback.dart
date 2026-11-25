import '../domain/models/buddy_protocol.dart';
import '../domain/rules/text.dart';

/// 在线回答不可用时，按本轮输入给出可独立执行的学习步骤。
String localBuddyReply(
  BuddyContext context, {
  String text = '',
  bool hasImages = false,
}) {
  final asked = _askedText(context, text);
  final help = switch (context.mode) {
    BuddyMode.hint => ('本地提示', _hintSteps),
    BuddyMode.explain => ('本地讲解提纲', _explainSteps),
    BuddyMode.check => ('本地检查清单', _checkSteps),
    BuddyMode.chat || BuddyMode.plan => null,
  };
  if (asked.isEmpty && hasImages) {
    return '图片已保存在本次记录中。请先写下题目要解决的问题、已知条件和卡住的步骤，再按文字继续。';
  }
  if (help != null || asked.isNotEmpty) {
    final steps = help?.$2 ?? _stepsFor(_shapeOf(asked));
    return [
      if (help != null) help.$1 else '围绕「${_excerpt(asked)}」先做这几步。',
      '',
      for (var index = 0; index < steps.length; index++)
        '${index + 1}. ${steps[index]}',
      if (context.material case final material?)
        if (context.materialPage case final page?) ...[
          '',
          '可对照《${material.title}》${material.position(page.pageNo)}核对依据。',
        ],
      if (help != null && context.attempt?.hintUsed == true) ...[
        '',
        '这次已经使用过帮助，可以先独立写一步，再对照上次记录。',
      ],
    ].join('\n');
  }

  final attempt = context.attempt;
  if (attempt != null) {
    if (!attempt.submitted) {
      return '这次作答还没有提交。可以写下已知条件和关键步骤，再回到材料核对；'
          '本地建议只看作答记录，不读题。';
    }
    if (attempt.hintUsed) {
      return '上次作答使用过提示。下一次可先独立重做，写出关键步骤后再与答案对照。';
    }
    return '下一次可换一道同类题独立作答，再记录解题方法和完成条件。';
  }
  if (context.openItems.isNotEmpty) {
    final first = context.openItems.first;
    return '本地建议：开始学习事项「${first.title}」。'
        '${first.note == null ? '完成后记录结果。' : '说明：${first.note}。'}';
  }
  final attempts = context.recentAttempts;
  if (attempts.isNotEmpty) {
    final entry = attempts.first;
    final judgment = entry.attempt.isCorrect == null
        ? '当时没有判断对错'
        : entry.attempt.isCorrect!
        ? '当时自评正确'
        : '当时自评有误';
    return '最近一次作答来自「${entry.question.displayStem}」，$judgment。'
        '可以重新作答，并记录当前的解题方法。';
  }
  if (context.memories.isNotEmpty) {
    return '最近的学习记忆：${context.memories.first.content}。'
        '提一个问题或贴一道题，本地规则会按问法给出步骤。';
  }
  return '写下一道想做的题，或为本周目标写下一件今天能完成的学习事项。';
}

const _hintSteps = [
  '先标出已知条件和题目要求，圈出还缺的一步。',
  '从材料中找一条能连接已知条件与目标的定义或公式，先用它写出一步。',
];

const _explainSteps = [
  '写出题目的目标、已知条件和你准备用的定义。',
  '按顺序写出关键步骤，每一步补一句理由。',
  '对照材料或例题，标出第一处需要进一步确认的推导。',
];

const _checkSteps = [
  '从第一步开始，逐行核对每个结论所用的条件和依据。',
  '用代回原题、检查单位或取一个简单例子来验证结果。',
  '改正第一处对不上的地方，再重新检查后续步骤。',
];

/// 本地可给的一步：用户当次问的是具体问题时不另给建议，避免把话题转到
/// 已有的待办上；明确在问安排，或者没有当次问题时，才看今天的预约与待办。
List<NextStepDraft> localNextStep(
  BuddyContext context, {
  String text = '',
  bool hasImages = false,
}) {
  final asked = _askedText(context, text);
  if (asked.isEmpty ? hasImages : _shapeOf(asked) != _QuestionShape.planning) {
    return const [];
  }
  return _planStep(context);
}

/// 今天还没结束的时间块优先，其次待办，最后是最近一道没做对的题。
List<NextStepDraft> _planStep(BuddyContext context) {
  for (final block in context.todayBlocks) {
    if (!block.block.planned || block.block.endAt.isBefore(context.now)) {
      continue;
    }
    return [
      NextStepDraft(
        title: block.itemTitle,
        action: block.itemNote,
        minutes: block.block.endAt.difference(block.block.startAt).inMinutes,
      ),
    ];
  }
  if (context.openItems.isNotEmpty) {
    final item = context.openItems.first;
    return [
      NextStepDraft(
        title: item.title,
        action: item.note,
        minutes: item.estMinutes,
      ),
    ];
  }
  for (final entry in context.recentAttempts) {
    if (entry.attempt.isCorrect == false) {
      return [
        NextStepDraft(
          title: '重做：${entry.question.displayStem}',
          action: entry.attempt.hintUsed ? '独立重做一遍，写下关键步骤' : '再次作答，并说明这次与上次的不同',
          endCondition: '独立写出完整过程',
          minutes: 20,
        ),
      ];
    }
  }
  return const [];
}

enum _QuestionShape { math, code, language, explain, planning, general }

const List<String> _mathMarkers = [
  '求解',
  '求导',
  '计算',
  '证明',
  '解方程',
  '积分',
  '导数',
  '概率',
  '矩阵',
  '数列',
  '向量',
  '不等式',
  '几何',
  '方程',
];

const List<String> _codeMarkers = [
  '报错',
  '编译',
  '代码',
  '程序',
  '函数',
  '运行',
  '调试',
  '接口',
  '异常',
  'python',
  'java',
  'javascript',
  'typescript',
  'dart',
  'sql',
  'bug',
];

const List<String> _languageMarkers = [
  '翻译',
  '英语',
  '单词',
  '语法',
  '句子',
  '作文',
  '阅读',
  '词义',
  '读音',
  '时态',
];

const List<String> _explainMarkers = [
  '为什么',
  '原因',
  '原理',
  '区别',
  '含义',
  '是什么',
  '怎么理解',
  '如何理解',
  '意义',
];

const List<String> _planningMarkers = [
  '下一步',
  '接下来',
  '做什么',
  '怎么安排',
  '计划',
  '复习',
  '先学',
  '学什么',
  '从哪开始',
  '安排',
];

_QuestionShape _shapeOf(String text) {
  final lower = text.toLowerCase();
  bool has(List<String> markers) => markers.any(lower.contains);
  if (has(_codeMarkers)) return _QuestionShape.code;
  final hasNumber = RegExp(r'\d').hasMatch(lower);
  if (has(_mathMarkers) ||
      (hasNumber && RegExp(r'[+\-×÷*/=<>^]').hasMatch(lower))) {
    return _QuestionShape.math;
  }
  if (has(_languageMarkers)) return _QuestionShape.language;
  if (has(_explainMarkers)) return _QuestionShape.explain;
  if (has(_planningMarkers)) return _QuestionShape.planning;
  return _QuestionShape.general;
}

List<String> _stepsFor(_QuestionShape shape) => switch (shape) {
  _QuestionShape.math => const [
    '把已知量和要求的量分开写下来，标出单位与限制条件。',
    '写出可能用到的一条公式或定义，逐条核对它要求的条件是否都满足。',
    '先算到可以检验的一步，用代回、取特例或检查量纲确认，再继续往下推。',
  ],
  _QuestionShape.code => const [
    '抄下最小可复现的输入和完整的报错首行，不只留最后一句。',
    '在出错的位置前后各看一次中间结果，确认数据的类型与形状。',
    '把问题缩到一段能单独运行的代码，再逐项去掉与报错无关的部分。',
  ],
  _QuestionShape.language => const [
    '先拆出主语、谓语和修饰成分，标出不认识的词。',
    '查词时同时记下词性、一个例句和一个近义说法，不只看中文释义。',
    '合回整句读一遍，核对时态、单复数与语序是否和例句一致。',
  ],
  _QuestionShape.explain => const [
    '用自己的话写下这个问题在问什么，一句话即可。',
    '回到材料或课本找对应的定义与例子，记下页码。',
    '举一个反例或边界情况，检验自己的解释是否还成立。',
  ],
  _QuestionShape.planning => const [
    '从最近一次作答、材料位置和目标里各挑一件，不要同时开三件。',
    '给挑中的这件事写一个二十分钟能做到的动作和一个结束条件。',
    '做完再决定下一步，没有做之前不重排全部计划。',
  ],
  _QuestionShape.general => const [
    '把问题写成一句完整的话：已知什么、想得到什么。',
    '写下已经试过的做法与卡住的那一步。',
    '带着这两条去查材料或课本的对应段落，再回来补充答案。',
  ],
};

/// 这次的问题：讨论里用用户刚写下的话，学习中用题目原文。
String _askedText(BuddyContext context, String text) {
  final typed = text.trim();
  if (typed.isNotEmpty) return typed;
  return context.question?.stem.trim() ?? '';
}

/// 回答开头只放问题的第一行，超过长度时截断。
String _excerpt(String text) {
  const limit = 32;
  final line = text.split('\n').first.replaceAll(RegExp(r'\s+'), ' ').trim();
  return truncateCodePoints(line, limit);
}
