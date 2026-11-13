import '../domain/models/buddy_protocol.dart';

/// 没有模型时的本地回答与下一步（06 第 5 章 R3 的兜底）。
///
/// 本地规则不读题，也不判断对错，因此它只做三件事：接住这次的问题，按问法
/// 给出一组可以自己执行的步骤，说明配置之前仍然可用的功能与配置之后从哪里
/// 继续回答。用户已经写下问题时，回答不转到待办或别的题目上。
///
/// [text] 是用户这次写下的话：讨论里没有题目记录，只能由调用方传进来；
/// [hasImages] 表示这次只发了图片，本地读不了图；[modelMissing] 为 false 时
/// 说明这次是调用失败，不写成“没有接模型”，以免和上一条失败提示对不上。
String localBuddyReply(
  BuddyContext context, {
  bool modelMissing = true,
  String text = '',
  bool hasImages = false,
}) {
  final asked = _askedText(context, text);
  if (asked.isNotEmpty) {
    return _replyForQuestion(context, asked, modelMissing: modelMissing);
  }
  if (hasImages) return _replyForImages(modelMissing: modelMissing);

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
    final prompt = modelMissing ? '本地建议：开始学习事项' : '可以开始学习事项';
    return '$prompt「${first.title}」。'
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
  return '写下本周目标，或提一个问题、贴一道题开始学习；'
      '本地规则会先给一组合用的步骤，配置模型之后再接着回答同一个问题。';
}

/// 一次提问的本地回答：先说问的是哪一句，再给步骤，最后说明现在能做什么、
/// 配置之后从哪里继续。
String _replyForQuestion(
  BuddyContext context,
  String asked, {
  required bool modelMissing,
}) {
  if (context.mode == BuddyMode.hint ||
      context.mode == BuddyMode.explain ||
      context.mode == BuddyMode.check) {
    return _replyForHelp(context, modelMissing: modelMissing);
  }
  final steps = _stepsFor(_shapeOf(asked));
  final opening = modelMissing
      ? '本地建议：你问的是「${_excerpt(asked)}」。当前没有配置模型，本地规则不读题，只能按问法给通用步骤。'
      : '本地建议：你问的是「${_excerpt(asked)}」。这次模型没有返回内容，本地规则不读题，只能按问法给通用步骤。';
  final lines = <String>[
    opening,
    '',
    for (var index = 0; index < steps.length; index++)
      '${index + 1}. ${steps[index]}',
    '',
    if (context.material != null && context.materialPage != null)
      '这次带入了《${context.material!.title}》${context.material!.position(context.materialPage!.pageNo)}，'
          '可以对照原文核对第二步。',
    if (modelMissing)
      '配置前可以记录题目与作答、查看材料原文、安排时间；配置后回到这条讨论，'
          '点「用模型重新回答」会接着回答同一个问题，不用重发。'
    else
      '问题已经保存，可以稍后再点一次「用模型重新回答」。',
  ];
  return lines.join('\n');
}

/// 学习中的提示、讲解与检查：本地给不了内容，只能给方向、次序和自查清单。
String _replyForHelp(BuddyContext context, {required bool modelMissing}) {
  final lines = <String>[];
  switch (context.mode) {
    case BuddyMode.hint:
      lines
        ..add('本地提示：这次没有可用的模型，本地不读题，只按问法给一个方向。')
        ..add('')
        ..add(
          '这道题可以先做一件事：写下已知条件与要求的量，'
          '再从材料里找一条能连接两者的定义或公式；连接不上时，把缺的那条条件记下来。',
        );
      break;
    case BuddyMode.explain:
      lines
        ..add(
          '本地讲解：这次没有可用的模型，本地给不出这道题的讲解，'
          '只能给一个自己讲下来的次序。',
        )
        ..add('')
        ..add('1. 用一句话写下这道题在问什么。')
        ..add('2. 写清已知条件、要求的量与可能用到的定义。')
        ..add('3. 一步一个理由往下写，每一步标出依据。')
        ..add('4. 回到材料或课本核对，把对不上的那一步记下来。');
      break;
    case BuddyMode.check:
      lines
        ..add('本地检查：这次没有可用的模型，本地没法核对做法，只能给一份自查清单。')
        ..add('')
        ..add('1. 题目的条件是否都用上，有没有漏掉或重复使用。')
        ..add('2. 每一步是否有依据，依据来自定义、公式还是材料原文。')
        ..add('3. 结果能否代回原题或用特例检验。')
        ..add('')
        ..add('三处里有对不上的，先把那一处改掉，再提交作答。');
      break;
    case BuddyMode.chat:
    case BuddyMode.plan:
      break;
  }
  final attempt = context.attempt;
  if (attempt != null && attempt.helps.isNotEmpty) {
    lines
      ..add('')
      ..add('这次已经用过 ${attempt.helps.length} 次应用内帮助，可以先独立写一步，再对照上一条。');
  }
  lines
    ..add('')
    ..add(
      modelMissing
          ? '配置模型后回到这道题，再点一次这个按钮，回答会结合当前题目与上一次尝试，不用重写题目。'
          : '这次调用没有成功，题目、作答和帮助都已保存，可以稍后再点一次。',
    );
  return lines.join('\n');
}

/// 只发了图片、又没有模型时的回答：图片已经保存，读图要等模型。
String _replyForImages({required bool modelMissing}) {
  if (!modelMissing) {
    return '图片已保存在本次讨论中，这次模型没有返回内容。'
        '可以稍后点「用模型重新回答」，或先写下已知条件与卡住的地方。';
  }
  return '图片已保存在本次讨论中。本地规则读不了图，可以先用文字写下这道题在问什么、'
      '已知哪些条件、卡在哪一步；配置模型后回到这条讨论，点「用模型重新回答」，'
      '会接着回答这张图对应的问题。';
}

/// 本地可给的一步：用户当次问的是具体问题时不另给建议，避免把话题转到
/// 已有的待办上；明确在问安排，或者没有当次问题时，才看今天的预约与待办。
List<NextStepDraft> localNextStep(BuddyContext context, {String text = ''}) {
  final asked = _askedText(context, text);
  if (asked.isNotEmpty && !_wantsPlan(asked)) return const [];
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
  final hasNumber = RegExp(r'\d').hasMatch(lower);
  if (has(_mathMarkers) ||
      (hasNumber && RegExp(r'[+\-×÷*/=<>^]').hasMatch(lower))) {
    return _QuestionShape.math;
  }
  if (has(_codeMarkers)) return _QuestionShape.code;
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

bool _wantsPlan(String text) {
  final lower = text.toLowerCase();
  return _planningMarkers.any(lower.contains);
}

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
  final runes = line.runes.toList(growable: false);
  if (runes.length <= limit) return line;
  return '${String.fromCharCodes(runes.take(limit))}…';
}
