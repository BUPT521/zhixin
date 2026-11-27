// 数据版本对照 git 的改进方案（G1、G2、G3）的验收用例。
//
// 这批用例在阶段 1（提交身份、按格变基、维护列合并规则）落地之前应当失败；
// 每条断言都给出期望值与当前实际值，失败信息里能直接看出是哪一类问题。
// 用例只依赖对外行为，不依赖 `syncRequestIdFor`、`_pulledOverwrites` 这类
// 马上要改掉的内部实现。

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/plan_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/study_plan_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/fake_server.dart';
import '../support/service_runtime.dart';
import '../support/sync_rig.dart';
import '../support/test_db.dart';

void main() {
  late FakeServer server;
  late TestClock clock;
  final devices = <SyncDevice>[];

  setUp(() {
    server = FakeServer();
    clock = TestClock();
    devices.clear();
  });

  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
  });

  Future<SyncDevice> device(
    String email, {
    bool register = false,
    required String deviceId,
    bool undoRules = false,
  }) async {
    final rig = undoRules
        ? await openTestRigWithUndoRules(clock: clock.call)
        : await openTestRig(clock: clock.call);
    final opened = await openSyncDevice(
      server,
      rig: rig,
      email: email,
      register: register,
      deviceId: deviceId,
      clock: clock,
    );
    devices.add(opened);
    return opened;
  }

  /// 两台设备同步到同一条记忆：A 上传基线，B 首次同步拉取之后，A 再同步一次
  /// 消化掉 B 首次同步上传的基线，后面只比较两边各自改过的内容。
  Future<(SyncDevice, SyncDevice)> devicesWithMemory(
    String content, {
    bool undoRules = false,
  }) async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
      undoRules: undoRules,
    );
    await insertTestMemory(a.rig, 'm1', content: content);
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device(
      'a@example.com',
      deviceId: 'device-b',
      undoRules: undoRules,
    );
    await b.sync.syncNow();
    await a.sync.syncNow();
    return (a, b);
  }

  test('同参数“暂停 → 恢复 → 暂停”之后目标仍处于暂停（G1①）', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    final tasks = TaskRepository(a.rig.db);
    final plans = PlanService(
      tasks: tasks,
      runtime: testRuntime(policy: () => TimePolicy(clock: clock.call)),
      studyPlans: StudyPlanRepository(a.rig.db),
      transactions: WriteTransactions(a.rig.db, revisions: a.rig.engine),
    );

    final created = await plans.addGoal(title: '概率论期末');
    expect(created.changed, isTrue, reason: '准备阶段：新建目标应当形成一条提交');
    final goals = await tasks.goals();
    expect(goals, hasLength(1), reason: '准备阶段：本机应当只有一个目标');
    final goalId = goals.single.id;
    expect(
      (await tasks.goalById(goalId))!.status,
      LearningGoalStatus.active,
      reason: '新建的目标默认进行中',
    );

    await plans.pauseGoal(goalId);
    expect(
      (await tasks.goalById(goalId))!.status,
      LearningGoalStatus.paused,
      reason: '准备阶段：第一次暂停应当生效',
    );

    await plans.resumeGoal(goalId);
    expect(
      (await tasks.goalById(goalId))!.status,
      LearningGoalStatus.active,
      reason: '准备阶段：恢复应当生效',
    );

    // 用户隔了一会儿再点一次暂停：动作与参数和第一次完全相同，但这是一次新
    // 的用户动作，不是网络回调或双击造成的重试。
    clock.advance(const Duration(minutes: 3));
    final headBefore = await a.rig.engine.headId(a.rig.raw);
    final again = await plans.pauseGoal(goalId);
    final status = (await tasks.goalById(goalId))!.status;
    expect(
      status,
      LearningGoalStatus.paused,
      reason:
          '同参数的第二次暂停被当成重试丢掉了：期望 paused，实际 ${status.value}；'
          '这次调用返回 changed=${again.changed}、commitId=${again.commitId}',
    );
    expect(
      await a.rig.engine.headId(a.rig.raw),
      greaterThan(headBefore),
      reason: '第二次暂停应当形成一条新的本机提交',
    );
  });

  test('撤销后重做同一动作，另一台设备同步后能看到重做（G1②）', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
      undoRules: true,
    );
    await a.sync.syncNow(confirmBaseline: true);
    final userId = (await a.account.snapshot()).session!.userId;
    final headAfterBaseline = server.headOf(userId);

    // 写入走与界面同一条命令路径，记忆行按列写，便于在同一个命令里固定标识。
    int firstCommit = 0;
    await a.rig.db.command((txn) async {
      await insertRow(txn, 'memory', {
        'id': 'm-redo',
        'kind': 'semantic',
        'content': 'prefer-examples',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-17 10:00:00',
        'updated_at': '2026-11-17 10:00:00',
      });
    }, label: '新增记忆');
    firstCommit = await a.rig.engine.headId(a.rig.raw);
    await a.sync.syncNow();
    expect(
      server.headOf(userId),
      headAfterBaseline + 1,
      reason: '准备阶段：新增记忆推上去之后服务端应当多一条提交',
    );

    final undone = await a.rig.revisions.undoCommit(firstCommit);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await testMemories(a.rig), isEmpty, reason: '准备阶段：撤销之后本机没有这条记忆');

    // 用户过一会儿又加了一条一模一样的内容：这是一个新的用户动作，界面上另起
    // 一个 uid，不是上一次动作的重试（ADR-0053 决定第 3 条）。
    clock.advance(const Duration(minutes: 3));
    await a.rig.db.command(
      (txn) => insertRow(txn, 'memory', {
        'id': 'm-redo',
        'kind': 'semantic',
        'content': 'prefer-examples',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-17 10:03:00',
        'updated_at': '2026-11-17 10:03:00',
      }),
      label: '新增记忆',
    );
    expect(await testMemories(a.rig), hasLength(1), reason: '准备阶段：重做之后本机有一条记忆');

    await a.sync.syncNow();

    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    final contents = [
      for (final row in await testMemories(b.rig)) row['content'],
    ];
    expect(
      contents,
      contains('prefer-examples'),
      reason:
          '撤销后重做同一条记忆，另一台设备没有看到：期望含有 prefer-examples，'
          '实际 $contents（服务端序列 ${serverActions(server, userId)}）',
    );
  });

  test('两台设备改同一行的不同列，双向同步后各自的新值都在且没有 updated_at 噪音冲突'
      '（G2②/G3）', () async {
    final (a, b) = await devicesWithMemory('喜欢先看例子');

    // A 只改内容，B 只改状态；两边都会顺带改到 updated_at。
    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    }, label: '修改记忆内容');
    await updateTestMemory(b.rig, 'm1', {
      'status': 'deleted',
      'updated_at': '2026-11-17 10:06:00',
    }, label: '修改记忆状态');

    await b.sync.syncNow();
    await a.sync.syncNow();
    await b.sync.syncNow();

    final aRow = (await testMemory(a.rig, 'm1'))!;
    final bRow = (await testMemory(b.rig, 'm1'))!;
    expect(
      bRow['content'],
      'A 的新内容',
      reason:
          'B 没有收到 A 改的内容：期望 “A 的新内容”，实际 ${bRow['content']}；'
          '两边状态 A=${aRow['status']}、B=${bRow['status']}',
    );
    expect(
      aRow['status'],
      'deleted',
      reason: 'A 没有收到 B 改的状态：期望 deleted，实际 ${aRow['status']}',
    );
    expect(
      aRow['content'],
      'A 的新内容',
      reason: 'A 本机的内容应当保持自己写的新值，实际 ${aRow['content']}',
    );
    expect(
      bRow['status'],
      'deleted',
      reason: 'B 本机的状态应当保持自己写的新值，实际 ${bRow['status']}',
    );

    // updated_at 是维护列：两边各自写了一次，它不应当成为用户看不懂的冲突。
    final aNoise = [
      for (final conflict in await a.rig.revisions.conflicts())
        if (conflict.column == 'updated_at') conflict.reason,
    ];
    final bNoise = [
      for (final conflict in await b.rig.revisions.conflicts())
        if (conflict.column == 'updated_at') conflict.reason,
    ];
    expect(aNoise, isEmpty, reason: 'A 上出现了 updated_at 的冲突噪音：$aNoise');
    expect(bNoise, isEmpty, reason: 'B 上出现了 updated_at 的冲突噪音：$bNoise');
  });

  test('一条提交同时改两行，其中一行被远端覆盖时另一行仍能推到另一台设备（G2①）', () async {
    final a = await device(
      'a@example.com',
      register: true,
      deviceId: 'device-a',
    );
    await insertTestMemory(a.rig, 'm1', content: '第一条');
    await insertTestMemory(a.rig, 'm2', content: '第二条');
    await a.sync.syncNow(confirmBaseline: true);
    final b = await device('a@example.com', deviceId: 'device-b');
    await b.sync.syncNow();
    await a.sync.syncNow();

    await updateTestMemory(b.rig, 'm1', {
      'content': 'B 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    }, label: '修改记忆');
    await b.sync.syncNow();

    // A 一条提交同时改两行：m1 会被远端提交覆盖，m2 只有本机改过。
    await a.rig.db.command((txn) async {
      await updateRow(
        txn,
        'memory',
        {'content': 'A 改的 m1', 'updated_at': '2026-11-17 10:06:00'},
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      await updateRow(
        txn,
        'memory',
        {'content': 'A 改的 m2', 'updated_at': '2026-11-17 10:06:00'},
        where: 'id = ?',
        whereArgs: ['m2'],
      );
    }, label: '一次改两条记忆');

    await a.sync.syncNow();
    await b.sync.syncNow();

    final bM2 = (await testMemory(b.rig, 'm2'))!;
    expect(
      bM2['content'],
      'A 改的 m2',
      reason:
          '同一条提交里没有被覆盖的另一行没有推过去：期望 “A 改的 m2”，'
          '实际 ${bM2['content']}',
    );
    final bM1 = (await testMemory(b.rig, 'm1'))!;
    expect(
      bM1['content'],
      'B 的新内容',
      reason: '被远端覆盖的那一行应当保留远端值，实际 ${bM1['content']}',
    );
    expect(
      (await testMemory(a.rig, 'm2'))!['content'],
      'A 改的 m2',
      reason: 'A 本机没有被覆盖的那一行应当保持自己写的新值',
    );
  });

  test('拉取成功、推送失败之后，下一轮同步不把被覆盖的旧值推回服务端（G2④）', () async {
    final (a, b) = await devicesWithMemory('喜欢先看例子');
    final userId = (await a.account.snapshot()).session!.userId;

    await updateTestMemory(b.rig, 'm1', {
      'content': 'B 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    }, label: '修改记忆');
    await b.sync.syncNow();

    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 的旧值',
      'updated_at': '2026-11-17 10:06:00',
    }, label: '修改记忆');
    // 另一条不受远端覆盖的写入：这一轮会真的发出推送请求，才能让它失败。
    await insertTestMemory(
      a.rig,
      'm2',
      content: 'A 新增的一行',
      timestamp: '2026-11-17 10:06:00',
    );
    final headBefore = server.headOf(userId);

    // 这一轮拉取成功、推送失败：被覆盖的旧值只在内存里记着，同步还没收尾。
    server.pushFailures = 1;
    await expectLater(
      a.sync.syncNow(),
      throwsA(
        isA<ServerProblem>().having(
          (error) => error.code,
          'code',
          'unavailable',
        ),
      ),
      reason: '准备阶段：这一轮应当拉取成功、推送失败',
    );
    expect(
      await testMemoryContent(a.rig, 'm1'),
      'B 的新内容',
      reason: '准备阶段：A 本机的旧值已经被远端值覆盖',
    );
    expect(server.headOf(userId), headBefore, reason: '准备阶段：推送失败时服务端序列没有前进');

    // 下一轮同步：被覆盖的旧提交不能再推一次。
    await a.sync.syncNow();
    await b.sync.syncNow();
    final bRow = (await testMemory(b.rig, 'm1'))!;
    expect(
      bRow['content'],
      'B 的新内容',
      reason:
          '被覆盖的旧值在下一轮又被推回服务端：B 看到 ${bRow['content']}，'
          '期望 “B 的新内容”（服务端序列 ${serverActions(server, userId)}）',
    );
    expect(
      await testMemoryContent(a.rig, 'm1'),
      'B 的新内容',
      reason: 'A 本机应当保持远端值，实际 ${await testMemoryContent(a.rig, 'm1')}',
    );
  });

  test('同步过程中新写入的修改照常推送（G2③）', () async {
    final (a, b) = await devicesWithMemory('喜欢先看例子');
    final userId = (await a.account.snapshot()).session!.userId;

    await updateTestMemory(b.rig, 'm1', {
      'content': 'B 的新内容',
      'updated_at': '2026-11-17 10:05:00',
    }, label: '修改记忆');
    await b.sync.syncNow();

    // A 在拉取之前也改过这一行：拉取会把本机值覆盖掉。
    await updateTestMemory(a.rig, 'm1', {
      'content': 'A 的旧值',
      'updated_at': '2026-11-17 10:06:00',
    }, label: '修改记忆');

    // 拉取已经应用、推送还没开始算的时候，用户又改了一次：这条提交是同步过程
    // 中新产生的，不能因为同一个格子刚被远端覆盖而被跳过。
    var pulled = false;
    server.onPull = () async {
      pulled = true;
    };
    server.onHead = () async {
      if (!pulled) return;
      pulled = false;
      await updateTestMemory(a.rig, 'm1', {
        'content': 'A 在同步途中改的值',
        'updated_at': '2026-11-17 10:07:00',
      }, label: '同步途中修改记忆');
    };

    final result = await a.sync.syncNow();
    expect(result.pulledCommits, 1, reason: '准备阶段：这一轮应当拉到 B 的一条提交');

    await b.sync.syncNow();
    final bRow = (await testMemory(b.rig, 'm1'))!;
    expect(
      bRow['content'],
      'A 在同步途中改的值',
      reason:
          '同步途中新写入的修改被跳过了：B 看到 ${bRow['content']}，'
          '期望 “A 在同步途中改的值”（服务端序列 ${serverActions(server, userId)}）',
    );
  });
}
