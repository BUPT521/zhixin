import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/study.dart';

import '../support/test_db.dart';

/// 跟随写入更新的读取（ADR-0014）：通知按提交里改到的表发送，提交之后才到达。
void main() {
  test('提交之后按表通知，订阅中的读取重跑一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final values = <List<String>>[];
    final subscription = rig.db
        .watch(
          tables: const {'plan_item'},
          read: () async => [
            for (final item in await tasks.items(openOnly: true)) item.title,
          ],
        )
        .listen(values.add);
    addTearDown(subscription.cancel);

    await _settle();
    expect(values, hasLength(1), reason: '订阅之后先读一次');
    expect(values.single, isEmpty);

    await tasks.createItem(title: '线性代数作业');
    await _settle();
    expect(values, hasLength(2), reason: '事项写入之后重读一次');
    expect(values.last, ['线性代数作业']);

    // 只改到目标，不碰事项：订阅事项的读取不重跑。
    await tasks.createGoal(title: '概率论期末');
    await _settle();
    expect(values, hasLength(2));

    await tasks.createItem(title: '概率论作业');
    await _settle();
    expect(values, hasLength(3));
    expect(values.last, containsAll(['线性代数作业', '概率论作业']));
  });

  test('回滚的命令不通知，没有净变化的写入也不通知', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final item = await tasks.createItem(title: '读一章');

    final values = <int>[];
    final subscription = rig.db
        .watch(
          tables: const {'plan_item'},
          read: () async => (await tasks.items(openOnly: true)).length,
        )
        .listen(values.add);
    addTearDown(subscription.cancel);
    await _settle();
    expect(values, [1]);

    await expectLater(
      rig.db.command(label: '回滚的写入', (txn) async {
        await tasks.createItem(
          title: '回滚的事项',
          transaction: WriteTransaction(txn, revisions: rig.engine),
        );
        throw StateError('回滚这次写入');
      }),
      throwsA(isA<StateError>()),
    );
    await _settle();
    expect(values, [1], reason: '回滚的写入没有形成提交，不通知');

    // 写成与现值相同的状态：采集到了行，但没有净变化，不形成提交。
    await rig.db.command(
      label: '写入相同值',
      (txn) => txn.execute('UPDATE plan_item SET status = ? WHERE id = ?', [
        PlanItemStatus.todo.value,
        item,
      ]),
    );
    await _settle();
    expect(values, [1], reason: '没有净变化时不通知');
  });

  test('换库之后按全部表补发一次，订阅中的页面在新库上重读', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final values = <int>[];
    final subscription = rig.db
        .watch(
          tables: const {'learning_goal'},
          read: () async => (await tasks.goals()).length,
        )
        .listen(values.add);
    addTearDown(subscription.cancel);
    await _settle();
    expect(values, [0]);

    await tasks.createGoal(title: '第二学期');
    await _settle();
    expect(values, [0, 1]);

    // 整库恢复与清空换掉连接之后由应用根调用它：全部表补发一次。
    rig.db.connectionReplaced();
    await _settle();
    expect(values, [0, 1, 1]);
  });

  test('多个订阅者各自重读，退订之后不再重跑', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final first = <int>[];
    final second = <int>[];
    final one = rig.db
        .watch(
          tables: const {'plan_item'},
          read: () async => (await tasks.items(openOnly: true)).length,
        )
        .listen(first.add);
    final two = rig.db
        .watch(
          tables: const {'plan_item'},
          read: () async => (await tasks.items(openOnly: true)).length,
        )
        .listen(second.add);
    addTearDown(one.cancel);
    addTearDown(two.cancel);
    await _settle();

    await tasks.createItem(title: '一起看');
    await _settle();
    expect(first, [0, 1]);
    expect(second, [0, 1]);

    await one.cancel();
    await tasks.createItem(title: '再看一次');
    await _settle();
    expect(first, [0, 1], reason: '退订之后的读取不再重跑');
    expect(second, [0, 1, 2]);
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
