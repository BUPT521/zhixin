import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_usage_service.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/uuid_v7.dart';

import '../support/test_db.dart';

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
      selectRows(rig.db, 'memory_usage');

  Future<int> useRowCount() async =>
      (await selectRows(rig.db, 'memory_use')).length;
}

void main() {
  test('召回与主动搜索先记在本机，不形成提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');

    device.service.noteRecall(id);
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final uses = await selectRows(rig.db, 'memory_use');
    expect(uses, hasLength(2));
    expect(
      uses.map((row) => row['kind']),
      unorderedEquals(['recall', 'search']),
    );
    expect(uses.map((row) => row['device_id']), everyElement('device-a'));
    expect(
      uses.map((row) => row['acquired_at']),
      hasLength(2),
      reason: '本机拿到它的时刻就是用的时刻',
    );
    // 使用记录只是本机的簿记，不进 memory_usage。
    expect(await device.usageRows(), isEmpty);
  });

  test('冲刷按设备现算计数：recall 与 search 分别累加，重复冲刷不重复计数', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');

    device.service.noteRecall(id);
    device.service.noteRecall(id);
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    device.now = device.now.add(const Duration(minutes: 5));
    final flushed = await device.service.flush();
    expect(flushed, isTrue);

    var rows = await device.usageRows();
    expect(rows, hasLength(1));
    expect(rows.single['memory_id'], id);
    expect(rows.single['device_id'], 'device-a');
    expect(rows.single['recall_count'], 2);
    expect(rows.single['search_count'], 1);
    expect(rows.single['last_recalled_at'], isNotNull);
    expect(rows.single['last_searched_at'], isNotNull);
    expect(rows.single['first_seen_at'], '2026-11-12 10:05:00');

    // 没有新的使用再冲刷一次：计数不变，也不形成提交。
    final head = await rig.engine.headId(rig.raw);
    expect(await device.service.flush(), isFalse);
    rows = await device.usageRows();
    expect(rows.single['recall_count'], 2);
    expect(rows.single['search_count'], 1);
    expect(await rig.engine.headId(rig.raw), head, reason: '没有可数的记录时不形成提交');

    // 再记一次搜索并冲刷：只在原计数上加一。
    device.now = device.now.add(const Duration(minutes: 5));
    device.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    device.now = device.now.add(const Duration(minutes: 5));
    expect(await device.service.flush(), isTrue, reason: '新的使用要能冲刷');
    rows = await device.usageRows();
    expect(rows, hasLength(1), reason: '记忆编号加设备编号只一行');
    expect(rows.single['recall_count'], 2);
    expect(rows.single['search_count'], 2);
    // 冲刷时把 first_seen_at 前移到本次冲刷时刻；计数已经累加过，重复冲刷按
    // cquired_at > first_seen_at 现算不会重复计数。
    expect(rows.single['first_seen_at'], '2026-11-12 10:15:00');
  });

  test('冲刷形成 maintenance 提交，行为者是 system', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final device = _Device(rig);
    final id = await device.memory('晚上学习');
    device.service.noteRecall(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final before = await rig.engine.headId(rig.raw);

    expect(await device.service.flush(), isTrue);
    expect(await rig.engine.headId(rig.raw), greaterThan(before));
    final commit = await rig.engine.commitById(
      rig.raw,
      await rig.engine.headId(rig.raw),
    );
    expect(commit, isNotNull);
    expect(commit!.kind, RevisionKind.maintenance);
    expect(commit.actor, 'system');
    expect(commit.action, flushMemoryUsageAction);
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

  test('两台设备各写各的行，互不影响', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final a = _Device(rig, deviceId: 'device-a');
    final b = _Device(rig, deviceId: 'device-b');
    final id = await a.memory('晚上学习');

    a.service.noteRecall(id);
    b.service.noteSearch(id);
    b.service.noteSearch(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await a.service.flush(), isTrue);
    expect(await b.service.flush(), isTrue);

    final rows = await selectRows(rig.db, 'memory_usage');
    expect(rows, hasLength(2), reason: '记忆编号加设备编号各一行');
    final byDevice = {for (final row in rows) row['device_id']: row};
    expect(byDevice['device-a']!['recall_count'], 1);
    expect(byDevice['device-a']!['search_count'], 0);
    expect(byDevice['device-b']!['recall_count'], 0);
    expect(byDevice['device-b']!['search_count'], 2);
  });

  test('取不到设备编号时跳过冲刷，不写使用记录', () async {
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
    expect(called, greaterThan(0));
    expect(await selectRows(rig.db, 'memory_use'), isEmpty);
    expect(await service.flush(), isFalse);
    expect(await selectRows(rig.db, 'memory_usage'), isEmpty);
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
    // 按同一份统计行核对字段；MemoryUsageService.usage() 在 GuardedDatabase
    // 上读，生产装配与这里同一张表同一组列。
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
