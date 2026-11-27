import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_usage_service.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/domain/rules/revision_actions.dart';
import 'package:zhixin/domain/models/revision_models.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/uuid_v5.dart';
import 'package:zhixin/domain/rules/uuid_v7.dart';

import '../support/test_db.dart';

/// UUIDv5 文本：版本位固定 5，变体位落在 10xx。
final RegExp _uuidV5Text = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// 一台设备上的记忆使用统计：设备编号固定，写入与冲刷都走生产路径。
class _Device {
  _Device(this.rig, {this.deviceId = 'device-a', DateTime? now})
    : now = now ?? DateTime(2026, 11, 12, 10) {
    service = MemoryUsageService(
      db: rig.db,
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      deviceIdSource: () async => deviceId,
      clock: () => this.now,
    );
    memories = MemoryRepository(rig.db, clock: () => this.now);
  }

  final TestRig rig;
  final String deviceId;
  DateTime now;
  late final MemoryUsageService service;
  late final MemoryRepository memories;

  Future<String> memory(String content, {MemoryKind? kind}) => memories.create(
    id: newUuidV7(),
    kind: kind ?? MemoryKind.semantic,
    content: content,
  );

  Future<List<Map<String, Object?>>> usageRows() =>
      selectRows(rig.raw, 'memory_usage');

  Future<List<Map<String, Object?>>> bufferRows() =>
      selectRows(rig.raw, 'local_memory_use');

  Future<int> commitCount() async =>
      (await selectRows(rig.raw, 'revision_commit')).length;

  Future<int> headId() => rig.engine.headId(rig.raw);
}

