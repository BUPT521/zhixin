import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/buddy_fallback.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/question.dart';
import 'package:zhixin/domain/models/study.dart';

BuddyContext _context({
  String? question,
  Attempt? attempt,
  List<PlanItem> openItems = const [],
  List<ScheduledItem> todayBlocks = const [],
  List<AttemptWithQuestion> recentAttempts = const [],
  List<Memory> memories = const [],
  Material? material,
  MaterialPage? materialPage,
  BuddyMode mode = BuddyMode.chat,
}) {
  return BuddyContext(
    now: DateTime(2026, 11, 10, 20),
    question: question == null ? null : Question(id: 1, stem: question),
    attempt: attempt,
    openItems: openItems,
    todayBlocks: todayBlocks,
    recentAttempts: recentAttempts,
    memories: memories,
    material: material,
    materialPage: materialPage,
    mode: mode,
  );
}

void main() {
  test('普通提问得到针对这句话的步骤，不推荐已有的学习事项', () {
    final reply = localBuddyReply(
      _context(openItems: [const PlanItem(id: 1, title: '第三章作业')]),
      text: '为什么这里需要独立性？',
    );

    expect(reply, contains('为什么这里需要独立性'));
    expect(reply, contains('用自己的话写下这个问题在问什么'));
    // 用户刚提出问题时不把话题转到待办上。
    expect(reply, isNot(contains('第三章作业')));
    expect(reply, isNot(contains('开始学习事项')));
  });

  test('数学题给出整理条件、核对公式与检验结果三步', () {
    final reply = localBuddyReply(_context(), text: '解方程 3x+2=8，求 x');

    expect(reply, contains('3x+2=8'));
    expect(reply, contains('已知量和要求的量'));
    expect(reply, contains('公式或定义'));
    expect(reply, contains('检验'));
  });

  test('代码报错、英语句子与安排问题各给对应的步骤', () {
    final code = localBuddyReply(_context(), text: '这段代码为什么报错？');
    expect(code, contains('报错首行'));
    expect(code, contains('类型与形状'));

    final language = localBuddyReply(_context(), text: '这句话怎么翻译？');
    expect(language, contains('主语、谓语'));
    expect(language, contains('词性'));

    final planning = localBuddyReply(_context(), text: '接下来复习什么？');
    expect(planning, contains('二十分钟'));
    expect(planning, contains('结束条件'));
  });

  test('回答里说明配置前能做什么、配置后从哪里继续', () {
    final reply = localBuddyReply(_context(), text: '这道题怎么想？');

    expect(reply, contains('配置前可以记录题目与作答'));
    expect(reply, contains('用模型重新回答'));
    expect(reply, contains('不用重发'));
  });

  test('调用失败时不写成没有配置模型', () {
    final failed = localBuddyReply(
      _context(),
      text: '这道题怎么想？',
      modelMissing: false,
    );
    expect(failed, contains('这次模型没有返回内容'));
    expect(failed, isNot(contains('现在没有配置模型')));
    expect(failed, contains('可以稍后再点一次'));
  });

  test('只发了图片时说明本地读不了图，并给出用文字写条件的做法', () {
    final reply = localBuddyReply(_context(), hasImages: true);

    expect(reply, contains('图片已保存在本次讨论中'));
    expect(reply, contains('读不了图'));
    expect(reply, contains('已知哪些条件'));
  });

  test('带入材料页时按页码提示核对原文', () {
    final reply = localBuddyReply(
      _context(
        material: const Material(id: 7, title: '概率论课件'),
        materialPage: const MaterialPage(
          id: 1,
          materialId: 7,
          pageNo: 12,
          content: '条件概率的定义是 P(A|B)=P(AB)/P(B)。',
        ),
      ),
      text: '条件概率怎么算',
    );

    expect(reply, contains('《概率论课件》第 12 页'));
  });

  test('学习中的提示、讲解与检查各有本地说法，并给出配置后的入口', () {
    final hint = localBuddyReply(
      _context(question: '求条件概率', mode: BuddyMode.hint),
    );
    expect(hint, contains('本地提示'));
    expect(hint, contains('配置模型后回到这道题'));

    final explain = localBuddyReply(
      _context(question: '求条件概率', mode: BuddyMode.explain),
    );
    expect(explain, contains('本地讲解'));
    expect(explain, contains('自己讲下来的次序'));

    final check = localBuddyReply(
      _context(question: '求条件概率', mode: BuddyMode.check),
    );
    expect(check, contains('本地检查'));
    expect(check, contains('自查清单'));
  });

  test('用过的帮助次数会写进本地提示', () {
    final attempt = Attempt(
      id: 3,
      conversationId: 1,
      helps: [
        HelpEntry(kind: 'hint', content: '先写条件', at: DateTime(2026, 11, 10)),
      ],
    );
    final reply = localBuddyReply(
      _context(question: '求条件概率', attempt: attempt, mode: BuddyMode.hint),
    );
    expect(reply, contains('已经用过 1 次应用内帮助'));
  });

  test('待办与最近没做对的题仍然给本地建议，标明来源', () {
    final item = localBuddyReply(
      _context(openItems: [const PlanItem(id: 1, title: '第三章作业')]),
    );
    expect(item, contains('本地建议：开始学习事项「第三章作业」'));

    final attempt = localBuddyReply(
      _context(
        recentAttempts: [
          AttemptWithQuestion(
            attempt: Attempt(
              id: 2,
              conversationId: 9,
              isCorrect: false,
              submittedAt: DateTime(2026, 11, 9),
            ),
            question: const Question(id: 9, stem: '第 8 题求条件概率'),
          ),
        ],
      ),
    );
    expect(attempt, contains('第 8 题求条件概率'));
    expect(attempt, contains('当时自评有误'));
  });

  test('下一步建议只在问安排或没有当次问题时给，不转到已有待办上', () {
    final question = localNextStep(_context(), text: '解方程 3x+2=8，求 x');
    expect(question, isEmpty);

    final todayBlock = ScheduledItem(
      block: ScheduleBlock(
        id: 1,
        planItemId: 5,
        startAt: DateTime(2026, 11, 10, 20),
        endAt: DateTime(2026, 11, 10, 20, 30),
      ),
      itemTitle: '第三章作业',
      itemNote: '做完第 3 节',
    );
    final plan = localNextStep(
      _context(openItems: [const PlanItem(id: 5, title: '第三章作业')]),
      text: '接下来做什么',
    );
    expect(plan.single.title, '第三章作业');

    final withoutPlan = localNextStep(_context(), text: '接下来做什么');
    expect(withoutPlan, isEmpty);

    final withBlock = localNextStep(
      _context(
        todayBlocks: [todayBlock],
        openItems: [const PlanItem(id: 5, title: '第三章作业')],
      ),
      text: '接下来做什么',
    );
    expect(withBlock.single.title, '第三章作业');
    expect(withBlock.single.minutes, 30);
  });

  test('用户问的是具体问题时，本地不另推已有的待办', () {
    final steps = localNextStep(
      _context(
        openItems: [const PlanItem(id: 5, title: '第三章作业')],
        todayBlocks: [
          ScheduledItem(
            block: ScheduleBlock(
              id: 2,
              planItemId: 5,
              startAt: DateTime(2026, 11, 10, 20),
              endAt: DateTime(2026, 11, 10, 20, 30),
            ),
            itemTitle: '第三章作业',
          ),
        ],
      ),
      text: '为什么这里需要独立性？',
    );
    expect(steps, isEmpty);
  });

  test('没有当次文字问题时，仍按当天预约与待办给建议', () {
    final step = localNextStep(
      _context(openItems: [const PlanItem(id: 5, title: '第三章作业')]),
    );
    expect(step.single.title, '第三章作业');
  });
}
