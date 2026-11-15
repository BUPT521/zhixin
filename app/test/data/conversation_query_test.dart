import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';

import '../support/test_db.dart';

void main() {
  test('记录列表按页读取，翻页不重复也不漏行', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    final conversations = ConversationRepository(db, clock: () => now);
    final ids = <int>[];
    for (var index = 0; index < 5; index++) {
      now = DateTime(2026, 11, 10, 9, index);
      final id = await conversations.create(title: '第 $index 条');
      await conversations.append(id, role: 'user', content: '问题 $index');
      ids.add(id);
    }

    final first = await conversations.list(limit: 2);
    final second = await conversations.list(limit: 2, offset: 2);

    expect(first.map((record) => record.id), ids.reversed.take(2));
    expect(second.map((record) => record.id), ids.reversed.skip(2).take(2));
    expect(
      first
          .map((record) => record.id)
          .toSet()
          .intersection(second.map((record) => record.id).toSet()),
      isEmpty,
    );
  });

  test('作答状态在查询里筛选，口径与题目视图一致', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    final conversations = ConversationRepository(db, clock: () => now);
    final attempts = AttemptRepository(db, clock: () => now);

    Future<int> record(String title) async {
      now = now.add(const Duration(minutes: 1));
      final id = await conversations.create(title: title);
      await conversations.append(id, role: 'user', content: title);
      return id;
    }

    final correct = await record('做对的题');
    final correctAttempt = await attempts.ensureOpenAttempt(correct);
    await attempts.submit(
      correctAttempt.id,
      answer: '对',
      isCorrect: true,
      independent: true,
    );

    final wrong = await record('做错的题');
    final wrongAttempt = await attempts.ensureOpenAttempt(wrong);
    await attempts.submit(
      wrongAttempt.id,
      answer: '错',
      isCorrect: false,
      independent: false,
    );

    final draft = await record('只有草稿的题');
    final draftAttempt = await attempts.ensureOpenAttempt(draft);
    await attempts.saveDraft(draftAttempt.id, answer: '写了一半');

    final discussion = await record('只有讨论');

    Future<Set<int>> ids(String status) async => {
      for (final record in await conversations.list(answerStatus: status))
        record.id,
    };

    expect(await ids('correct'), {correct});
    expect(await ids('wrong'), {wrong});
    expect(await ids('unjudged'), isEmpty);
    // 有作答记录、还没提交的算未作答；没有作答记录的讨论不在题目视图里。
    expect(await ids('open'), {draft});
    expect((await conversations.list()).map((record) => record.id).toSet(), {
      correct,
      wrong,
      draft,
      discussion,
    });
  });

  test('题目视图只读指定记录', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    final conversations = ConversationRepository(db, clock: () => now);
    final attempts = AttemptRepository(db, clock: () => now);

    final kept = <int>[];
    for (var index = 0; index < 3; index++) {
      now = DateTime(2026, 11, 10, 9, index);
      final id = await conversations.create(title: '第 $index 条');
      await conversations.append(id, role: 'user', content: '问题 $index');
      await attempts.ensureOpenAttempt(id);
      kept.add(id);
    }

    final rows = await conversations.questionRows(
      conversationIds: [kept[0], kept[2]],
    );

    expect(rows.map((row) => row.question.id).toSet(), {kept[0], kept[2]});
    expect(
      await conversations.questionRows(conversationIds: const []),
      isEmpty,
    );
  });

  test('继续入口的候选只读前几条，刚写下的草稿仍然排在最前', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var now = DateTime(2026, 11, 10, 9);
    final conversations = ConversationRepository(db, clock: () => now);
    final attempts = AttemptRepository(db, clock: () => now);

    final ids = <int>[];
    for (var index = 0; index < 6; index++) {
      now = DateTime(2026, 11, 10, 9, index);
      final id = await conversations.create(title: '第 $index 条');
      await conversations.append(id, role: 'user', content: '问题 $index');
      ids.add(id);
    }
    // 最早的一条写草稿：它的记录更新时间最旧，但最近一次学习行为最新。
    final oldest = await attempts.ensureOpenAttempt(ids.first);
    now = DateTime(2026, 11, 10, 12);
    await attempts.saveDraft(oldest.id, answer: '先写了两步');

    final recent = await conversations.listRecentlyActive(limit: 2);

    expect(recent.map((record) => record.id), [ids.first, ids.last]);
  });
}
