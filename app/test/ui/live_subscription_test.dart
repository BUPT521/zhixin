import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/task_repository.dart';

import '../support/test_db.dart';

/// 订阅与写入在页面测试里互不等待（ADR-0014）。
///
/// 页面测试的写入发生在 `tester.runAsync` 的真异步区，重读若落进假异步区就要
/// 等下一次 pump，而排队的写入又等着这次重读结束。通知带上发出时的执行区，
/// 重读回到那里跑完，写入因此连续发几次也不会互等。
void main() {
  testWidgets('写入块里连续写入不会被订阅挡住', (tester) async {
    late TestRig rig;
    late TaskRepository tasks;
    await tester.runAsync(() async {
      rig = await openTestRig();
      tasks = TaskRepository(rig.db);
    });
    addTearDown(rig.close);

    final values = <int>[];
    final subscription = rig.db
        .watch(
          tables: const {'plan_item'},
          read: () async => (await tasks.items(openOnly: true)).length,
        )
        .listen(values.add);
    addTearDown(subscription.cancel);

    // 首读在页面构建所在的假异步区发起，先让它跑完。
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(values.isNotEmpty, isTrue);

    // 真异步区里连续写三次：每次提交都会触发一次重读。
    await tester.runAsync(() async {
      await tasks.createItem(title: '第一件');
      await tasks.createItem(title: '第二件');
      await tasks.createItem(title: '第三件');
    });
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(
      (await tester.runAsync(() => tasks.items(openOnly: true)))!.length,
      3,
    );
    expect(values.isNotEmpty, isTrue);
  });
}