void main() {
  test('召回与主动搜索只写本机缓冲，不形成提交也不推进 HEAD', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    final head = await device.headId();
    final commits = await device.commitCount();

    device.service.noteRecall(id);
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final buffer = await device.bufferRows();
    expect(buffer, hasLength(2));
    expect(
      buffer.map((row) => row['kind']),
      unorderedEquals(['recall', 'search']),
    );
    expect(buffer.map((row) => row['memory_id']), everyElement(id));
    expect(
      buffer.map((row) => row['used_at']),
      everyElement('2026-11-12 10:00:00'),
      reason: '同一秒的连续使用各记一行，时刻不必错开',
    );
    // 缓冲只是本机的簿记，不进 memory_usage。
    expect(await device.usageRows(), isEmpty);
    expect(await device.headId(), head, reason: '召回不推进 HEAD');
    expect(await device.commitCount(), commits, reason: '召回不形成提交');
  });

  test('冲刷把缓冲汇总成一条 maintenance 提交并清空缓冲', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');

    device.service.noteRecall(id);
    device.service.noteRecall(id);
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final commitsBefore = await device.commitCount();

    device.now = device.now.add(const Duration(minutes: 5));
    expect(await device.service.flush(), isTrue);

    final rows = await device.usageRows();
    expect(rows, hasLength(1));
    expect(rows.single['memory_id'], id);
    expect(rows.single['device_id'], 'device-a');
    expect(rows.single['recall_count'], 2);
    expect(rows.single['search_count'], 1);
    expect(rows.single['last_recalled_at'], '2026-11-12 10:00:00');
    expect(rows.single['last_searched_at'], '2026-11-12 10:00:00');
    expect(rows.single['updated_at'], '2026-11-12 10:05:00');
    expect(await device.bufferRows(), isEmpty, reason: '汇总与清空在同一个事务里');

    // 冲刷只形成一条提交：类型 maintenance，行为者 system。
    expect(await device.commitCount(), commitsBefore + 1);
    final commit = await rig.engine.commitById(rig.raw, await device.headId());
    expect(commit, isNotNull);
    expect(commit!.kind, RevisionKind.maintenance);
    expect(commit.actor, 'system');
    expect(commit.action, flushMemoryUsageAction);
  });

  test('重复冲刷不重复计数，也不再多形成提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.service.flush(), isTrue);
    final head = await device.headId();

    // 没有新的缓冲行：不再写库，也不形成提交。
    expect(await device.service.flush(), isFalse);
    var rows = await device.usageRows();
    expect(rows.single['recall_count'], 1);
    expect(await device.headId(), head, reason: '没有可汇总的记录时不形成提交');

    // 再记一次搜索并冲刷：只在原计数上加一，重复冲刷不重复累加。
    device.now = device.now.add(const Duration(hours: 1));
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.service.flush(), isTrue);
    rows = await device.usageRows();
    expect(rows, hasLength(1), reason: '记忆编号加设备编号只一行');
    expect(rows.single['recall_count'], 1);
    expect(rows.single['search_count'], 1);
    expect(await device.bufferRows(), isEmpty);
  });

  test('两台设备的计数各写一行，读回时相加', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final a = _Device(rig, deviceId: 'device-a');
    final b = _Device(rig, deviceId: 'device-b');
    final id = await a.memory('晚上学习');

    // 缓冲表不带设备编号，一次冲刷清空整张缓冲；真实使用里一台机器只有一台
    // 设备，这里按“先汇总 A，再汇总 B”的顺序造出两台设备各一行的状态。
    a.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await a.service.flush(), isTrue);
    b.service.noteSearch(id);
    b.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await b.service.flush(), isTrue);

    final rows = await a.usageRows();
    expect(rows, hasLength(2), reason: '记忆编号加设备编号各一行');
    final byDevice = {for (final row in rows) row['device_id']: row};
    expect(byDevice['device-a']!['recall_count'], 1);
    expect(byDevice['device-a']!['search_count'], 0);
    expect(byDevice['device-b']!['recall_count'], 0);
    expect(byDevice['device-b']!['search_count'], 2);
    expect(
      byDevice['device-a']!['id'],
      isNot(byDevice['device-b']!['id']),
      reason: '编号以设备编号与记忆编号为名字，两台设备各不相同',
    );

    // 按记忆汇总时各设备的行相加。
    final totals = await rig.raw.rawQuery(
      'SELECT SUM(recall_count) AS recall, SUM(search_count) AS search '
      'FROM memory_usage WHERE memory_id = ?',
      [id],
    );
    expect(totals.single['recall'], 1);
    expect(totals.single['search'], 2);
  });

  test('记忆被删除时缓冲随外键一起消失', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.bufferRows(), hasLength(1));

    await rig.db.execute('DELETE FROM memory WHERE id = ?', [id]);

    expect(await device.bufferRows(), isEmpty, reason: '缓冲行随外键级联删除');
    expect(await device.service.flush(), isFalse);
    expect(await device.usageRows(), isEmpty);
  });

  test('memory_usage.id 是 UUIDv5：同设备同记忆稳定，不同设备不同', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.service.flush(), isTrue);
    final firstId = (await device.usageRows()).single['id']! as String;
    expect(firstId, hasLength(36));
    expect(
      _uuidV5Text.hasMatch(firstId),
      isTrue,
      reason: '不是 UUIDv5 文本：$firstId',
    );

    // 同一条记忆再用一次：编号不变，计数在原行上累加。
    device.now = device.now.add(const Duration(hours: 1));
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.service.flush(), isTrue);
    final rows = await device.usageRows();
    expect(rows, hasLength(1), reason: '同一台设备同一条记忆只有一行');
    expect(rows.single['id'], firstId);
    expect(rows.single['search_count'], 1);

    // 换一台设备汇总同一条记忆：编号不同。
    final other = _Device(rig, deviceId: 'device-b');
    other.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await other.service.flush(), isTrue);
    final otherId = (await other.usageRows()).firstWhere(
      (row) => row['device_id'] == 'device-b',
    )['id'];
    expect(otherId, isNot(firstId));
    expect(_uuidV5Text.hasMatch(otherId! as String), isTrue);
  });

  test('UUIDv5 按 RFC 4122 计算：同一输入得到同一标识', () {
    // RFC 4122 的 DNS 命名空间加 www.example.com 是公开的示例向量。
    expect(
      uuidV5(
        'www.example.com',
        namespace: '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
      ),
      '2ed6657d-e927-568b-95e1-2665a8aea6a2',
    );
    expect(uuidV5('同一输入'), uuidV5('同一输入'));
    expect(uuidV5('同一输入'), isNot(uuidV5('另一个输入')));
    expect(zhixinUuidV5Namespace, hasLength(36));
  });

  test('距上次冲刷不足一天时进入后台不冲刷', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await device.service.flushIfDue();
    expect(device.service.lastFlushAt, isNotNull);
    expect((await device.usageRows()).single['recall_count'], 1);

    // 十二小时之后又用了一次：还在一天之内，进入后台不冲刷。
    device.now = device.now.add(const Duration(hours: 12));
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await device.service.flushIfDue();
    expect((await device.usageRows()).single['recall_count'], 1);

    // 再过十二小时满一天，进入后台时冲刷。
    device.now = device.now.add(const Duration(hours: 12));
    await device.service.flushIfDue();
    expect((await device.usageRows()).single['recall_count'], 2);
  });

  test('取不到设备编号时仍写缓冲，但跳过冲刷', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final id = await memories.create(
      id: newUuidV7(),
      kind: MemoryKind.semantic,
      content: '晚上学习',
    );
    var called = 0;
    final service = MemoryUsageService(
      db: rig.db,
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      deviceIdSource: () async {
        called++;
        throw StateError('登录凭据不可用');
      },
      clock: () => DateTime(2026, 11, 12, 10),
    );
    service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(called, 0, reason: '写缓冲不经过设备编号');
    expect(
      await selectRows(rig.raw, 'local_memory_use'),
      hasLength(1),
      reason: '缓冲表不带设备编号，取不到设备也能记',
    );
    expect(await service.flush(), isFalse);
    expect(called, greaterThan(0), reason: '冲刷要问设备编号，取不到就跳过');
    expect(await selectRows(rig.raw, 'memory_usage'), isEmpty);
    expect(
      await selectRows(rig.raw, 'local_memory_use'),
      hasLength(1),
      reason: '跳过冲刷时缓冲行留着，下次再汇总',
    );
  });

  test('读回本设备的统计：最近使用时间与合计', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    device.now = DateTime(2026, 11, 12, 11);
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await device.service.flush(), isTrue);

    // 读回统计：测试里走的是原始执行器（DriftRawDatabase 本身就是 drift 连接），
    // 按同一份统计行核对字段；readUsage 在 GuardedDatabase 上读，生产装配与这里
    // 同一张表同一组列。
    final rows = await device.usageRows();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row['memory_id'], id);
    expect(row['recall_count'], 1);
    expect(row['search_count'], 1);
    expect(row['last_recalled_at'], '2026-11-12 10:00:00');
    expect(row['last_searched_at'], '2026-11-12 11:00:00');
  });
}
