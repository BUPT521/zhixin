import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/continue_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';

import '../support/test_db.dart';

void main() {
  test('继续入口按最近一次学习统一排序，草稿取保存时间', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    DateTime clock() => now;
    final conversations = ConversationRepository(db.rawDb, clock: clock);
    final attempts = AttemptRepository(db.rawDb, clock: clock);
    final plans = StudyPlanRepository(db.rawDb, clock: clock);
    final service = ContinueService(conversations: conversations, plans: plans);

    final planId = await plans.createWithDrafts(
      title: '理解导数',
      drafts: const [
        StudyStepDraft(title: '从变化率理解导数', pageFrom: 1, pageTo: 2),
        StudyStepDraft(title: '求导法则', pageFrom: 3, pageTo: 4),
      ],
    );
    now = DateTime(2026, 11, 10, 10);
    final older = await conversations.create(title: '较早的讨论');
    await conversations.append(older, role: 'user', content: '较早的问题');

    now = DateTime(2026, 11, 10, 11);
    final draftId = await conversations.create(title: '条件概率');
    await conversations.append(draftId, role: 'user', content: '条件概率怎么算');
    final attempt = await attempts.ensureOpenAttempt(draftId);
    now = DateTime(2026, 11, 10, 11, 30);
    await attempts.saveDraft(attempt.id, answer: '先写出 P(A|B)=P(AB)/P(B)');

    // 完成第一步会让计划的继续位置与更新时间都向前推进。
    now = DateTime(2026, 11, 10, 12);
    final firstStep = (await plans.steps(planId)).first;
    await plans.setStepStatus(firstStep.id, PlanItemStatus.done);

    final entries = await service.load();

    expect(entries.map((entry) => _label(entry)), [
      'plan',
      'draft',
      'discussion',
    ]);
    expect(entries.first.plan!.nextStepTitle, '求导法则');
    expect(entries[1].record!.draftSnippet, '先写出 P(A|B)=P(AB)/P(B)');
    expect(entries[1].lastActiveAt, DateTime(2026, 11, 10, 11, 30));
    expect(entries[2].record!.lastUserMessage, '较早的问题');
    expect(entries[2].record!.preview, '较早的问题');

    expect(await service.load(limit: 2), hasLength(2));
  });

  test('同一时间有草稿的题目排在计划与讨论之前', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 10, 12);
    DateTime clock() => now;
    final conversations = ConversationRepository(db.rawDb, clock: clock);
    final plans = StudyPlanRepository(db.rawDb, clock: clock);
    final service = ContinueService(conversations: conversations, plans: plans);

    await plans.createWithDrafts(
      title: '理解导数',
      drafts: const [StudyStepDraft(title: '从变化率理解导数', pageFrom: 1)],
    );
    final discussion = await conversations.create(title: '一条讨论');
    await conversations.append(discussion, role: 'user', content: '一个问题');
    final draft = await conversations.create(title: '一道题');
    await conversations.append(draft, role: 'user', content: '另一道题');
    await AttemptRepository(db.rawDb, clock: clock).ensureOpenAttempt(draft);

    final entries = await service.load();

    expect(entries.map((entry) => _label(entry)), [
      'draft',
      'plan',
      'discussion',
    ]);
  });

  test('只读前几条与读全库再排序得到同一份结果', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 8);
    DateTime clock() => now;
    final conversations = ConversationRepository(db.rawDb, clock: clock);
    final attempts = AttemptRepository(db.rawDb, clock: clock);
    final plans = StudyPlanRepository(db.rawDb, clock: clock);
    final service = ContinueService(conversations: conversations, plans: plans);

    // 计划与讨论交替更新，另有较早的记录在最后写了草稿。
    for (var index = 0; index < 4; index++) {
      now = DateTime(2026, 11, 10, 8, index * 2);
      await plans.createWithDrafts(
        title: '计划 $index',
        drafts: const [StudyStepDraft(title: '第一步', pageFrom: 1)],
      );
      now = DateTime(2026, 11, 10, 9, index * 2);
      final id = await conversations.create(title: '讨论 $index');
      await conversations.append(id, role: 'user', content: '问题 $index');
      if (index == 0) {
        final attempt = await attempts.ensureOpenAttempt(id);
        now = DateTime(2026, 11, 10, 13);
        await attempts.saveDraft(attempt.id, answer: '草稿写在这里');
      }
    }

    final all = await service.load(limit: 20);
    final head = await service.load(limit: 3);

    expect(all.length, greaterThan(3));
    expect(
      head.map((entry) => entry.isPlan ? 'plan' : 'record').toList(),
      all.take(3).map((entry) => entry.isPlan ? 'plan' : 'record').toList(),
    );
  });
}

String _label(ContinueEntry entry) {
  if (entry.isPlan) return 'plan';
  return entry.hasDraft ? 'draft' : 'discussion';
}
