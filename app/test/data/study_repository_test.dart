import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/study_repository.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/repository/task_repository.dart';

import '../support/test_db.dart';

void main() {
  test('未结束场次只在相同目标范围内复用', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final study = StudyRepository(db.rawDb);
    final goalA = await tasks.createGoal(title: '目标 A');
    final goalB = await tasks.createGoal(title: '目标 B');

    final sessionA = await study.start(goalId: goalA);
    final sessionB = await study.openFor(goalId: goalB);
    expect(sessionB, isNull);

    final sessionForA = await study.openFor(goalId: goalA);
    expect(sessionForA!.id, sessionA.id);
    expect(await study.openFor(), isNull);
  });

  test('学习步骤取最近一次结束的场次', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db.rawDb);
    final study = StudyRepository(db.rawDb);
    final stepId = await tasks.createItem(title: '第 1 步');

    final first = await study.start(planItemId: stepId);
    await study.end(first.id, outcome: 'not_done', summary: '先做了一半');
    final second = await study.start(planItemId: stepId);
    await study.end(second.id, outcome: 'done', summary: '这次独立完成');

    final latest = await study.latestEndedByPlanItem([stepId]);
    expect(latest[stepId]!.id, second.id);
    expect(latest[stepId]!.outcomeLabel, '完成');
    expect(latest[stepId]!.summary, '这次独立完成');
    expect(await study.latestEndedByPlanItem([]), isEmpty);
  });
}
