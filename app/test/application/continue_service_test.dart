import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/continue_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

void main() {
  test('继续入口按最近一次学习统一排序，草稿取保存时间', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    DateTime clock() => now;
    final conversations = ConversationRepository(db, clock: clock);
    final attempts = AttemptRepository(db, clock: clock);
    final plans = StudyPlanRepository(db, clock: clock);
    final service = ContinueService(
      conversations: conversations,
      plans: plans,
      activity: _noActivity,
      runtime: testRuntime(policy: () => TimePolicy(clock: clock)),
    );

    final planId = await plans.createWithDrafts(
      title: '理解导数',
      drafts: const [
        StudyStepDraft(title: '从变化率理解导数', pageFrom: 1, pageTo: 2),
        StudyStepDraft(title: '求导法则', pageFrom: 3, pageTo: 4),
      ],
    );
    now = DateTime(2026, 11, 10, 10);
    final older = await conversations.create(title: '较早的讨论');
    await conversations.append(older, role: MessageRole.user, content: '较早的问题');

    now = DateTime(2026, 11, 10, 11);
    final draftId = await conversations.create(title: '条件概率');
    await conversations.append(
      draftId,
      role: MessageRole.user,
      content: '条件概率怎么算',
    );
    final attempt = await attempts.ensureOpenAttempt(draftId);
    now = DateTime(2026, 11, 10, 11, 30);
    await attempts.saveDraft(attempt.id, answer: '先写出 P(A|B)=P(AB)/P(B)');

    // 完成第一步会把进行中的步骤换成下一步，但计划行只在状态变化时才写：
    // 当前页不再存回计划行（审查 S5），所以计划的更新时间仍停留在建计划那一刻。
    now = DateTime(2026, 11, 10, 12);
    final firstStep = (await plans.steps(planId)).first;
    await plans.setStepStatus(firstStep.id, PlanItemStatus.done);
    expect((await plans.byId(planId))!.updatedAt, DateTime(2026, 11, 10, 9));

    final entries = await service.load();

    // 草稿那条讨论 11:00 建、11:30 存下草稿，排在 10:00 的“较早的讨论”之前；
    // 计划的更新时间停在建计划那一刻（09:00），排在最后。
    expect(entries.map((entry) => _label(entry)), [
      'draft',
      'discussion',
      'plan',
    ]);
    expect(entries.first.record!.draftSnippet, '先写出 P(A|B)=P(AB)/P(B)');
    expect(entries.first.record!.displayTitle, '条件概率');
    expect(entries[1].record!.lastUserMessage, '较早的问题');
    expect(entries[1].record!.preview, '较早的问题');
    expect(entries.last.plan!.nextStepTitle, '求导法则');
    expect(entries.last.plan!.currentPage, 3, reason: '未完成步骤的起始页');

    expect(await service.load(limit: 2), hasLength(2));
  });

  test('同一时间有草稿的题目排在计划与讨论之前', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 10, 12);
    DateTime clock() => now;
    final conversations = ConversationRepository(db, clock: clock);
    final plans = StudyPlanRepository(db, clock: clock);
    final service = ContinueService(
      conversations: conversations,
      plans: plans,
      activity: _noActivity,
      runtime: testRuntime(policy: () => TimePolicy(clock: clock)),
    );

    await plans.createWithDrafts(
      title: '理解导数',
      drafts: const [StudyStepDraft(title: '从变化率理解导数', pageFrom: 1)],
    );
    final discussion = await conversations.create(title: '一条讨论');
    await conversations.append(
      discussion,
      role: MessageRole.user,
      content: '一个问题',
    );
    final draft = await conversations.create(title: '一道题');
    await conversations.append(draft, role: MessageRole.user, content: '另一道题');
    await AttemptRepository(db, clock: clock).ensureOpenAttempt(draft);

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
    final conversations = ConversationRepository(db, clock: clock);
    final attempts = AttemptRepository(db, clock: clock);
    final plans = StudyPlanRepository(db, clock: clock);
    final service = ContinueService(
      conversations: conversations,
      plans: plans,
      activity: _noActivity,
      runtime: testRuntime(policy: () => TimePolicy(clock: clock)),
    );

    // 计划与讨论交替更新，另有较早的记录在最后写了草稿。
    for (var index = 0; index < 4; index++) {
      now = DateTime(2026, 11, 10, 8, index * 2);
      await plans.createWithDrafts(
        title: '计划 $index',
        drafts: const [StudyStepDraft(title: '第一步', pageFrom: 1)],
      );
      now = DateTime(2026, 11, 10, 9, index * 2);
      final id = await conversations.create(title: '讨论 $index');
      await conversations.append(
        id,
        role: MessageRole.user,
        content: '问题 $index',
      );
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

  test('订阅中的首页摘要在写入之后重读一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final now = DateTime(2026, 11, 10, 9);
    final conversations = ConversationRepository(rig.db);
    final plans = StudyPlanRepository(rig.db);
    final service = ContinueService(
      conversations: conversations,
      plans: plans,
      activity: _noActivity,
      runtime: testRuntime(
        policy: () => TimePolicy(clock: () => now),
        live: rig.db.live,
      ),
    );
    final homes = <NowHome>[];
    final subscription = service.watchHome().listen(homes.add);
    addTearDown(subscription.cancel);

    await _settle();
    expect(homes, hasLength(1), reason: '订阅之后先读一次');
    expect(homes.single.continueEntries, isEmpty);
    expect(homes.single.activity.isEmpty, isTrue);

    await conversations.create(title: '一条讨论');
    await _settle();
    expect(homes, hasLength(2), reason: '讨论写入之后重读一次');
    expect(homes.last.continueEntries.single.record!.title, '一条讨论');
  });
}

/// 首页活动摘要：这组用例只看继续入口，活动一律为空。
Future<NowActivity> _noActivity() async => const NowActivity();

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

String _label(ContinueEntry entry) {
  if (entry.isPlan) return 'plan';
  return entry.hasDraft ? 'draft' : 'discussion';
}
